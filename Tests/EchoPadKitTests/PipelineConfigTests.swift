import XCTest
@testable import EchoPadKit

final class PipelineConfigTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("echopad-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func settings(vault: String = "/Users/me/Obsidian/Work") -> Settings {
        var settings = Settings()
        settings.vaultPath = vault
        settings.myName = "Aron"
        return settings
    }

    func testNoVaultNoConfig() {
        XCTAssertNil(PipelineConfig(settings(vault: "")))
        XCTAssertNil(PipelineConfig(settings(vault: "   ")))
        XCTAssertThrowsError(try PipelineConfig.validate(settings(vault: ""))) { error in
            XCTAssertEqual(error as? PipelineConfig.Failure, .noVault)
            XCTAssertEqual(error.localizedDescription, "Choose your Obsidian vault in Settings → Transcription")
        }
    }

    func testDefaultsGiveTheExactKeysWithAbsolutePaths() throws {
        let config = try XCTUnwrap(PipelineConfig(settings()))
        XCTAssertEqual(config.toml, """
            # Written by EchoPad from Settings → Transcription. Changes made here are overwritten.
            vault = "/Users/me/Obsidian/Work"
            log_book_dir = "/Users/me/Obsidian/Work/Log Book"
            transcripts_dir = "/Users/me/Obsidian/Work/_attachments/transcripts"
            glossary_path = "/Users/me/Obsidian/Work/Admin/Meeting Glossary.md"
            your_name = "Aron"
            claude_model = "sonnet"
            retention_days = 3
            calendar = true

            """)
    }

    func testChangedValuesBlankFoldersAndEscaping() throws {
        var settings = settings(vault: "~/Vault \"Q\"/")
        settings.logBookFolder = "  "
        settings.transcriptsFolder = "Meetings/Transcripts/"
        settings.glossaryPath = "/Elsewhere/Glossary.md"
        settings.myName = #"Back\slash"#
        settings.draftModel = .opus
        settings.transcriptRetentionDays = 0
        settings.looksUpCalendar = false
        let config = try XCTUnwrap(PipelineConfig(settings))
        let home = NSHomeDirectory()
        XCTAssertEqual(config.vault, "\(home)/Vault \"Q\"")
        XCTAssertEqual(config.logBookDir, "\(home)/Vault \"Q\"/Log Book")
        XCTAssertEqual(config.transcriptsDir, "\(home)/Vault \"Q\"/Meetings/Transcripts")
        XCTAssertEqual(config.glossaryPath, "/Elsewhere/Glossary.md")
        XCTAssertTrue(config.toml.contains(#"vault = "\#(home)/Vault \"Q\"""#), config.toml)
        XCTAssertTrue(config.toml.contains(#"your_name = "Back\\slash""#), config.toml)
        XCTAssertTrue(config.toml.contains("claude_model = \"opus\"\nretention_days = 0\ncalendar = false\n"), config.toml)
        XCTAssertEqual(PipelineConfig.quote("a\tb\nc\u{1}"), #""a\tb\nc\u0001""#)
    }

    func testWritesAtomicallyAndOnlyWhenMissing() throws {
        let url = root.appendingPathComponent("data/config.toml")
        let first = try XCTUnwrap(PipelineConfig(settings()))
        XCTAssertTrue(try first.writeIfMissing(to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), first.toml)

        var changed = settings()
        changed.draftModel = .opus
        let second = try XCTUnwrap(PipelineConfig(changed))
        XCTAssertFalse(try second.writeIfMissing(to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), first.toml)

        try second.write(to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), second.toml)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["config.toml"])
    }

    func testValidateNeedsAnExistingVault() throws {
        let vault = root.appendingPathComponent("Vault")
        XCTAssertThrowsError(try PipelineConfig.validate(settings(vault: vault.path))) { error in
            XCTAssertEqual(error as? PipelineConfig.Failure, .vaultMissing(vault.path))
        }
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        XCTAssertThrowsError(try PipelineConfig.validate(settings(vault: vault.path))) { error in
            XCTAssertEqual(error as? PipelineConfig.Failure, .notAVault(vault.path))
        }
        XCTAssertFalse(PipelineConfig.hasValidVault(settings(vault: vault.path)))
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        XCTAssertEqual(try PipelineConfig.validate(settings(vault: vault.path)).vault, vault.path)
        XCTAssertTrue(PipelineConfig.hasValidVault(settings(vault: vault.path)))
    }

    func testResolvesThePickedVaultFolder() throws {
        let fm = FileManager.default
        func folder(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // Obsidian/ holds one vault (Work) and a plain folder: picking Obsidian/ selects Work.
        let parent = try folder("Obsidian")
        let work = try folder("Obsidian/Work")
        _ = try folder("Obsidian/Work/.obsidian")
        _ = try folder("Obsidian/Attachments")
        try Data("x".utf8).write(to: parent.appendingPathComponent("notes.md"))
        XCTAssertFalse(ObsidianVault.isVault(parent))
        XCTAssertTrue(ObsidianVault.isVault(work))
        XCTAssertEqual(ObsidianVault.resolve(picked: work)?.path, work.path)
        XCTAssertEqual(ObsidianVault.resolve(picked: parent)?.path, work.path)
        // A vault inside the vault does not matter when the picked folder is one.
        _ = try folder("Obsidian/Work/Nested/.obsidian")
        XCTAssertEqual(ObsidianVault.resolve(picked: work)?.path, work.path)

        // Two vaults below: ambiguous, rejected.
        _ = try folder("Obsidian/Personal/.obsidian")
        XCTAssertNil(ObsidianVault.resolve(picked: parent))
        // No vault at all, and a file named .obsidian, are rejected.
        XCTAssertNil(ObsidianVault.resolve(picked: try folder("Empty")))
        let fake = try folder("Fake")
        try Data().write(to: fake.appendingPathComponent(".obsidian"))
        XCTAssertFalse(ObsidianVault.isVault(fake))
        XCTAssertNil(ObsidianVault.resolve(picked: fake))
        XCTAssertNil(ObsidianVault.resolve(picked: root.appendingPathComponent("Missing")))
        XCTAssertEqual(ObsidianVault.NOT_A_VAULT,
                       "This folder is not an Obsidian vault (no .obsidian folder inside). Pick the vault itself, e.g. …/Obsidian/Work.")
    }

    func testPrepareRunCreatesTheTranscriptsFolder() throws {
        let vault = root.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let config = try PipelineConfig.validate(settings(vault: vault.path))
        let url = root.appendingPathComponent("data/config.toml")
        try config.prepareRun(configURL: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.appendingPathComponent("_attachments/transcripts").path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config.toml)
    }

    func testDefaultFileFollowsTheDataFolder() {
        XCTAssertEqual(PipelineConfig.fileURL, AppDirectories.applicationSupport.appendingPathComponent("config.toml"))
    }
}

final class PipelineSetupTests: XCTestCase {
    func testSummary() {
        func summary(vault: Bool = true, speaker: SpeakerFinder.ModelStatus = .ready,
                     pipeline: ExternalTranscriber.PipelineStatus = .ready, claude: ClaudeStatus = .ready) -> String {
            PipelineSetup.summary(vaultChosen: vault, speakerModel: speaker, pipeline: pipeline, claude: claude)
        }
        XCTAssertEqual(summary(), "Ready")
        XCTAssertEqual(summary(pipeline: .missing("Python environment"), claude: .notLoggedIn),
                       "Needs setup: Python environment, Claude login")
        XCTAssertEqual(summary(speaker: .notDownloaded, claude: .notInstalled), "Needs setup: Speaker model, Claude Code")
        XCTAssertEqual(summary(vault: false), "Needs setup: Obsidian vault")
        XCTAssertEqual(summary(claude: .checking), "Checking…")
        XCTAssertEqual(summary(pipeline: .failed("No pipeline in this build.")), "No pipeline in this build.")
    }

    func testReadsClaudeAuthStatus() {
        let loggedOut = ["{", #"  "loggedIn": false,"#, #"  "authMethod": "none","#, #"  "apiProvider": "firstParty""#, "}"]
        XCTAssertEqual(ClaudeCLI.loggedIn(fromJSON: loggedOut), false)
        XCTAssertEqual(ClaudeCLI.loggedIn(fromJSON: [#"{"loggedIn": true, "authMethod": "claude.ai"}"#]), true)
        XCTAssertNil(ClaudeCLI.loggedIn(fromJSON: ["Not logged in. Run claude auth login to authenticate."]))
        XCTAssertNil(ClaudeCLI.locate(environment: ["PATH": "/nonexistent:/also/not/here"]))
    }
}
