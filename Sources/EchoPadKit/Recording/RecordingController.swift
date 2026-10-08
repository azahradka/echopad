import AppKit
import Foundation
import ScribeKit
import SystemAudioKit

/// Runs a recording from start to saved files: capture with SystemAudioKit, transcribe
/// with ScribeKit (or the bundled Notetaker pipeline), then export to the chosen destination and run its after-save actions.
@MainActor
public final class RecordingController {
    /// Seconds of silent system audio during a detected call before the UI warns about it.
    static let SILENT_SYSTEM_WARNING: TimeInterval = 20
    /// Shorter recordings are treated as accidental and discarded.
    static let MINIMUM_DURATION: TimeInterval = 1.5

    private let appState: AppState
    private let library: ConversationLibrary
    private let recorder = AudioRecorder()
    private let scribe: Scribe
    private let external: ExternalTranscriber
    private let speakers: SpeakerFinder
    public var settings: Settings
    public var sounds: SoundPlayer?
    public var onSaved: ((Conversation) -> Void)?
    public var onError: ((String) -> Void)?
    /// Asked for a title when a recording stops and `asksForTitle` is on; nil keeps the current title.
    public var askForTitle: ((String) async -> String?)?

    private var currentID: UUID?
    private var startDate: Date?
    private var meetingBundleID: String?
    private var silenceTimer: Timer?
    private var silentSince: Date?

    public init(appState: AppState, library: ConversationLibrary, settings: Settings, scribe: Scribe = .shared,
                external: ExternalTranscriber? = nil, speakers: SpeakerFinder? = nil) {
        self.appState = appState
        self.library = library
        self.settings = settings
        self.scribe = scribe
        self.external = external ?? ExternalTranscriber()
        self.speakers = speakers ?? SpeakerFinder(scribe: scribe)
        recorder.onLevels = { [weak appState] mic, system in
            Task { @MainActor in appState?.push(microphone: mic, system: system) }
        }
    }

    // MARK: - Start and stop

    public func toggle() {
        if appState.phase.isRecording {
            Task { await stop() }
        } else if !appState.phase.isBusy {
            Task { await start() }
        }
    }

    /// Starts recording. `meeting` is the call app when the recording starts from a meeting
    /// notification; with the "only the meeting app" setting, just that app is recorded.
    public func start(title: String? = nil, meeting: DetectedMeeting? = nil, destinationID: UUID? = nil) async {
        guard !appState.phase.isBusy else { return }
        let id = UUID()
        let folder = library.folder(for: id)
        let date = Date()
        meetingBundleID = meeting?.bundleID
        let setup = configuration(for: meeting)

        do {
            try await recorder.start(setup.configuration, in: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            fail(Self.describe(error))
            return
        }

        currentID = id
        startDate = date
        appState.currentTitle = title ?? defaultTitle(meeting: meeting, date: date)
        appState.currentApp = meeting?.appName
        appState.currentDestinationID = destinationID ?? settings.defaultDestinationID
        appState.systemAudioLooksSilent = false
        appState.microphoneNotice = setup.microphoneNotice
        if let notice = setup.microphoneNotice { Log.recording.notice("\(notice)") }
        appState.transition(to: .recording(since: date))
        sounds?.play(.start)
        watchSystemAudio()
    }

    /// Stops recording. With `transcribe: false` (used on quit) the audio is kept and
    /// transcribed on the next launch.
    public func stop(transcribe: Bool = true) async {
        guard appState.phase.isRecording, let id = currentID, let startDate else { return }
        silenceTimer?.invalidate()
        silenceTimer = nil
        appState.transition(to: .processing(.finishingAudio))
        sounds?.play(.stop)

        guard let recording = await recorder.stop() else {
            fail("The recording could not be finished.")
            return
        }
        currentID = nil
        self.startDate = nil

        if recording.duration < Self.MINIMUM_DURATION {
            try? FileManager.default.removeItem(at: library.folder(for: id))
            appState.transition(to: .idle)
            return
        }

        var title = appState.currentTitle
        if transcribe, settings.asksForTitle, let ask = askForTitle, let chosen = await ask(title) {
            title = chosen.isEmpty ? title : chosen
        }

        var conversation = Conversation(id: id, title: title, date: startDate, duration: recording.duration,
                                        app: appState.currentApp, destinationID: appState.currentDestinationID)
        conversation.status = transcribe ? .transcribing : .recorded
        library.add(conversation)
        guard transcribe else {
            appState.transition(to: .idle)
            return
        }
        await process(id)
    }

    /// Stops and throws the recording away.
    public func discard() async {
        guard appState.phase.isRecording, let id = currentID else { return }
        silenceTimer?.invalidate()
        _ = await recorder.stop()
        try? FileManager.default.removeItem(at: library.folder(for: id))
        currentID = nil
        startDate = nil
        appState.transition(to: .idle)
    }

    /// Stops a recording because the call ended, if it was started for that call.
    public func meetingEnded(_ meeting: DetectedMeeting) {
        guard appState.phase.isRecording, meetingBundleID == meeting.bundleID else { return }
        Task { await stop() }
    }

    // MARK: - Processing

    /// Transcribes and exports a conversation already in the library. Used after a
    /// recording and for "Transcribe Again".
    public func process(_ id: UUID) async {
        guard var conversation = library.conversation(id: id) else { return }
        let tracks = library.tracks(for: id)
        guard tracks.microphone != nil || tracks.system != nil else {
            fail("The audio of this conversation is no longer kept, so it cannot be transcribed again.")
            return
        }
        library.update(id) { $0.status = .transcribing }
        appState.transition(to: .processing(.transcribing))
        if settings.transcriber == .external {
            await processExternally(id)
            return
        }

        let options = TranscriptionOptions(
            language: settings.language == "auto" ? nil : settings.language,
            diarize: settings.identifySpeakers,
            localSpeakerName: settings.myName.isEmpty ? "Me" : settings.myName
        )

        do {
            let appState = self.appState
            let transcript = try await scribe.transcribeConversation(
                microphone: tracks.microphone, system: tracks.system, options: options,
                progress: { stage in
                    Task { @MainActor in
                        switch stage {
                        case .identifyingSpeakers: appState.transition(to: .processing(.identifyingSpeakers))
                        case .finishing: appState.transition(to: .processing(.saving))
                        default: break
                        }
                    }
                })
            try library.store(transcript, for: id)
            conversation = library.conversation(id: id) ?? conversation
            try export(conversation, transcript: transcript)
        } catch {
            let message = Self.describe(error)
            library.update(id) { $0.status = .failed(message) }
            fail(message)
            return
        }
        library.enforceAudioLimit(settings.libraryLimit)
    }

    /// Finds speakers in the app (writing turns.json), then runs the Notetaker pipeline on the
    /// conversation's folder; it writes transcript.json, which is then exported exactly like a
    /// ScribeKit transcript. The pipeline may delete the tracks.
    private func processExternally(_ id: UUID) async {
        let appState = self.appState
        let folder = library.folder(for: id)
        let show: @Sendable @MainActor (String) -> Void = { stage in
            // A queued job must never take the pill away from a recording in progress.
            guard !appState.phase.isRecording else { return }
            appState.transition(to: .processing(.external(stage)))
        }
        do {
            // Checked first so a missing vault or pipeline fails before minutes of diarization.
            try PipelineConfig.validate(settings).prepareRun()
            _ = try ExternalTranscriber.command()
            try await speakers.prepareModel(onStatus: show)
            try await speakers.writeTurns(folder: folder, onStatus: show)
            // Runs --check first (and --setup when something is missing).
            try await external.transcribe(folder: folder, onStage: show)
            library.reload(id)
            guard let conversation = library.conversation(id: id), let transcript = library.transcript(for: id) else {
                throw ExternalTranscriber.Failure.noTranscript
            }
            try export(conversation, transcript: transcript)
        } catch {
            let message = Self.describe(error)
            library.update(id) { $0.status = .failed(message) }
            fail(message)
            return
        }
        library.enforceAudioLimit(settings.libraryLimit)
    }

    /// Writes the stored transcript again (for example after renaming speakers or
    /// choosing another destination) and runs the destination's after-save actions.
    public func export(_ conversation: Conversation, transcript: Transcript, runActions: Bool = true) throws {
        appState.transition(to: .processing(.saving))
        let destination = settings.destination(id: conversation.destinationID)
        let tracks = library.tracks(for: conversation.id)
        let result = try Exporter().export(conversation, transcript: transcript,
                                           tracks: [tracks.microphone, tracks.system].compactMap { $0 },
                                           to: destination)
        library.update(conversation.id) {
            $0.status = .done
            $0.wordCount = transcript.wordCount
            $0.speakers = transcript.speakers
            $0.language = transcript.language
            $0.exportedFiles = result.files.map(\.path)
            $0.exportedAudio = result.audio?.path
        }
        appState.transition(to: .saved(title: conversation.title), resetAfter: 2.5)
        sounds?.play(.saved)
        if runActions { AfterSave.run(destination.afterSave, result: result, transcript: transcript, destination: destination) }
        if let saved = library.conversation(id: conversation.id) { onSaved?(saved) }
    }

    // MARK: - Helpers

    private func configuration(for meeting: DetectedMeeting?) -> (configuration: AudioRecorder.Configuration,
                                                                  microphoneNotice: String?) {
        var configuration = AudioRecorder.Configuration()
        var microphoneNotice: String?
        configuration.backend = SystemAudioBackend(rawValue: settings.systemAudioBackend) ?? .processTap
        if settings.recordsMicrophone {
            if let uid = settings.microphoneUID {
                configuration.microphone = .device(uid: uid)
            } else {
                (configuration.microphone, microphoneNotice) = Self.unpinnedMicrophone(among: AudioDevices.inputs())
            }
        } else {
            configuration.microphone = nil
        }
        switch settings.systemAudio {
        case .off: configuration.systemAudio = nil
        case .everything: configuration.systemAudio = .everything
        case .meetingApp: configuration.systemAudio = meeting.map { .apps([$0.bundleID]) } ?? .everything
        case .selectedApps:
            configuration.systemAudio = settings.systemAudioApps.isEmpty ? .everything : .apps(settings.systemAudioApps)
        }
        // App isolation needs a process tap; ScreenCaptureKit always records everything.
        if configuration.backend == .screenCaptureKit, case .apps = configuration.systemAudio {
            configuration.systemAudio = .everything
        }
        return (configuration, microphoneNotice)
    }

    /// The microphone to record when none is pinned: the system default, unless that is a Bluetooth
    /// headset. Opening a headset's microphone drops it to 16 kHz hands-free audio in both directions,
    /// so the built-in microphone is used instead, with a notice. Without one, the default stays.
    nonisolated static func unpinnedMicrophone(among inputs: [AudioDevice])
        -> (microphone: AudioRecorder.Configuration.Microphone, notice: String?) {
        guard inputs.first(where: \.isDefault)?.transport == .bluetooth,
              let builtIn = inputs.first(where: { $0.transport == .builtIn }) else { return (.systemDefault, nil) }
        return (.device(uid: builtIn.uid), "Using \(builtIn.name): the default input is a Bluetooth headset")
    }

    private func defaultTitle(meeting: DetectedMeeting?, date: Date) -> String {
        if let meeting { return "\(meeting.appName) call" }
        let hour = Calendar.current.component(.hour, from: date)
        let part = hour < 12 ? "Morning" : hour < 18 ? "Afternoon" : "Evening"
        return "\(part) conversation"
    }

    /// Warns when a call is being recorded but the system track stays silent, which usually
    /// means the system audio permission was not granted.
    private func watchSystemAudio() {
        silentSince = nil
        guard settings.systemAudio != .off else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let peak = self.recorder.systemAudioPeak() ?? 0
                if peak > 0.02 {
                    self.silentSince = nil
                    self.appState.systemAudioLooksSilent = false
                } else if self.meetingBundleID != nil || self.appState.detectedMeeting != nil {
                    let since = self.silentSince ?? Date()
                    self.silentSince = since
                    self.appState.systemAudioLooksSilent = Date().timeIntervalSince(since) > Self.SILENT_SYSTEM_WARNING
                }
            }
        }
    }

    private func fail(_ message: String) {
        Log.recording.error("\(message)")
        appState.transition(to: .error(message), resetAfter: 6)
        sounds?.play(.error)
        onError?(message)
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }
}
