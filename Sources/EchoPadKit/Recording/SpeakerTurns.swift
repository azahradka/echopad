import AVFoundation
import Foundation
import Observation
import ScribeKit

/// `<folder>/turns.json`, written before the external transcriber runs so it gets speaker turns
/// without running a diarizer of its own:
///
///     {"mode": "call" | "in-person", "track": "system.wav" | "microphone.wav",
///      "diarizer": "fluidaudio-community-1", "turns": [{"start": 12.4, "end": 18.9, "speaker": "S1"}, …]}
///
/// Turns are sorted by start and speakers are named S1…SN in order of first appearance.
public struct SpeakerTurns: Codable, Equatable, Sendable {
    public static let FILE_NAME = "turns.json"
    public static let DIARIZER = "fluidaudio-community-1"
    /// Speakers expected around the laptop in an in-person meeting (PLAN: 1:1 or 2–4 people).
    static let IN_PERSON_SPEAKERS = 2...4

    public enum Mode: String, Codable, Sendable {
        case call
        case inPerson = "in-person"
    }

    public struct Turn: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var speaker: String
    }

    public var mode: Mode
    public var track: String
    public var diarizer: String
    public var turns: [Turn]

    /// Sorts `turns` by start and renames the diarizer's arbitrary IDs to S1…SN by first appearance.
    /// Times are rounded to 10 ms; turns that round to nothing are dropped, so every turn has
    /// 0 ≤ start < end as the pipeline requires.
    public init(mode: Mode, track: String, turns raw: [SegmentBuilder.Turn]) {
        self.mode = mode
        self.track = track
        diarizer = Self.DIARIZER
        var names: [String: String] = [:]
        turns = raw.map { ($0.speakerID, Self.round(max(0, $0.start)), Self.round($0.end)) }
            .filter { $0.1 < $0.2 }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map { id, start, end in
                let name = names[id] ?? "S\(names.count + 1)"
                names[id] = name
                return Turn(start: start, end: end, speaker: name)
            }
    }

    private static func round(_ seconds: TimeInterval) -> Double {
        (seconds * 100).rounded() / 100
    }

    /// The JSON with keys in the documented order, one turn per line.
    public func encoded() -> Data {
        func string(_ value: String) -> String {
            String(decoding: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
        func number(_ value: Double) -> String {
            value.isFinite ? "\(value)" : "0"
        }
        let rows = turns.map { "  {\"start\": \(number($0.start)), \"end\": \(number($0.end)), \"speaker\": \(string($0.speaker))}" }
        let head = "{\"mode\": \(string(mode.rawValue)), \"track\": \(string(track)), \"diarizer\": \(string(diarizer)), \"turns\": ["
        let body = rows.isEmpty ? "" : "\n" + rows.joined(separator: ",\n") + "\n"
        return Data((head + body + "]}\n").utf8)
    }

    /// Writes `turns.json` into `folder` through a temporary file and a rename, so a reader never
    /// sees half a file.
    public func write(to folder: URL) throws {
        let target = folder.appendingPathComponent(Self.FILE_NAME)
        let temporary = folder.appendingPathComponent(".\(Self.FILE_NAME).\(UUID().uuidString).tmp")
        try encoded().write(to: temporary)
        guard rename(temporary.path, target.path) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

/// The pipeline's "is there speech on this track" test (`pipeline/diarize.py` `speech_regions()` and
/// `process.py` `has_speech()`), mirrored so the app and the pipeline always agree on the mode:
/// 30 ms frames whose RMS is above −45 dBFS are speech, regions less than 0.5 s apart are joined,
/// and a track has speech when its regions add up to at least 1 s. A trailing partial frame is ignored.
public struct SpeechGate: Sendable {
    public static let FRAME_SECONDS = 0.03
    public static let GATE_DBFS = -45.0
    public static let MERGE_GAP_SECONDS = 0.5
    public static let MIN_SPEECH_SECONDS = 1.0

    public private(set) var regions: [(start: Double, end: Double)] = []
    private let frameLength: Int
    private let threshold: Float
    private var frameIndex = 0
    private var sumOfSquares: Float = 0
    private var filled = 0

    public init(sampleRate: Double = 16000) {
        frameLength = max(1, Int(Self.FRAME_SECONDS * sampleRate))
        threshold = Float(pow(10, Self.GATE_DBFS / 20))
    }

    /// Feeds the next samples of the track.
    public mutating func consume(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            sumOfSquares += sample * sample
            filled += 1
            if filled == frameLength { closeFrame() }
        }
    }

    public mutating func consume(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { consume($0) }
    }

    private mutating func closeFrame() {
        let rms = (sumOfSquares / Float(frameLength)).squareRoot()
        if rms > threshold {
            let start = Double(frameIndex) * Self.FRAME_SECONDS
            let end = Double(frameIndex + 1) * Self.FRAME_SECONDS
            if let last = regions.last, start - last.end < Self.MERGE_GAP_SECONDS {
                regions[regions.count - 1].end = end
            } else {
                regions.append((start, end))
            }
        }
        frameIndex += 1
        sumOfSquares = 0
        filled = 0
    }

    /// Total speech, with each region rounded to 10 ms as the pipeline does.
    public var speechSeconds: Double {
        regions.reduce(0) { total, region in
            total + ((region.end * 100).rounded() - (region.start * 100).rounded()) / 100
        }
    }

    public var hasSpeech: Bool { speechSeconds >= Self.MIN_SPEECH_SECONDS }

    /// Whether a WAV file has speech, read in blocks so long recordings stay out of memory.
    public static func hasSpeech(_ url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url)
        var gate = SpeechGate(sampleRate: file.processingFormat.sampleRate)
        let block: AVAudioFrameCount = 16000 * 30
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: block)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            gate.consume(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            if gate.hasSpeech { return true }
        }
        return gate.hasSpeech
    }
}

/// Finds speakers for the external transcriber with ScribeKit's diarizer, which only needs the
/// speaker model (about 30 MB, downloaded on first use). The speech model is never loaded.
@MainActor
@Observable
public final class SpeakerFinder {
    public enum ModelStatus: Equatable, Sendable {
        case unknown
        case notDownloaded
        case downloading(String)
        case ready
        case failed(String)
    }

    public enum Failure: LocalizedError {
        case noAudio
        case diarization(String)

        public var errorDescription: String? {
            switch self {
            case .noAudio: return "The audio of this conversation is no longer kept, so it cannot be transcribed again."
            case .diarization(let reason): return "Finding speakers failed: \(reason)"
            }
        }
    }

    /// What to diarize for a conversation folder.
    struct Plan: Equatable {
        var mode: SpeakerTurns.Mode
        var track: URL
        var minSpeakers: Int?
        var maxSpeakers: Int?
    }

    public private(set) var model: ModelStatus = .unknown
    private let scribe: Scribe

    public init(scribe: Scribe = .shared) {
        self.scribe = scribe
    }

    public func refresh() {
        if case .downloading = model { return }
        model = Scribe.diarizationModelIsCached() ? .ready : .notDownloaded
    }

    /// Call mode diarizes `system.wav` with no speaker hints. In-person mode (system audio was not
    /// captured, or its track has no speech by the pipeline's gate) diarizes `microphone.wav`
    /// expecting 2–4 speakers. Without a microphone track, the system track is used whatever it holds.
    nonisolated static func plan(folder: URL) throws -> Plan {
        let fm = FileManager.default
        let system = folder.appendingPathComponent("system.wav")
        let microphone = folder.appendingPathComponent("microphone.wav")
        let hasSystem = fm.fileExists(atPath: system.path)
        let hasMicrophone = fm.fileExists(atPath: microphone.path)
        if hasSystem, try !hasMicrophone || SpeechGate.hasSpeech(system) {
            return Plan(mode: .call, track: system, minSpeakers: nil, maxSpeakers: nil)
        }
        guard hasMicrophone else { throw Failure.noAudio }
        return Plan(mode: .inPerson, track: microphone,
                    minSpeakers: SpeakerTurns.IN_PERSON_SPEAKERS.lowerBound,
                    maxSpeakers: SpeakerTurns.IN_PERSON_SPEAKERS.upperBound)
    }

    /// Decides the mode, diarizes the right track and writes `<folder>/turns.json`.
    /// `onStatus` gets "Finding speakers" or the speaker model's download progress.
    @discardableResult
    public func writeTurns(folder: URL, onStatus: @escaping @Sendable @MainActor (String) -> Void = { _ in }) async throws -> SpeakerTurns {
        onStatus("Finding speakers")
        let plan = try await Task.detached(priority: .userInitiated) { try Self.plan(folder: folder) }.value
        let cached = Scribe.diarizationModelIsCached()
        // Once the model is cached, never touch the network for it again.
        Scribe.offlineMode = cached
        if !cached { model = .downloading("Downloading speaker model") }
        let raw: [SegmentBuilder.Turn]
        do {
            raw = try await scribe.diarize(url: plan.track, minSpeakers: plan.minSpeakers, maxSpeakers: plan.maxSpeakers,
                                           exclusive: true) { [weak self] progress in
                Task { @MainActor in
                    switch progress {
                    case .model(let fraction, _):
                        guard !cached else { return }
                        let text = "Downloading speaker model" + (fraction.map { " \(Int($0 * 100))%" } ?? "")
                        self?.model = .downloading(text)
                        onStatus(text)
                    case .diarizing:
                        if self?.model != .ready { self?.model = .ready }
                        onStatus("Finding speakers")
                    }
                }
            }
        } catch {
            let reason = RecordingController.describe(error)
            model = Scribe.diarizationModelIsCached() ? .ready : .failed(reason)
            throw Failure.diarization(reason)
        }
        model = .ready
        let turns = SpeakerTurns(mode: plan.mode, track: plan.track.lastPathComponent, turns: raw)
        try turns.write(to: folder)
        return turns
    }
}
