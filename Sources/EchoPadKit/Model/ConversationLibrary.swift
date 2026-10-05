import Foundation
import Observation
import ScribeKit

/// One recorded conversation in EchoPad's library.
public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public enum Status: Codable, Hashable, Sendable {
        case recorded
        case transcribing
        case done
        case failed(String)
    }

    public var id: UUID
    public var title: String
    public var date: Date
    public var duration: TimeInterval
    /// Call app that was detected, if any.
    public var app: String?
    public var destinationID: UUID?
    public var status: Status
    public var language: String?
    public var wordCount: Int
    public var speakers: [Speaker]
    /// Files written to the destination, most important first.
    public var exportedFiles: [String]
    public var exportedAudio: String?

    public init(id: UUID = UUID(), title: String, date: Date, duration: TimeInterval = 0, app: String? = nil,
                destinationID: UUID? = nil, status: Status = .recorded) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.app = app
        self.destinationID = destinationID
        self.status = status
        language = nil
        wordCount = 0
        speakers = []
        exportedFiles = []
        exportedAudio = nil
    }

    public var isFinished: Bool {
        if case .done = status { return true }
        return false
    }
}

/// Stores conversations as folders under ``AppDirectories/library``:
///
///     <id>/conversation.json   metadata
///     <id>/transcript.json     the ScribeKit transcript
///     <id>/microphone.wav      tracks, removed when the library limit is reached
///     <id>/system.wav
@MainActor
@Observable
public final class ConversationLibrary {
    public private(set) var conversations: [Conversation] = []
    public let directory: URL

    public init(directory: URL = AppDirectories.library) {
        self.directory = directory
        reload()
    }

    public func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        conversations = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("conversation.json")) else { return nil }
            return try? decoder.decode(Conversation.self, from: data)
        }.sorted { $0.date > $1.date }
        // A crash or quit mid-transcription leaves the status stuck; queue it to be finished.
        for index in conversations.indices where conversations[index].status == .transcribing {
            conversations[index].status = .recorded
            save(conversations[index])
        }
    }

    /// Re-reads one conversation's metadata from disk, after an external transcriber has run on its folder.
    public func reload(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              let data = try? Data(contentsOf: folder(for: id).appendingPathComponent("conversation.json")),
              let conversation = try? JSONDecoder().decode(Conversation.self, from: data) else { return }
        conversations[index] = conversation
    }

    /// Conversations recorded but never transcribed (the app quit or crashed in between).
    public var unfinished: [Conversation] {
        conversations.filter { $0.status == .recorded && hasAudio($0.id) }
    }

    public func folder(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func conversation(id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    public func transcript(for id: UUID) -> Transcript? {
        let url = folder(for: id).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    public func tracks(for id: UUID) -> (microphone: URL?, system: URL?) {
        let folder = folder(for: id)
        func existing(_ name: String) -> URL? {
            let url = folder.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return (existing("microphone.wav"), existing("system.wav"))
    }

    public func hasAudio(_ id: UUID) -> Bool {
        let tracks = tracks(for: id)
        return tracks.microphone != nil || tracks.system != nil
    }

    public func add(_ conversation: Conversation) {
        conversations.insert(conversation, at: 0)
        conversations.sort { $0.date > $1.date }
        save(conversation)
    }

    public func update(_ id: UUID, _ change: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
        save(conversations[index])
    }

    public func store(_ transcript: Transcript, for id: UUID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: folder(for: id).appendingPathComponent("transcript.json"), options: .atomic)
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
        conversations.removeAll { $0.id == id }
    }

    /// Deletes the audio of all but the newest `limit` finished conversations; transcripts stay.
    public func enforceAudioLimit(_ limit: Int) {
        let finished = conversations.filter(\.isFinished)
        for conversation in finished.dropFirst(max(limit, 0)) {
            let tracks = tracks(for: conversation.id)
            for url in [tracks.microphone, tracks.system].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func save(_ conversation: Conversation) {
        let folder = folder(for: conversation.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(conversation) {
            try? data.write(to: folder.appendingPathComponent("conversation.json"), options: .atomic)
        }
    }
}

extension Conversation {
    // Dates are stored as ISO 8601 so the JSON stays readable; decoding accepts both forms.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        if let string = try? container.decode(String.self, forKey: .date),
           let parsed = ISO8601DateFormatter().date(from: string) {
            date = parsed
        } else {
            date = try container.decode(Date.self, forKey: .date)
        }
        duration = (try? container.decode(TimeInterval.self, forKey: .duration)) ?? 0
        app = try? container.decode(String.self, forKey: .app)
        destinationID = try? container.decode(UUID.self, forKey: .destinationID)
        status = (try? container.decode(Status.self, forKey: .status)) ?? .recorded
        language = try? container.decode(String.self, forKey: .language)
        wordCount = (try? container.decode(Int.self, forKey: .wordCount)) ?? 0
        speakers = (try? container.decode([Speaker].self, forKey: .speakers)) ?? []
        exportedFiles = (try? container.decode([String].self, forKey: .exportedFiles)) ?? []
        exportedAudio = try? container.decode(String.self, forKey: .exportedAudio)
    }
}
