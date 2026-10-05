import Foundation
import Observation

/// Runs a user-chosen command instead of ScribeKit. The contract:
///
///     <command> --check     prints "models: ok" or "models: missing <what>", exits 0, no network
///     <command> --setup     downloads missing models; exit 3 = needs a Hugging Face token,
///                           4 = the model's gate is not accepted ("needs: gate <url>"), other = failure
///     <command> <folder>    writes <folder>/transcript.json; exit 6 = models missing
///
/// Progress arrives on stdout as `stage: <text>` lines, failures as the first stderr line.
/// Setup and transcription run one at a time, in the order they were asked for.
@MainActor
@Observable
public final class ExternalTranscriber {
    /// Shown when `--setup` asks for a token without naming the gated model.
    nonisolated static let DEFAULT_GATE_URL = URL(string: "https://huggingface.co/pyannote/speaker-diarization-community-1")!
    static let EXIT_NEEDS_TOKEN: Int32 = 3
    static let EXIT_GATE_NOT_ACCEPTED: Int32 = 4
    static let EXIT_MODELS_MISSING: Int32 = 6
    /// stderr lines kept for the log; the rest is drained and dropped.
    static let STDERR_LINE_LIMIT = 200

    public enum ModelsStatus: Equatable, Sendable {
        case unknown
        case checking
        case ready
        case missing(String)
        case downloading(String)
        case failed(String)
    }

    public enum Failure: LocalizedError, Equatable {
        case noCommand
        case notExecutable(String)
        case exited(Int32, String?)
        case setupCancelled
        case modelsStillMissing
        case noTranscript

        public var errorDescription: String? {
            switch self {
            case .noCommand:
                return "Choose the external transcriber command in Settings → Transcription."
            case .notExecutable(let path):
                return "The external transcriber \(path) is not an executable file."
            case .exited(let status, let line):
                return line ?? "The external transcriber stopped with exit code \(status)."
            case .setupCancelled:
                return "The transcription models were not downloaded, so this conversation was not transcribed. Download them in Settings → Transcription, then choose Transcribe Again."
            case .modelsStillMissing:
                return "The external transcriber still reports missing models after downloading them."
            case .noTranscript:
                return "The external transcriber finished without writing a readable transcript.json."
            }
        }
    }

    /// What a finished command printed.
    struct Output: Sendable {
        var status: Int32
        var stdout: [String]
        var stderr: [String]

        var firstErrorLine: String? {
            stderr.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }

        func value(for key: String) -> String? {
            stdout.lazy.compactMap { ExternalTranscriber.value(of: key, in: $0) }.first
        }
    }

    public private(set) var models: ModelsStatus = .unknown
    public private(set) var hasToken = HuggingFaceToken.isStored
    /// Asked for a Hugging Face token; nil means the user cancelled.
    public var askForToken: ((TokenRequest) async -> String?)?

    private var tail: Task<Void, Never>?
    private var isSettingUp = false

    public init() {}

    // MARK: - Public entry points

    /// Runs `--check` and updates ``models``. Returns nil when the answer is unknown.
    @discardableResult
    public func check(command: String) async -> Bool? {
        guard !isSettingUp else { return nil }
        models = .checking
        hasToken = HuggingFaceToken.isStored
        do {
            let output = try await Self.execute(try Self.executable(command), ["--check"])
            guard output.status == 0 else {
                models = .failed(Failure.exited(output.status, output.firstErrorLine).errorDescription ?? "")
                return nil
            }
            guard let answer = output.value(for: "models") else {
                models = .failed("The command did not answer --check with a “models:” line.")
                return nil
            }
            if answer == "ok" {
                models = .ready
                return true
            }
            models = .missing(Self.describeMissing(answer))
            return false
        } catch {
            models = .failed(RecordingController.describe(error))
            return nil
        }
    }

    /// Downloads missing models, asking for a token when needed. Waits for any running job.
    public func setUpModels(command: String, onStage: @escaping @MainActor (String) -> Void = { _ in }) async throws {
        try await serialized {
            try await self.setUp(try Self.executable(command), onStage: onStage)
        }
    }

    /// Transcribes `folder` (which must already hold conversation.json and the tracks), setting
    /// up models first when they are missing. Waits for any running job.
    public func transcribe(folder: URL, command: String, onStage: @escaping @MainActor (String) -> Void) async throws {
        try await serialized {
            let executable = try Self.executable(command)
            if await self.check(command: command) == false {
                try await self.setUp(executable, onStage: onStage)
            }
            var output = try await Self.execute(executable, [folder.path], onStage: onStage)
            if output.status == Self.EXIT_MODELS_MISSING {
                try await self.setUp(executable, onStage: onStage)
                output = try await Self.execute(executable, [folder.path], onStage: onStage)
                if output.status == Self.EXIT_MODELS_MISSING { throw Failure.modelsStillMissing }
            }
            guard output.status == 0 else {
                Self.log(output)
                throw Failure.exited(output.status, output.firstErrorLine)
            }
        }
    }

    public func forgetToken() {
        HuggingFaceToken.delete()
        hasToken = false
    }

    // MARK: - Setup

    private func setUp(_ executable: URL, onStage: @escaping @MainActor (String) -> Void) async throws {
        isSettingUp = true
        defer { isSettingUp = false }
        var token = HuggingFaceToken.load()
        while true {
            models = .downloading("Starting…")
            let output: Output
            do {
                output = try await Self.execute(executable, ["--setup"], token: token) { [weak self] stage in
                    self?.models = .downloading(stage)
                    onStage(stage)
                }
            } catch {
                models = .failed(RecordingController.describe(error))
                throw error
            }
            let request: TokenRequest
            switch output.status {
            case 0:
                models = .ready
                return
            case Self.EXIT_NEEDS_TOKEN:
                request = TokenRequest(gateURL: Self.gateURL(output.value(for: "needs")), gateRejected: false, detail: nil)
            case Self.EXIT_GATE_NOT_ACCEPTED:
                request = TokenRequest(gateURL: Self.gateURL(output.value(for: "needs")), gateRejected: true,
                                       detail: output.firstErrorLine)
            default:
                Self.log(output)
                let failure = Failure.exited(output.status, output.firstErrorLine)
                models = .failed(failure.errorDescription ?? "")
                throw failure
            }
            guard let entered = await askForToken?(request), !entered.isEmpty else {
                isSettingUp = false
                await check(command: executable.path)
                throw Failure.setupCancelled
            }
            // A token that cannot be stored is still used for this download.
            try? HuggingFaceToken.save(entered)
            hasToken = HuggingFaceToken.isStored
            token = entered
        }
    }

    // MARK: - Running the command

    private func serialized(_ work: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            try await work()
        }
        tail = Task { _ = await task.result }
        try await task.value
    }

    static func executable(_ command: String) throws -> URL {
        let path = (command.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty else { throw Failure.noCommand }
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) else {
            throw Failure.notExecutable(path)
        }
        return URL(fileURLWithPath: path)
    }

    /// A clean environment: nothing from EchoPad's own environment except the data folder override.
    static func environment(token: String? = nil) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let home = inherited["HOME"] ?? NSHomeDirectory()
        var environment = [
            "HOME": home,
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ]
        if let dataDirectory = inherited["ECHOPAD_DATA_DIR"] { environment["ECHOPAD_DATA_DIR"] = dataDirectory }
        if let token { environment["HF_TOKEN"] = token }
        return environment
    }

    /// Runs the command without a shell and reports each `stage:` line as it arrives.
    static func execute(_ executable: URL, _ arguments: [String], token: String? = nil,
                        onStage: @escaping @MainActor (String) -> Void = { _ in }) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.environment = environment(token: token)
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let (exits, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { finished in
            exited.yield(finished.terminationStatus)
            exited.finish()
        }
        try process.run()

        // Both pipes are drained at once so a chatty stderr cannot block the command.
        async let errorLines = collect(lines(of: stderr.fileHandleForReading), limit: STDERR_LINE_LIMIT)
        var lines: [String] = []
        for await line in self.lines(of: stdout.fileHandleForReading) {
            lines.append(line)
            if let stage = value(of: "stage", in: line), !stage.isEmpty { onStage(String(stage.prefix(80))) }
        }
        let stderrLines = await errorLines
        var status: Int32 = -1
        for await code in exits { status = code }
        return Output(status: status, stdout: lines, stderr: stderrLines)
    }

    /// Lines read with blocking reads on a background queue (FileHandle.bytes stalls when two
    /// pipes are read concurrently).
    nonisolated static func lines(of handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .utility).async {
                var buffer = Data()
                func emit(_ line: Data) {
                    var text = String(decoding: line, as: UTF8.self)
                    if text.hasSuffix("\r") { text.removeLast() }
                    continuation.yield(text)
                }
                while case let chunk = handle.availableData, !chunk.isEmpty {
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        emit(buffer[buffer.startIndex..<newline])
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                }
                if !buffer.isEmpty { emit(buffer) }
                continuation.finish()
            }
        }
    }

    /// Keeps the first `limit` lines and drains the rest.
    nonisolated static func collect(_ lines: AsyncStream<String>, limit: Int) async -> [String] {
        var kept: [String] = []
        for await line in lines where kept.count < limit { kept.append(line) }
        return kept
    }

    // MARK: - Parsing

    /// The text after `key:` in a line like `stage: diarizing`, or nil.
    nonisolated static func value(of key: String, in line: String) -> String? {
        let prefix = key + ":"
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    /// `missing qwen3` → `Qwen3-ASR`.
    nonisolated static func describeMissing(_ answer: String) -> String {
        let what = answer.hasPrefix("missing") ? answer.dropFirst("missing".count).trimmingCharacters(in: .whitespaces) : answer
        switch what {
        case "qwen3": return "Qwen3-ASR"
        case "pyannote": return "pyannote"
        case "both": return "Qwen3-ASR and pyannote"
        default: return what.isEmpty ? "models" : what
        }
    }

    /// The gate page from `needs: gate <url>`; only Hugging Face pages are linked.
    nonisolated static func gateURL(_ needs: String?) -> URL {
        guard let needs, needs.hasPrefix("gate "),
              let url = URL(string: needs.dropFirst("gate ".count).trimmingCharacters(in: .whitespaces)),
              url.scheme == "https", url.host == "huggingface.co" else { return DEFAULT_GATE_URL }
        return url
    }

    private static func log(_ output: Output) {
        let errors = output.stderr.joined(separator: "\n")
        Log.transcription.error("External transcriber exited with \(output.status): \(errors)")
    }
}

/// Why a Hugging Face token is being asked for.
public struct TokenRequest: Sendable {
    public var gateURL: URL
    /// The token was given but Hugging Face refused it for the model.
    public var gateRejected: Bool
    public var detail: String?
}
