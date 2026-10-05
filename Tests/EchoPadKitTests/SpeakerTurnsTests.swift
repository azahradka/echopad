import AVFoundation
import ScribeKit
import XCTest
@testable import EchoPadKit

final class SpeakerTurnsTests: XCTestCase {
    func testEncodesSortedTurnsWithSpeakersInOrderOfFirstAppearance() throws {
        let raw = [
            SegmentBuilder.Turn(speakerID: "7", start: 5.004, end: 8.2),
            SegmentBuilder.Turn(speakerID: "3", start: 0.5, end: 4.996),
            SegmentBuilder.Turn(speakerID: "1", start: 12, end: 13.5),
            SegmentBuilder.Turn(speakerID: "7", start: 9.25, end: 11),
            SegmentBuilder.Turn(speakerID: "9", start: 0.2, end: 0.204),  // rounds to nothing: dropped
        ]
        let turns = SpeakerTurns(mode: .call, track: "system.wav", turns: raw)
        XCTAssertEqual(turns.turns.map(\.speaker), ["S1", "S2", "S2", "S3"])
        let json = String(decoding: turns.encoded(), as: UTF8.self)
        XCTAssertEqual(json, """
        {"mode": "call", "track": "system.wav", "diarizer": "fluidaudio-community-1", "turns": [
          {"start": 0.5, "end": 5.0, "speaker": "S1"},
          {"start": 5.0, "end": 8.2, "speaker": "S2"},
          {"start": 9.25, "end": 11.0, "speaker": "S2"},
          {"start": 12.0, "end": 13.5, "speaker": "S3"}
        ]}

        """)
        XCTAssertEqual(try JSONDecoder().decode(SpeakerTurns.self, from: turns.encoded()), turns)

        let empty = SpeakerTurns(mode: .inPerson, track: "microphone.wav", turns: [])
        XCTAssertEqual(String(decoding: empty.encoded(), as: UTF8.self),
                       #"{"mode": "in-person", "track": "microphone.wav", "diarizer": "fluidaudio-community-1", "turns": []}"# + "\n")
    }

    func testWritesAtomically() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("old".utf8).write(to: folder.appendingPathComponent("turns.json"))
        let turns = SpeakerTurns(mode: .call, track: "system.wav", turns: [.init(speakerID: "a", start: 1, end: 2)])
        try turns.write(to: folder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("turns.json")), turns.encoded())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["turns.json"])
    }
}

final class SpeechGateTests: XCTestCase {
    /// A 440 Hz sine whose RMS is `dbfs`.
    private func tone(seconds: Double, dbfs: Double) -> [Float] {
        let amplitude = Float(pow(10, dbfs / 20) * 2.0.squareRoot())
        return (0..<Int(seconds * 16000)).map { amplitude * sin(2 * .pi * 440 * Float($0) / 16000) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16000))
    }

    func testMirrorsPipelineThresholds() {
        XCTAssertEqual(SpeechGate.FRAME_SECONDS, 0.03)
        XCTAssertEqual(SpeechGate.GATE_DBFS, -45)
        XCTAssertEqual(SpeechGate.MERGE_GAP_SECONDS, 0.5)
        XCTAssertEqual(SpeechGate.MIN_SPEECH_SECONDS, 1.0)
    }

    func testLoudFramesBecomeRegions() {
        // Frame-aligned: 0.3 s = 10 frames of 480 samples.
        var gate = SpeechGate()
        gate.consume(silence(0.6) + tone(seconds: 0.3, dbfs: -30) + silence(0.6) + tone(seconds: 0.3, dbfs: -30) + silence(0.3))
        XCTAssertEqual(gate.regions.count, 2)
        XCTAssertEqual(gate.regions[0].start, 0.6, accuracy: 1e-9)
        XCTAssertEqual(gate.regions[0].end, 0.9, accuracy: 1e-9)
        XCTAssertEqual(gate.speechSeconds, 0.6, accuracy: 1e-9)
        XCTAssertFalse(gate.hasSpeech)
    }

    func testGapsUnderHalfASecondAreJoined() {
        var gate = SpeechGate()
        // 0.3 s + 0.42 s gap + 0.3 s = one region of 1.02 s, which is speech.
        gate.consume(tone(seconds: 0.3, dbfs: -30) + silence(0.42) + tone(seconds: 0.3, dbfs: -30))
        XCTAssertEqual(gate.regions.count, 1)
        XCTAssertEqual(gate.speechSeconds, 1.02, accuracy: 1e-9)
        XCTAssertTrue(gate.hasSpeech)
    }

    func testQuietAudioIsNotSpeech() {
        var gate = SpeechGate()
        gate.consume(tone(seconds: 5, dbfs: -50))
        XCTAssertTrue(gate.regions.isEmpty)
        XCTAssertFalse(gate.hasSpeech)
        var loud = SpeechGate()
        loud.consume(tone(seconds: 1.5, dbfs: -40))
        XCTAssertTrue(loud.hasSpeech)
    }

    func testChunkedInputMatchesWhole() {
        let samples = silence(0.25) + tone(seconds: 0.7, dbfs: -20) + silence(0.9) + tone(seconds: 0.5, dbfs: -20)
        var whole = SpeechGate()
        whole.consume(samples)
        var chunked = SpeechGate()
        for start in stride(from: 0, to: samples.count, by: 777) {
            chunked.consume(Array(samples[start..<min(samples.count, start + 777)]))
        }
        XCTAssertEqual(whole.regions.map(\.start), chunked.regions.map(\.start))
        XCTAssertEqual(whole.regions.map(\.end), chunked.regions.map(\.end))
    }

    func testPlanPicksTheTrack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let microphone = folder.appendingPathComponent("microphone.wav")
        let system = folder.appendingPathComponent("system.wav")
        try WAV.write(tone(seconds: 3, dbfs: -25), to: microphone)

        // No system track: system audio capture was off.
        var plan = try SpeakerFinder.plan(folder: folder)
        XCTAssertEqual(plan, .init(mode: .inPerson, track: microphone, minSpeakers: 2, maxSpeakers: 4))

        // A system track with only quiet noise.
        try WAV.write(tone(seconds: 3, dbfs: -60), to: system)
        plan = try SpeakerFinder.plan(folder: folder)
        XCTAssertEqual(plan.mode, .inPerson)

        try WAV.write(silence(1) + tone(seconds: 2, dbfs: -30), to: system)
        plan = try SpeakerFinder.plan(folder: folder)
        XCTAssertEqual(plan, .init(mode: .call, track: system, minSpeakers: nil, maxSpeakers: nil))

        // An imported file is stored as the system track alone and is always diarized as a call.
        try FileManager.default.removeItem(at: microphone)
        try WAV.write(silence(2), to: system)
        XCTAssertEqual(try SpeakerFinder.plan(folder: folder).mode, .call)
    }
}

/// Real speaker model on two synthesized voices in a conversation folder, through the same code
/// the app runs before the pipeline. Skipped when the speaker model is not cached, so it never
/// downloads. With ECHOPAD_DATA_DIR set, the folder is kept in that library for inspection.
final class SpeakerFinderEndToEndTests: XCTestCase {
    static let LINES = [
        ("Samantha", "Good morning. I wanted to go over the inspection results from last week before the client call this afternoon."),
        ("Daniel", "Sure. The second run found three new anomalies near the river crossing, and all of them are fairly shallow."),
        ("Samantha", "Do we know whether they line up with the bending strain we saw in the earlier data set?"),
        ("Daniel", "Two of them do. The third one sits on a straight section, so I would like to take another look at it."),
        ("Samantha", "That makes sense. Can you send me the chainage for all three before Friday?"),
        ("Daniel", "Yes, I will put them in a short table with the depths and the dates of both runs."),
        ("Samantha", "Great. I will add them to the report and flag the third one as needing a follow up."),
        ("Daniel", "Sounds good. I will also check whether the geohazard team has anything on that slope."),
    ]

    @MainActor
    func testCallModeFindsTwoSpeakers() async throws {
        try XCTSkipUnless(Scribe.diarizationModelIsCached(), "speaker model not cached")
        let (folder, expected) = try makeConversation()
        let started = Date()
        let turns = try await SpeakerFinder(scribe: Scribe()).writeTurns(folder: folder)
        let elapsed = Date().timeIntervalSince(started)

        let written = try Data(contentsOf: folder.appendingPathComponent("turns.json"))
        XCTAssertEqual(try JSONDecoder().decode(SpeakerTurns.self, from: written), turns)
        let seconds = Double(try WAV.read(folder.appendingPathComponent("system.wav")).count) / 16000
        print("turns.json (\(String(format: "%.2f", elapsed)) s for \(seconds) s of audio, folder \(folder.path)):")
        print(String(decoding: written, as: UTF8.self))
        print("expected:", expected.map { "\($0.0) \(String(format: "%.2f–%.2f", $0.1, $0.2))" }.joined(separator: ", "))

        XCTAssertEqual(turns.mode, .call)
        XCTAssertEqual(turns.track, "system.wav")
        XCTAssertEqual(Set(turns.turns.map(\.speaker)), ["S1", "S2"])
        XCTAssertEqual(turns.turns.first?.speaker, "S1")
        // Each line belongs mostly to one speaker, alternating S1, S2, S1, …
        let owners = expected.map { _, start, end in
            Dictionary(grouping: turns.turns, by: \.speaker).mapValues { group in
                group.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
            }.max { $0.value < $1.value }?.key
        }
        XCTAssertEqual(owners, expected.indices.map { $0 % 2 == 0 ? "S1" : "S2" })
    }

    /// `<library>/<id>/` with conversation.json, a ~60 s two-voice system.wav and a silent microphone.wav.
    @MainActor
    private func makeConversation() throws -> (URL, [(String, Double, Double)]) {
        let keep = ProcessInfo.processInfo.environment["ECHOPAD_DATA_DIR"] != nil
        let libraryURL = keep ? AppDirectories.library
            : FileManager.default.temporaryDirectory.appendingPathComponent("echopad-e2e-\(UUID().uuidString)")
        if !keep { addTeardownBlock { try? FileManager.default.removeItem(at: libraryURL) } }
        let library = ConversationLibrary(directory: libraryURL)
        let conversation = Conversation(title: "Diarize test", date: Date(), duration: 60, status: .transcribing)
        library.add(conversation)
        let folder = library.folder(for: conversation.id)

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var samples: [Float] = []
        var expected: [(String, Double, Double)] = []
        for (index, (voice, text)) in Self.LINES.enumerated() {
            let aiff = scratch.appendingPathComponent("\(index).aiff")
            let wav = scratch.appendingPathComponent("\(index).wav")
            try run("/usr/bin/say", ["-v", voice, "-o", aiff.path, text])
            try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiff.path, wav.path])
            let line = try WAV.read(wav)
            let start = Double(samples.count) / 16000
            samples += line
            expected.append((voice, start, Double(samples.count) / 16000))
            samples += [Float](repeating: 0, count: 6400)  // 0.4 s between speakers
        }
        samples += [Float](repeating: 0, count: max(0, 60 * 16000 - samples.count))
        try WAV.write(samples, to: folder.appendingPathComponent("system.wav"))
        try WAV.write([Float](repeating: 0, count: samples.count), to: folder.appendingPathComponent("microphone.wav"))
        return (folder, expected)
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(path) \(arguments)")
    }
}

/// 16 kHz mono float32 WAV, the format EchoPad records.
enum WAV {
    static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
        }
        try file.write(from: buffer)
    }

    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
