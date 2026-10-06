import Foundation
import Observation

/// Whether the Claude CLI that drafts the meeting note is installed and logged in.
public enum ClaudeStatus: Equatable, Sendable {
    case unknown
    case checking
    case ready
    case notLoggedIn
    case notInstalled
    case failed(String)
}

/// The `claude` command the pipeline hands off to, looked up and asked exactly as the pipeline
/// would run it (the same minimal environment). EchoPad never logs in on the user's behalf.
enum ClaudeCLI {
    static let LOGIN_COMMAND = "claude auth login --claudeai"
    static let INSTALL_PAGE = URL(string: "https://code.claude.com/docs/en/setup")!
    /// `claude auth status` answers in well under a second; a hung CLI must not block setup.
    static let TIMEOUT: Duration = .seconds(30)

    /// The first executable `claude` on the environment's PATH.
    nonisolated static func locate(environment: [String: String]) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// `claude auth status --json` prints `{"loggedIn": true|false, …}` (exit 1 when logged out).
    nonisolated static func loggedIn(fromJSON lines: [String]) -> Bool? {
        let data = Data(lines.joined(separator: "\n").utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["loggedIn"] as? Bool
    }

    @MainActor
    static func status() async -> ClaudeStatus {
        guard let claude = locate(environment: ExternalTranscriber.environment()) else { return .notInstalled }
        do {
            let output = try await ExternalTranscriber.execute(claude, ["auth", "status", "--json"], timeout: TIMEOUT)
            guard let loggedIn = loggedIn(fromJSON: output.stdout) else {
                return .failed(output.lastErrorLine ?? "claude auth status did not answer (exit code \(output.status)).")
            }
            return loggedIn ? .ready : .notLoggedIn
        } catch {
            return .failed(RecordingController.describe(error))
        }
    }
}

/// "Set Up Pipeline": the speaker model, the pipeline's Python environment and Qwen3-ASR
/// (`transcribe.sh --setup`), and the Claude CLI check, plus the one-line summary of all of them.
@MainActor
@Observable
public final class PipelineSetup {
    public private(set) var claude: ClaudeStatus = .unknown
    /// The step running now ("Downloading speaker model 40%", a pipeline stage, "Checking Claude"); nil when idle.
    public private(set) var progress: String?

    private let external: ExternalTranscriber
    private let speakers: SpeakerFinder

    public init(external: ExternalTranscriber, speakers: SpeakerFinder) {
        self.external = external
        self.speakers = speakers
    }

    public var isRunning: Bool { progress != nil }

    /// True when every part Set Up Pipeline handles is in place.
    public var isComplete: Bool {
        speakers.model == .ready && external.pipeline == .ready && claude == .ready
    }

    /// Reads each part's state again without downloading anything.
    public func refresh() async {
        guard !isRunning else { return }
        speakers.refresh()
        await external.check()
        claude = .checking
        claude = await ClaudeCLI.status()
    }

    /// Runs the three steps in order, reporting each one's progress to `onStep` as well as
    /// ``progress``. A failed step does not stop the later ones. Returns the first problem, if any.
    public func run(onStep: @escaping @Sendable @MainActor (String) -> Void) async -> String? {
        guard !isRunning else { return nil }
        let show: @Sendable @MainActor (String) -> Void = { [weak self] text in
            self?.progress = text
            onStep(text)
        }
        show("Checking speaker model")
        defer { progress = nil }
        var problem: String?
        do {
            try await speakers.prepareModel(onStatus: show)
        } catch {
            problem = RecordingController.describe(error)
        }
        show("Setting up the pipeline")
        do {
            try await external.setUp(onStage: show)
        } catch {
            problem = problem ?? RecordingController.describe(error)
        }
        show("Checking Claude")
        claude = .checking
        claude = await ClaudeCLI.status()
        return problem ?? Self.claudeProblem(claude)
    }

    /// The Pipeline row while nothing runs: "Ready", "Checking…", "Needs setup: Python environment, Claude login",
    /// or why the pipeline cannot run at all.
    public func summary(vaultChosen: Bool) -> String {
        Self.summary(vaultChosen: vaultChosen, speakerModel: speakers.model, pipeline: external.pipeline, claude: claude)
    }

    nonisolated static func summary(vaultChosen: Bool, speakerModel: SpeakerFinder.ModelStatus,
                                    pipeline: ExternalTranscriber.PipelineStatus, claude: ClaudeStatus) -> String {
        if case .failed(let message) = pipeline { return message }
        var needs: [String] = []
        switch speakerModel {
        case .ready, .downloading: break
        case .unknown: return "Checking…"
        case .notDownloaded, .failed: needs.append("Speaker model")
        }
        switch pipeline {
        case .ready, .settingUp, .failed: break
        case .unknown, .checking: return "Checking…"
        case .missing(let what): needs.append(what)
        }
        switch claude {
        case .ready: break
        case .unknown, .checking: return "Checking…"
        case .notLoggedIn: needs.append("Claude login")
        case .notInstalled: needs.append("Claude Code")
        case .failed: needs.append("Claude check")
        }
        if !vaultChosen { needs.append("Obsidian vault") }
        return needs.isEmpty ? "Ready" : "Needs setup: " + needs.joined(separator: ", ")
    }

    nonisolated static func claudeProblem(_ status: ClaudeStatus) -> String? {
        switch status {
        case .ready, .unknown, .checking: return nil
        case .notLoggedIn: return "Claude: not logged in. Run \(ClaudeCLI.LOGIN_COMMAND) in Terminal."
        case .notInstalled: return "Claude: not installed. Install Claude Code, then set up again."
        case .failed(let message): return "Claude: \(message)"
        }
    }
}
