import Foundation
import Observation

/// Runs a user-chosen command instead of ScribeKit. The contract:
///
///     <command> --check     prints "setup: ok" or "setup: missing <env|qwen3|both>", exits 0, no network
///     <command> --setup     creates the Python environment and downloads Qwen3-ASR, printing stage lines;
///                           exit 0, or 5 = failure (reason on the last stderr line)
///     <command> <folder>    reads <folder>/turns.json, writes <folder>/transcript.json;
///                           exit 6 with "needs: setup" when setup is incomplete
///
/// Progress arrives on stdout as `stage: <text>` lines, failures as the last non-empty stderr line (the pipeline prints the reason last, after any warnings).
/// Setup and transcription run one at a time, in the order they were asked for.
@MainActor
@Observable
public final class ExternalTranscriber {
    static let EXIT_SETUP_FAILED: Int32 = 5
    static let EXIT_NEEDS_SETUP: Int32 = 6
    /// Most recent stderr lines kept for the log; earlier ones are dropped.
    static let STDERR_LINE_LIMIT = 200

    public enum PipelineStatus: Equatable, Sendable {
        case unknown
        case checking
        case ready
        case missing(String)
        case settingUp(String)
        case failed(String)
    }

    public enum Failure: LocalizedError, Equatable {
        case noCommand
        case notExecutable(String)
        case exited(Int32, String?)
        case setupStillIncomplete
        case noTranscript

        public var errorDescription: String? {
            switch self {
            case .noCommand:
                return "Choose the external transcriber command in Settings → Transcription."
            case .notExecutable(let path):
                return "The external transcriber \(path) is not an executable file."
            case .exited(let status, let line):
                return line ?? "The external transcriber stopped with exit code \(status)."
            case .setupStillIncomplete:
                return "The pipeline still reports that its setup is incomplete after setting it up. Try Set Up Pipeline in Settings → Transcription."
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

        var lastErrorLine: String? {
            stderr.reversed().lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }

        func value(for key: String) -> String? {
            stdout.lazy.compactMap { ExternalTranscriber.value(of: key, in: $0) }.first
        }
    }

    public private(set) var pipeline: PipelineStatus = .unknown

    private var tail: Task<Void, Never>?
    private var isSettingUp = false

    public init() {}

    // MARK: - Public entry points

    /// Runs `--check` and updates ``pipeline``. Returns nil when the answer is unknown.
    @discardableResult
    public func check(command: String) async -> Bool? {
        guard !isSettingUp else { return nil }
        pipeline = .checking
        do {
            let output = try await Self.execute(try Self.executable(command), ["--check"])
            guard output.status == 0 else {
                pipeline = .failed(Failure.exited(output.status, output.lastErrorLine).errorDescription ?? "")
                return nil
            }
            guard let answer = output.value(for: "setup") else {
                pipeline = .failed("The command did not answer --check with a “setup:” line.")
                return nil
            }
            if answer == "ok" {
                pipeline = .ready
                return true
            }
            pipeline = .missing(Self.describeMissing(answer))
            return false
        } catch {
            pipeline = .failed(RecordingController.describe(error))
            return nil
        }
    }

    /// Runs `--setup` (Python environment, Qwen3-ASR). Waits for any running job.
    public func setUp(command: String, onStage: @escaping @MainActor (String) -> Void = { _ in }) async throws {
        try await serialized {
            try await self.setUp(try Self.executable(command), onStage: onStage)
        }
    }

    /// Transcribes `folder` (which must already hold conversation.json, the tracks and turns.json),
    /// setting the pipeline up first when it is incomplete. Waits for any running job.
    public func transcribe(folder: URL, command: String, onStage: @escaping @MainActor (String) -> Void) async throws {
        try await serialized {
            let executable = try Self.executable(command)
            if await self.check(command: command) == false {
                try await self.setUp(executable, onStage: onStage)
            }
            var output = try await Self.execute(executable, [folder.path], onStage: onStage)
            if output.status == Self.EXIT_NEEDS_SETUP {
                try await self.setUp(executable, onStage: onStage)
                output = try await Self.execute(executable, [folder.path], onStage: onStage)
                if output.status == Self.EXIT_NEEDS_SETUP { throw Failure.setupStillIncomplete }
            }
            guard output.status == 0 else {
                Self.log(output)
                throw Failure.exited(output.status, output.lastErrorLine)
            }
        }
    }

    // MARK: - Setup

    private func setUp(_ executable: URL, onStage: @escaping @MainActor (String) -> Void) async throws {
        isSettingUp = true
        defer { isSettingUp = false }
        pipeline = .settingUp("Starting…")
        let output: Output
        do {
            output = try await Self.execute(executable, ["--setup"]) { [weak self] stage in
                self?.pipeline = .settingUp(stage)
                onStage(stage)
            }
        } catch {
            pipeline = .failed(RecordingController.describe(error))
            throw error
        }
        guard output.status == 0 else {
            Self.log(output)
            let failure = Failure.exited(output.status, output.lastErrorLine)
            pipeline = .failed(failure.errorDescription ?? "")
            throw failure
        }
        pipeline = .ready
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
    nonisolated static func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let home = inherited["HOME"] ?? NSHomeDirectory()
        var environment = [
            "HOME": home,
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ]
        if let dataDirectory = inherited["ECHOPAD_DATA_DIR"] { environment["ECHOPAD_DATA_DIR"] = dataDirectory }
        return environment
    }

    /// Runs the command without a shell and reports each `stage:` line as it arrives.
    static func execute(_ executable: URL, _ arguments: [String],
                        onStage: @escaping @MainActor (String) -> Void = { _ in }) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.environment = environment()
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

    /// Keeps the last `limit` lines.
    nonisolated static func collect(_ lines: AsyncStream<String>, limit: Int) async -> [String] {
        var kept: [String] = []
        for await line in lines {
            kept.append(line)
            if kept.count > limit { kept.removeFirst() }
        }
        return kept
    }

    // MARK: - Parsing

    /// The text after `key:` in a line like `stage: diarizing`, or nil.
    nonisolated static func value(of key: String, in line: String) -> String? {
        let prefix = key + ":"
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    /// `missing env` → `Python environment`, `missing qwen3` → `Qwen3-ASR`.
    nonisolated static func describeMissing(_ answer: String) -> String {
        let what = answer.hasPrefix("missing") ? answer.dropFirst("missing".count).trimmingCharacters(in: .whitespaces) : answer
        switch what {
        case "env": return "Python environment"
        case "qwen3": return "Qwen3-ASR"
        case "both": return "Python environment and Qwen3-ASR"
        default: return what.isEmpty ? "setup" : what
        }
    }

    private static func log(_ output: Output) {
        let errors = output.stderr.joined(separator: "\n")
        Log.transcription.error("External transcriber exited with \(output.status): \(errors)")
    }
}
