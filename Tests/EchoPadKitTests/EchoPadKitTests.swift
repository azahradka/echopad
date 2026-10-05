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
        XCTAssertEqual(settings.externalCommand, "")
    }

    func testExternalTranscriberRoundTrip() throws {
        var settings = Settings()
        settings.transcriber = .external
        settings.externalCommand = "/Users/me/bin/transcribe"
        let data = try JSONEncoder().encode(settings)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""transcriber":"external""#), json)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), settings)
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
        XCTAssertEqual(ExternalTranscriber.value(of: "stage", in: "stage: transcribing 12/65"), "transcribing 12/65")
        XCTAssertNil(ExternalTranscriber.value(of: "stage", in: "Loading weights"))
        XCTAssertEqual(ExternalTranscriber.describeMissing("missing both"), "Qwen3-ASR and pyannote")
        XCTAssertEqual(ExternalTranscriber.describeMissing("missing pyannote"), "pyannote")
    }

    func testOnlyLinksHuggingFaceGatePages() {
        XCTAssertEqual(ExternalTranscriber.gateURL("gate https://huggingface.co/pyannote/x").absoluteString,
                       "https://huggingface.co/pyannote/x")
        XCTAssertEqual(ExternalTranscriber.gateURL("gate https://example.com/x"), ExternalTranscriber.DEFAULT_GATE_URL)
        XCTAssertEqual(ExternalTranscriber.gateURL("hf_token"), ExternalTranscriber.DEFAULT_GATE_URL)
    }

    func testStageTitle() {
        XCTAssertEqual(ProcessingStep.external("drafting note").title, "Drafting note…")
    }
}
