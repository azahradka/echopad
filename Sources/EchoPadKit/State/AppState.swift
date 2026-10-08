import Foundation
import Observation
import ScribeKit

/// What EchoPad is doing right now.
public enum Phase: Equatable, Sendable {
    case idle
    case recording(since: Date)
    case processing(ProcessingStep)
    case saved(title: String)
    case error(String)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .recording, .processing: return true
        default: return false
        }
    }
}

public enum ProcessingStep: Equatable, Sendable {
    case finishingAudio
    case transcribing
    case identifyingSpeakers
    case saving
    /// A `stage:` line from the external transcriber.
    case external(String)

    public var title: String {
        switch self {
        case .finishingAudio: return "Finishing the recording…"
        case .transcribing: return "Transcribing…"
        case .identifyingSpeakers: return "Identifying speakers…"
        case .saving: return "Saving…"
        case .external(let stage): return stage.prefix(1).uppercased() + stage.dropFirst() + "…"
        }
    }
}

public enum ModelState: Equatable, Sendable {
    case notLoaded
    case loading(fraction: Double?, detail: String)
    case ready
    case failed(String)

    public var isReady: Bool { self == .ready }
}

/// Live state shared by the menu bar, the pill and the windows.
@MainActor
@Observable
public final class AppState {
    public static let LEVEL_HISTORY_COUNT = 32

    public private(set) var phase: Phase = .idle
    public var model: ModelState = .notLoaded
    public private(set) var microphoneLevels = Array(repeating: Float(0), count: LEVEL_HISTORY_COUNT)
    public private(set) var systemLevels = Array(repeating: Float(0), count: LEVEL_HISTORY_COUNT)
    /// Title of the recording in progress; editable while recording.
    public var currentTitle = ""
    /// Destination chosen for the recording in progress.
    public var currentDestinationID: UUID?
    /// App whose call is being recorded, if detected.
    public var currentApp: String?
    /// Set when system audio has stayed silent for a while during a call, a hint that the
    /// permission is missing or audio goes elsewhere.
    public var systemAudioLooksSilent = false
    /// Set when the recording uses another microphone than the system default, and why.
    public var microphoneNotice: String?
    public var detectedMeeting: String?

    private var resetTask: Task<Void, Never>?

    public init() {}

    public func transition(to phase: Phase, resetAfter delay: TimeInterval? = nil) {
        resetTask?.cancel()
        self.phase = phase
        if !phase.isRecording { resetLevels() }
        guard let delay else { return }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.phase == phase else { return }
            self.phase = .idle
        }
    }

    public func push(microphone: Float, system: Float) {
        guard phase.isRecording else { return }
        microphoneLevels.removeFirst()
        microphoneLevels.append(microphone)
        systemLevels.removeFirst()
        systemLevels.append(system)
    }

    /// Combined level per bar for a single waveform.
    public var combinedLevels: [Float] {
        zip(microphoneLevels, systemLevels).map { max($0, $1) }
    }

    private func resetLevels() {
        microphoneLevels = Array(repeating: 0, count: Self.LEVEL_HISTORY_COUNT)
        systemLevels = Array(repeating: 0, count: Self.LEVEL_HISTORY_COUNT)
    }
}
