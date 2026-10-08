import Foundation
import ScribeKit

/// Where and how finished conversations are saved. Users keep several (for example
/// "Work vault", "Client notes", "Subtitles") and pick one per recording.
public struct Destination: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Folder the transcript goes into. `~` is expanded.
    public var folder: String
    /// Optional subfolder under `folder`, same tokens as the file name, for example `{year}/{month}`.
    public var subfolderTemplate: String
    /// File name without extension, for example `{date} {time} - {title}`.
    public var fileNameTemplate: String
    /// Transcript files to write, one per format.
    public var formats: [TranscriptFormat]
    public var audio: AudioSaving
    /// Markdown only: YAML front matter with date, title, duration, speakers.
    public var includeFrontMatter: Bool
    /// Markdown only: a `[mm:ss]` before each paragraph.
    public var includeTimestamps: Bool
    /// Markdown only: extra front matter lines, one `key: value` per line (for example `tags: meeting`).
    public var extraFrontMatter: String
    public var afterSave: [AfterSaveAction]

    public init(id: UUID = UUID(), name: String, folder: String,
                subfolderTemplate: String = "",
                fileNameTemplate: String = Destination.DEFAULT_FILE_NAME,
                formats: [TranscriptFormat] = [.markdown],
                audio: AudioSaving = .init(),
                includeFrontMatter: Bool = true, includeTimestamps: Bool = true,
                extraFrontMatter: String = "", afterSave: [AfterSaveAction] = [.revealInFinder]) {
        self.id = id
        self.name = name
        self.folder = folder
        self.subfolderTemplate = subfolderTemplate
        self.fileNameTemplate = fileNameTemplate
        self.formats = formats
        self.audio = audio
        self.includeFrontMatter = includeFrontMatter
        self.includeTimestamps = includeTimestamps
        self.extraFrontMatter = extraFrontMatter
        self.afterSave = afterSave
    }

    public static let DEFAULT_FILE_NAME = "{date} {time} - {title}"

    public static var defaultFolder: String {
        "~/Documents/EchoPad"
    }

    public static func makeDefault() -> Destination {
        Destination(name: "Documents", folder: defaultFolder)
    }

    public var folderURL: URL {
        URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The Obsidian vault containing `folder`, if any (a parent folder with `.obsidian` in it).
    public var obsidianVault: URL? {
        ObsidianVault.containing(folderURL)
    }
}

/// Whether and where the recording itself is kept next to the transcript.
public struct AudioSaving: Codable, Hashable, Sendable {
    public enum Location: String, Codable, CaseIterable, Sendable {
        /// Not kept outside EchoPad's own library.
        case none
        /// Same folder as the transcript.
        case withTranscript
        /// A folder relative to the transcript folder (for example `attachments/audio`)
        /// or an absolute path.
        case folder
    }

    public enum Format: String, Codable, CaseIterable, Sendable {
        case m4a, wav

        public var displayName: String {
            switch self {
            case .m4a: return "AAC (.m4a), small"
            case .wav: return "WAV, lossless"
            }
        }
    }

    public var location: Location
    public var folder: String
    public var format: Format
    /// Markdown only: link the audio from the note (Obsidian embed inside a vault, a Markdown link otherwise).
    public var linkFromNote: Bool

    public init(location: Location = .none, folder: String = "attachments", format: Format = .m4a,
                linkFromNote: Bool = true) {
        self.location = location
        self.folder = folder
        self.format = format
        self.linkFromNote = linkFromNote
    }
}

/// Something to do once the files are written.
public enum AfterSaveAction: Codable, Hashable, Sendable {
    case revealInFinder
    /// Opens the main transcript in its default app.
    case openFile
    /// Opens the note in Obsidian (only when the folder is inside a vault).
    case openInObsidian
    case copyTranscript
    /// Runs a Shortcuts shortcut by name, with the transcript file as input.
    case runShortcut(String)
    /// Runs an executable with the transcript path as its first argument, and the
    /// audio path (or an empty string) as the second.
    case runScript(String)

    public var kind: Kind {
        switch self {
        case .revealInFinder: return .revealInFinder
        case .openFile: return .openFile
        case .openInObsidian: return .openInObsidian
        case .copyTranscript: return .copyTranscript
        case .runShortcut: return .runShortcut
        case .runScript: return .runScript
        }
    }

    public enum Kind: String, CaseIterable, Sendable {
        case revealInFinder, openFile, openInObsidian, copyTranscript, runShortcut, runScript

        public var title: String {
            switch self {
            case .revealInFinder: return "Show in Finder"
            case .openFile: return "Open the transcript"
            case .openInObsidian: return "Open in Obsidian"
            case .copyTranscript: return "Copy transcript to clipboard"
            case .runShortcut: return "Run a shortcut"
            case .runScript: return "Run a script"
            }
        }
    }
}

public enum ObsidianVault {
    public static let NOT_A_VAULT = "This folder is not an Obsidian vault (no .obsidian folder inside). Pick the vault itself, e.g. …/Obsidian/Work."

    /// Whether `url` is a vault: a folder with a `.obsidian` folder directly inside.
    public static func isVault(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(".obsidian").path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// The vault for a folder picked as one: the folder itself, or else its only immediate child that is
    /// a vault (picking the parent, such as …/Obsidian for …/Obsidian/Work, is the common mistake).
    /// nil when neither.
    public static func resolve(picked url: URL) -> URL? {
        let url = url.standardizedFileURL
        if isVault(url) { return url }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let vaults = children.filter(isVault)
        return vaults.count == 1 ? vaults[0].standardizedFileURL : nil
    }

    /// Walks up from `url` to find a folder holding `.obsidian`.
    public static func containing(_ url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if isVault(current) { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }

    /// `obsidian://open?vault=…&file=…` for a file inside `vault`.
    public static func openURL(for file: URL, in vault: URL) -> URL? {
        guard let relative = file.standardizedFileURL.path.relativePath(from: vault.standardizedFileURL.path) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vault.lastPathComponent),
            URLQueryItem(name: "file", value: relative),
        ]
        return components.url
    }
}

extension String {
    /// `self` relative to `base`, or nil when `self` is not inside `base`.
    func relativePath(from base: String) -> String? {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
