import AVFoundation
import XCTest
import ScribeKit
@testable import EchoPadKit

final class NameTemplateTests: XCTestCase {
    private let date: Date = {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute) = (2026, 9, 25, 14, 5)
        return Calendar.current.date(from: components)!
    }()

    func testDefaultTemplate() {
        let values = NameTemplate.Values(date: date, title: "Weekly sync")
        XCTAssertEqual(NameTemplate(Destination.DEFAULT_FILE_NAME).fileName(values), "2026-09-25 14.05 - Weekly sync")
    }

    func testAllTokens() {
        let values = NameTemplate.Values(date: date, title: "T", app: "Zoom", duration: 3900, speakerCount: 3, destination: "Work")
        let name = NameTemplate("{year}{month}{day} {hour}{minute} {weekday} {app} {duration} {speakers} {destination}").fileName(values)
        XCTAssertEqual(name, "20260925 1405 Friday Zoom 1h05m 3 Work")
    }

    func testUnsafeCharactersAndUnknownTokens() {
        let values = NameTemplate.Values(date: date, title: "Q3: plans / risks? [draft] #1")
        XCTAssertEqual(NameTemplate("{title} {nope}").fileName(values), "Q3 plans - risks draft 1 {nope}")
    }

    func testEmptyTemplateFallsBack() {
        let values = NameTemplate.Values(date: date, title: "x")
        XCTAssertEqual(NameTemplate("   ").fileName(values), "2026-09-25 14.05 - x")
    }

    func testFolderPathKeepsSlashesButNotFromValues() {
        let values = NameTemplate.Values(date: date, title: "a/b")
        XCTAssertEqual(NameTemplate("{year}/{month}/{title}").folderPath(values), "2026/09/a-b")
        XCTAssertEqual(NameTemplate("../{year}").folderPath(values), "2026")
    }
}

final class ExporterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("echopad-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func transcript() -> Transcript {
        Transcript(segments: [
            Segment(speakerID: "me", start: 0, end: 2, text: "Hello there."),
            Segment(speakerID: "s1", start: 2.5, end: 5, text: "Hi, how are you?"),
        ], speakers: [Speaker(id: "me", name: "Lukasz", isLocal: true), Speaker(id: "s1", name: "Speaker 1")],
        language: "en", duration: 5)
    }

    private func conversation() -> Conversation {
        Conversation(title: "Sync", date: Date(timeIntervalSince1970: 1_790_000_000), duration: 5, app: "Zoom")
    }

    private func tone(seconds: Double = 1) throws -> URL {
        let url = root.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.3 * sin(Float(i) * 0.1) }
        try file.write(from: buffer)
        return url
    }

    func testWritesEveryFormatWithSharedName() throws {
        let destination = Destination(name: "Notes", folder: root.path, subfolderTemplate: "{year}",
                                      fileNameTemplate: "{title}", formats: [.markdown, .srt, .json])
        let result = try Exporter().export(conversation(), transcript: transcript(), tracks: [], to: destination)
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["Sync.md", "Sync.srt", "Sync.json"])
        XCTAssertTrue(result.files[0].path.contains("/2026/"))
        let markdown = try String(contentsOf: result.files[0], encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("---\n"))
        XCTAssertTrue(markdown.contains("app: \"Zoom\""), markdown)
        XCTAssertTrue(markdown.contains("**Lukasz:** Hello there."), markdown)
        XCTAssertNil(result.audio)
    }

    func testDoesNotOverwrite() throws {
        let destination = Destination(name: "N", folder: root.path, fileNameTemplate: "{title}", formats: [.text])
        let first = try Exporter().export(conversation(), transcript: transcript(), tracks: [], to: destination)
        let second = try Exporter().export(conversation(), transcript: transcript(), tracks: [], to: destination)
        XCTAssertEqual(first.files[0].lastPathComponent, "Sync.txt")
        XCTAssertEqual(second.files[0].lastPathComponent, "Sync (2).txt")
    }

    func testAudioInObsidianVaultIsEmbedded() throws {
        let vault = root.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let destination = Destination(
            name: "Vault", folder: vault.appendingPathComponent("Meetings").path, fileNameTemplate: "{title}",
            formats: [.markdown], audio: AudioSaving(location: .folder, folder: "attachments/audio", format: .m4a))
        let result = try Exporter().export(conversation(), transcript: transcript(), tracks: [try tone(), try tone()],
                                           to: destination)
        let audio = try XCTUnwrap(result.audio)
        XCTAssertEqual(audio.path, vault.appendingPathComponent("attachments/audio/Sync.m4a").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let markdown = try String(contentsOf: result.files[0], encoding: .utf8)
        XCTAssertTrue(markdown.contains("![[attachments/audio/Sync.m4a]]"), markdown)
        XCTAssertTrue(markdown.contains("audio: \"[[attachments/audio/Sync.m4a]]\""), markdown)
        XCTAssertEqual(ObsidianVault.openURL(for: result.files[0], in: vault)?.absoluteString,
                       "obsidian://open?vault=Vault&file=Meetings/Sync.md")
    }

    func testAudioNextToTranscriptOutsideVaultIsLinked() throws {
        let destination = Destination(name: "D", folder: root.path, fileNameTemplate: "{title}",
                                      formats: [.markdown], audio: AudioSaving(location: .withTranscript, format: .wav))
        let result = try Exporter().export(conversation(), transcript: transcript(), tracks: [try tone()], to: destination)
        XCTAssertEqual(result.audio?.lastPathComponent, "Sync.wav")
        let markdown = try String(contentsOf: result.files[0], encoding: .utf8)
        XCTAssertTrue(markdown.contains("[Recording](Sync.wav)"), markdown)
    }

    func testRelativeLink() {
        let exporter = Exporter()
        XCTAssertEqual(exporter.relativeLink(from: URL(fileURLWithPath: "/a/b/notes"), to: URL(fileURLWithPath: "/a/b/audio/x.m4a")),
                       "../audio/x.m4a")
    }
}

final class SettingsTests: XCTestCase {
    func testDecodesPartialSettings() throws {
        let json = #"{"language":"pl","myName":"Łukasz"}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.language, "pl")
        XCTAssertEqual(settings.myName, "Łukasz")
        XCTAssertEqual(settings.destinations.count, 1)
        XCTAssertTrue(settings.identifySpeakers)
        XCTAssertEqual(settings.transcriber, .builtIn)
        XCTAssertEqual(settings.vaultPath, "")
        XCTAssertEqual(settings.logBookFolder, "Log Book")
        XCTAssertEqual(settings.transcriptsFolder, "_attachments/transcripts")
        XCTAssertEqual(settings.glossaryPath, "Admin/Meeting Glossary.md")
        XCTAssertEqual(settings.transcriptRetentionDays, 3)
        XCTAssertEqual(settings.draftModel, .sonnet)
        XCTAssertTrue(settings.looksUpCalendar)
    }

    func testPipelineSettingsRoundTrip() throws {
        var settings = Settings()
        settings.transcriber = .external
        settings.vaultPath = "/Users/me/Vault"
        settings.draftModel = .opus
        settings.transcriptRetentionDays = 7
        settings.looksUpCalendar = false
        let data = try JSONEncoder().encode(settings)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""transcriber":"external""#), json)
        XCTAssertTrue(json.contains(#""draftModel":"opus""#), json)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), settings)
    }

    /// A settings.json from the external-command era keeps its choice; the command is dropped on the next save.
    func testMigratesExternalCommandSettings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("echopad-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let old = #"{"transcriber":"external","externalCommand":"/Users/me/Notetaker/pipeline/transcribe.sh","myName":"Aron","language":"en"}"#
        try Data(old.utf8).write(to: url)
        let settings = SettingsStore.load(from: url)
        XCTAssertEqual(settings.transcriber, .external)
        XCTAssertEqual(settings.myName, "Aron")
        XCTAssertEqual(settings.language, "en")
        XCTAssertEqual(settings.vaultPath, "")
        XCTAssertEqual(settings.glossaryPath, Settings.DEFAULT_GLOSSARY_PATH)
        try SettingsStore.save(settings, to: url)
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(saved.contains("externalCommand"), saved)
        XCTAssertTrue(saved.contains(#""transcriber" : "external""#), saved)
        XCTAssertEqual(SettingsStore.load(from: url), settings)
    }

    func testTranscriberTitles() {
        XCTAssertEqual(Settings.TranscriberChoice.allCases.map(\.title), ["Built-in (Parakeet)", "Notetaker pipeline"])
    }

    func testRoundTrip() throws {
        var settings = Settings()
        settings.destinations.append(Destination(name: "Vault", folder: "~/Vault", afterSave: [.runShortcut("Summarize"), .openInObsidian]))
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), settings)
    }
}

final class ExternalTranscriberTests: XCTestCase {
    func testParsesContractLines() {
        XCTAssertEqual(ExternalTranscriber.value(of: "stage", in: "stage: downloading Qwen3-ASR 1.2/4.1 GB"),
                       "downloading Qwen3-ASR 1.2/4.1 GB")
        XCTAssertEqual(ExternalTranscriber.value(of: "setup", in: "setup: missing env"), "missing env")
        XCTAssertNil(ExternalTranscriber.value(of: "stage", in: "Loading weights"))
        XCTAssertEqual(ExternalTranscriber.describeMissing("missing env"), "Python environment")
        XCTAssertEqual(ExternalTranscriber.describeMissing("missing qwen3"), "Qwen3-ASR")
        XCTAssertEqual(ExternalTranscriber.describeMissing("missing both"), "Python environment and Qwen3-ASR")
    }

    func testEnvironmentCarriesNoToken() {
        let environment = ExternalTranscriber.environment()
        XCTAssertEqual(Set(environment.keys).subtracting(["ECHOPAD_DATA_DIR"]), ["HOME", "PATH", "USER", "LOGNAME"])
        XCTAssertFalse(environment["USER"]?.isEmpty ?? true)
    }

    func testFindsTheBundledPipelineFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echopad-pipeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources")
        let checkout = root.appendingPathComponent("checkout/pipeline")
        for folder in [resources.appendingPathComponent("pipeline"), checkout] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let script = folder.appendingPathComponent("transcribe.sh")
            try Data("#!/bin/sh\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let override = ["ECHOPAD_PIPELINE_DIR": checkout.path]
        XCTAssertEqual(try ExternalTranscriber.command(resources: resources, environment: override).path,
                       resources.appendingPathComponent("pipeline/transcribe.sh").path)
        let unbundled = root.appendingPathComponent("NoResources")
        XCTAssertEqual(try ExternalTranscriber.command(resources: unbundled, environment: override).path,
                       checkout.appendingPathComponent("transcribe.sh").path)
        XCTAssertThrowsError(try ExternalTranscriber.command(resources: unbundled, environment: [:])) { error in
            XCTAssertEqual(error as? ExternalTranscriber.Failure, .pipelineMissing)
        }
        XCTAssertThrowsError(try ExternalTranscriber.command(resources: nil, environment: ["ECHOPAD_PIPELINE_DIR": root.path])) { error in
            XCTAssertEqual(error as? ExternalTranscriber.Failure, .notExecutable(root.appendingPathComponent("transcribe.sh").path))
        }
    }

    func testStageTitle() {
        XCTAssertEqual(ProcessingStep.external("drafting note").title, "Drafting note…")
        XCTAssertEqual(ProcessingStep.external("Finding speakers").title, "Finding speakers…")
    }
}
