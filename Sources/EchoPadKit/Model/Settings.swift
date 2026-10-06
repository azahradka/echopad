import Foundation
import ScribeKit
import SystemAudioKit

/// Everything the user can change. Stored as JSON in Application Support.
public struct Settings: Codable, Equatable, Sendable {
    public var destinations: [Destination]
    public var defaultDestinationID: UUID?

    // Transcription
    public var transcriber: TranscriberChoice
    /// ISO 639-1 code, or "auto".
    public var language: String
    public var identifySpeakers: Bool
    /// Name for the local speaker in transcripts.
    public var myName: String

    // Notetaker pipeline (written to its config.toml, see ``PipelineConfig``)
    /// Absolute path of the Obsidian vault; empty until chosen.
    public var vaultPath: String
    /// Folders and the glossary note, relative to the vault.
    public var logBookFolder: String
    public var transcriptsFolder: String
    public var glossaryPath: String
    /// Days a transcript is kept in the vault before the pipeline deletes it.
    public var transcriptRetentionDays: Int
    public var draftModel: DraftModel
    /// Lets the note-drafting step look up the meeting in the Outlook calendar.
    public var looksUpCalendar: Bool

    // Capture
    /// nil means the system default microphone.
    public var microphoneUID: String?
    public var recordsMicrophone: Bool
    public var systemAudio: SystemAudioChoice
    /// Bundle IDs when `systemAudio == .selectedApps`.
    public var systemAudioApps: [String]
    public var systemAudioBackend: String

    // Behaviour
    public var hotkey: Hotkey
    public var detectsMeetings: Bool
    public var showsPill: Bool
    public var playsSounds: Bool
    /// Asks for a title when a recording stops, instead of using the default title.
    public var asksForTitle: Bool
    /// Recordings kept in EchoPad's own library (0 = keep only the exported files).
    public var libraryLimit: Int
    public var hasCompletedOnboarding: Bool

    public enum SystemAudioChoice: String, Codable, CaseIterable, Sendable {
        case everything, meetingApp, selectedApps, off

        public var title: String {
            switch self {
            case .everything: return "Everything on this Mac"
            case .meetingApp: return "Only the meeting app"
            case .selectedApps: return "Only selected apps"
            case .off: return "Off (microphone only)"
            }
        }
    }

    /// `external` is the Notetaker pipeline shipped inside the app (the raw value predates the bundle).
    public enum TranscriberChoice: String, Codable, CaseIterable, Sendable {
        case builtIn, external

        public var title: String {
            switch self {
            case .builtIn: return "Built-in (Parakeet)"
            case .external: return "Notetaker pipeline"
            }
        }
    }

    /// The Claude model that drafts the meeting note.
    public enum DraftModel: String, Codable, CaseIterable, Sendable {
        case sonnet, opus

        public var title: String {
            switch self {
            case .sonnet: return "Sonnet"
            case .opus: return "Opus"
            }
        }
    }

    public static let DEFAULT_LOG_BOOK_FOLDER = "Log Book"
    public static let DEFAULT_TRANSCRIPTS_FOLDER = "_attachments/transcripts"
    public static let DEFAULT_GLOSSARY_PATH = "Admin/Meeting Glossary.md"
    public static let DEFAULT_TRANSCRIPT_RETENTION_DAYS = 3

    public init() {
        let destination = Destination.makeDefault()
        destinations = [destination]
        defaultDestinationID = destination.id
        transcriber = .builtIn
        language = "auto"
        identifySpeakers = true
        myName = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
        vaultPath = ""
        logBookFolder = Self.DEFAULT_LOG_BOOK_FOLDER
        transcriptsFolder = Self.DEFAULT_TRANSCRIPTS_FOLDER
        glossaryPath = Self.DEFAULT_GLOSSARY_PATH
        transcriptRetentionDays = Self.DEFAULT_TRANSCRIPT_RETENTION_DAYS
        draftModel = .sonnet
        looksUpCalendar = true
        microphoneUID = nil
        recordsMicrophone = true
        systemAudio = .everything
        systemAudioApps = []
        systemAudioBackend = SystemAudioBackend.processTap.rawValue
        hotkey = .defaultToggle
        detectsMeetings = true
        showsPill = true
        playsSounds = true
        asksForTitle = false
        libraryLimit = 50
        hasCompletedOnboarding = false
    }

    public var defaultDestination: Destination {
        destinations.first { $0.id == defaultDestinationID } ?? destinations.first ?? .makeDefault()
    }

    public func destination(id: UUID?) -> Destination {
        destinations.first { $0.id == id } ?? defaultDestination
    }

    public static let LIBRARY_LIMITS = [0, 10, 25, 50, 100, 500]

    // Decoding tolerates missing keys, so settings files from older versions keep working. Keys
    // that no longer exist (such as `externalCommand`, replaced by the bundled pipeline) are
    // ignored and dropped on the next save.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ key: CodingKeys, into value: inout T) {
            if let decoded = try? container.decode(T.self, forKey: key) { value = decoded }
        }
        decode(.destinations, into: &destinations)
        defaultDestinationID = try? container.decode(UUID.self, forKey: .defaultDestinationID)
        decode(.transcriber, into: &transcriber)
        decode(.language, into: &language)
        decode(.identifySpeakers, into: &identifySpeakers)
        decode(.myName, into: &myName)
        decode(.vaultPath, into: &vaultPath)
        decode(.logBookFolder, into: &logBookFolder)
        decode(.transcriptsFolder, into: &transcriptsFolder)
        decode(.glossaryPath, into: &glossaryPath)
        decode(.transcriptRetentionDays, into: &transcriptRetentionDays)
        decode(.draftModel, into: &draftModel)
        decode(.looksUpCalendar, into: &looksUpCalendar)
        microphoneUID = try? container.decode(String.self, forKey: .microphoneUID)
        decode(.recordsMicrophone, into: &recordsMicrophone)
        decode(.systemAudio, into: &systemAudio)
        decode(.systemAudioApps, into: &systemAudioApps)
        decode(.systemAudioBackend, into: &systemAudioBackend)
        decode(.hotkey, into: &hotkey)
        decode(.detectsMeetings, into: &detectsMeetings)
        decode(.showsPill, into: &showsPill)
        decode(.playsSounds, into: &playsSounds)
        decode(.asksForTitle, into: &asksForTitle)
        decode(.libraryLimit, into: &libraryLimit)
        decode(.hasCompletedOnboarding, into: &hasCompletedOnboarding)
        if destinations.isEmpty { destinations = [.makeDefault()] }
    }
}

/// A global keyboard shortcut: a key plus modifiers (Carbon values).
public struct Hotkey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, shiftKey, optionKey, controlKey).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌘⇧E, as in earlier EchoPad versions.
    public static let defaultToggle = Hotkey(keyCode: 14, modifiers: 0x0100 | 0x0200)
}

/// Loads and saves ``Settings``.
public enum SettingsStore {
    public static var fileURL: URL {
        AppDirectories.applicationSupport.appendingPathComponent("settings.json")
    }

    public static func load(from url: URL = fileURL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    public static func save(_ settings: Settings, to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

public enum AppDirectories {
    public static var applicationSupport: URL {
        if let override = ProcessInfo.processInfo.environment["ECHOPAD_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoPad", isDirectory: true)
    }

    /// One folder per recording: tracks, transcript and metadata.
    public static var library: URL {
        applicationSupport.appendingPathComponent("Library", isDirectory: true)
    }
}
