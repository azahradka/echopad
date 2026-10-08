import Foundation

/// The Notetaker pipeline's `config.toml`, derived from ``Settings``. The app owns the file: it is
/// rewritten whenever these settings change, and at launch when it is missing.
/// Keys are exactly the ones `pipeline/process.py` reads; all paths are absolute.
public struct PipelineConfig: Equatable, Sendable {
    public var vault: String
    public var logBookDir: String
    public var transcriptsDir: String
    public var glossaryPath: String
    public var yourName: String
    public var claudeModel: String
    public var retentionDays: Int
    public var calendar: Bool

    public enum Failure: LocalizedError, Equatable {
        case noVault
        case vaultMissing(String)
        case notAVault(String)

        public var errorDescription: String? {
            switch self {
            case .noVault:
                return "Choose your Obsidian vault in Settings → Transcription"
            case .vaultMissing(let path):
                return "The Obsidian vault \(path) was not found. Choose it again in Settings → Transcription."
            case .notAVault(let path):
                return "\(path) is not an Obsidian vault (no .obsidian folder inside). Choose the vault itself in Settings → Transcription."
            }
        }
    }

    /// `BASE/config.toml`, where `transcribe.sh` reads it (BASE honours `ECHOPAD_DATA_DIR`).
    public static var fileURL: URL {
        AppDirectories.applicationSupport.appendingPathComponent("config.toml")
    }

    /// nil until a vault is chosen. Blank folder fields fall back to their defaults.
    public init?(_ settings: Settings) {
        let vault = Self.expand(settings.vaultPath)
        guard !vault.isEmpty else { return nil }
        func inVault(_ path: String, default fallback: String) -> String {
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            let relative = trimmed.isEmpty ? fallback : trimmed
            if relative.hasPrefix("/") || relative.hasPrefix("~") { return Self.expand(relative) }
            return URL(fileURLWithPath: vault).appendingPathComponent(relative).standardizedFileURL.path
        }
        self.vault = vault
        logBookDir = inVault(settings.logBookFolder, default: Settings.DEFAULT_LOG_BOOK_FOLDER)
        transcriptsDir = inVault(settings.transcriptsFolder, default: Settings.DEFAULT_TRANSCRIPTS_FOLDER)
        glossaryPath = inVault(settings.glossaryPath, default: Settings.DEFAULT_GLOSSARY_PATH)
        let name = settings.myName.trimmingCharacters(in: .whitespaces)
        yourName = name.isEmpty ? "Me" : name
        claudeModel = settings.draftModel.rawValue
        retentionDays = max(0, settings.transcriptRetentionDays)
        calendar = settings.looksUpCalendar
    }

    /// The vault is required before a recording can go through the pipeline, and must be a vault
    /// (holding `.obsidian`), not for example the folder above it.
    public static func validate(_ settings: Settings) throws -> PipelineConfig {
        guard let config = PipelineConfig(settings) else { throw Failure.noVault }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: config.vault, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.vaultMissing(config.vault)
        }
        guard ObsidianVault.isVault(URL(fileURLWithPath: config.vault)) else { throw Failure.notAVault(config.vault) }
        return config
    }

    /// Whether the saved vault would pass ``validate(_:)``; the Pipeline row says "Needs setup: Obsidian vault" otherwise.
    public static func hasValidVault(_ settings: Settings) -> Bool {
        (try? validate(settings)) != nil
    }

    public var toml: String {
        """
        # Written by EchoPad from Settings → Transcription. Changes made here are overwritten.
        vault = \(Self.quote(vault))
        log_book_dir = \(Self.quote(logBookDir))
        transcripts_dir = \(Self.quote(transcriptsDir))
        glossary_path = \(Self.quote(glossaryPath))
        your_name = \(Self.quote(yourName))
        claude_model = \(Self.quote(claudeModel))
        retention_days = \(retentionDays)
        calendar = \(calendar)

        """
    }

    /// Replaces the file atomically (temporary file, then rename).
    public func write(to url: URL = PipelineConfig.fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(toml.utf8).write(to: url, options: .atomic)
    }

    /// Writes the file only when it does not exist yet. Returns whether it wrote.
    @discardableResult
    public func writeIfMissing(to url: URL = PipelineConfig.fileURL) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try write(to: url)
        return true
    }

    /// Before a run: writes the file if it is missing and creates the transcripts folder with its
    /// parents (the pipeline only creates the last level, so a vault without `_attachments/` would fail).
    public func prepareRun(configURL: URL = PipelineConfig.fileURL) throws {
        try writeIfMissing(to: configURL)
        try FileManager.default.createDirectory(atPath: transcriptsDir, withIntermediateDirectories: true)
    }

    /// A TOML basic string.
    static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}
