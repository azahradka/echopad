import AppKit
import ScribeKit
import SwiftUI
import SystemAudioKit

struct RecordingSettingsView: View {
    @Environment(SettingsModel.self) private var settings
    @State private var microphones: [AudioDevice] = []
    @State private var permissions = PermissionSnapshot.current()

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Record my microphone", isOn: $settings.value.recordsMicrophone)
                if settings.value.recordsMicrophone {
                    Picker("Microphone", selection: $settings.value.microphoneUID) {
                        Text("System default").tag(String?.none)
                        ForEach(microphones) { Text($0.name).tag(Optional($0.uid)) }
                    }
                }
            } header: {
                Text("You")
            } footer: {
                Text("Everything on this track is labelled with your name, so it needs no speaker detection.")
            }

            Section {
                Picker("System audio", selection: $settings.value.systemAudio) {
                    ForEach(Settings.SystemAudioChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.value.systemAudio == .selectedApps {
                    AppListEditor(bundleIDs: $settings.value.systemAudioApps)
                }
                if settings.value.systemAudio != .off {
                    Picker("Capture with", selection: $settings.value.systemAudioBackend) {
                        Text("Core Audio (recommended)").tag(SystemAudioBackend.processTap.rawValue)
                        Text("ScreenCaptureKit").tag(SystemAudioBackend.screenCaptureKit.rawValue)
                    }
                }
            } header: {
                Text("The other side")
            } footer: {
                Text(systemAudioFooter)
            }

            Section("Permissions") {
                PermissionRow(title: "Microphone", status: permissions.microphone, pane: .microphone) {
                    _ = await AudioPermissions.requestMicrophone()
                }
                if settings.value.systemAudio != .off {
                    if settings.value.systemAudioBackend == SystemAudioBackend.screenCaptureKit.rawValue {
                        PermissionRow(title: "Screen Recording", status: permissions.screenRecording, pane: .screenRecording) {
                            _ = CGRequestScreenCaptureAccess()
                        }
                    } else {
                        PermissionRow(title: "System Audio Recording", status: permissions.systemAudio, pane: .systemAudio) {
                            _ = await AudioPermissions.requestSystemAudio()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recording")
        .onAppear { microphones = AudioDevices.inputs() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            permissions = PermissionSnapshot.current()
        }
    }

    private var systemAudioFooter: String {
        switch settings.value.systemAudio {
        case .everything: return "Records whatever this Mac plays, from any app, so it works with every call app and browser."
        case .meetingApp: return "When a recording starts from a meeting notification, only that app is recorded. Other recordings capture everything."
        case .selectedApps: return "Only these apps are recorded, including their helper processes (browsers play calls from helpers)."
        case .off: return "Only your microphone is recorded. Speaker detection still separates voices in the room."
        }
    }
}

struct PermissionSnapshot: Equatable {
    var microphone: AudioPermissions.Status
    var systemAudio: AudioPermissions.Status
    var screenRecording: AudioPermissions.Status

    static func current() -> PermissionSnapshot {
        PermissionSnapshot(microphone: AudioPermissions.microphone, systemAudio: AudioPermissions.systemAudio,
                           screenRecording: AudioPermissions.screenRecording)
    }
}

struct PermissionRow: View {
    let title: String
    let status: AudioPermissions.Status
    let pane: AudioPermissions.Pane
    let request: () async -> Void

    var body: some View {
        LabeledContent(title) {
            switch status {
            case .authorized:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notDetermined, .unknown:
                Button("Allow…") { Task { await request() } }
            case .denied:
                Button("Open Privacy Settings…") { NSWorkspace.shared.open(AudioPermissions.settingsURL(for: pane)) }
            }
        }
    }
}

/// Picks apps (by bundle ID) whose audio is recorded.
struct AppListEditor: View {
    @Binding var bundleIDs: [String]

    var body: some View {
        ForEach(bundleIDs, id: \.self) { bundleID in
            HStack {
                appIcon(bundleID)
                Text(appName(bundleID))
                Spacer()
                Button { bundleIDs.removeAll { $0 == bundleID } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        Menu("Add App") {
            ForEach(suggestions, id: \.self) { bundleID in
                Button(appName(bundleID)) { bundleIDs.append(bundleID) }
            }
            Divider()
            Button("Choose…") { choose() }
        }
        .fixedSize()
    }

    private var suggestions: [String] {
        let known = MeetingDetector.knownApps.keys.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
        return Array(Set(known + running)).filter { !bundleIDs.contains($0) && $0 != Bundle.main.bundleIdentifier }
            .sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }

    private func appName(_ bundleID: String) -> String {
        if let name = MeetingDetector.knownApps[bundleID] { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @ViewBuilder
    private func appIcon(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "app").frame(width: 18, height: 18)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleIDs.contains(bundleID) else { return }
        bundleIDs.append(bundleID)
    }
}

struct TranscriptionSettingsView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(AppState.self) private var appState
    @Environment(ExternalTranscriber.self) private var external
    @Environment(SpeakerFinder.self) private var speakers
    @Environment(PipelineSetup.self) private var setup
    @Environment(\.appActions) private var actions

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Transcriber", selection: $settings.value.transcriber) {
                    ForEach(Settings.TranscriberChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                if settings.value.transcriber == .external {
                    Text("When a recording stops, EchoPad finds the speakers and runs the Notetaker pipeline built into the app: it transcribes with Qwen3-ASR on this Mac, saves the transcript in your vault and has Claude draft a meeting note in your Log Book.")
                }
            }
            if settings.value.transcriber == .external {
                pipelineSections
            } else {
                builtInSections
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
    }

    @ViewBuilder
    private var builtInSections: some View {
        @Bindable var settings = settings
        Section {
            Picker("Language", selection: $settings.value.language) {
                Text("Detect automatically").tag("auto")
                Divider()
                ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
            }
        } footer: {
            Text("Parakeet v3 understands 25 European languages. Choosing one helps with short or mixed recordings.")
        }
        Section {
            Toggle("Identify speakers", isOn: $settings.value.identifySpeakers)
            TextField("Your name", text: $settings.value.myName, prompt: Text("Me"))
        } footer: {
            Text("Voices on the system track are told apart and labelled Speaker 1, Speaker 2… You can rename them in each conversation.")
        }
        Section("Speech model") {
            LabeledContent("Model", value: "Parakeet TDT 0.6B v3 + pyannote")
            LabeledContent("Status") { modelStatus }
            LabeledContent("Runs on", value: "Apple Neural Engine, fully offline")
        }
    }

    @ViewBuilder
    private var pipelineSections: some View {
        @Bindable var settings = settings
        Section {
            LabeledContent("Pipeline") { pipelineSummary }
            LabeledContent("Speaker model") { speakerModelStatus }
            LabeledContent("Speech recognition") { speechStatus }
            LabeledContent("Claude") { claudeStatus }
            claudeInstructions
            Button("Set Up Pipeline") {
                Task { await runSetup() }
            }
            .disabled(setup.isRunning || setup.isComplete || appState.phase.isBusy || isChecking)
        } header: {
            Text("Pipeline")
        } footer: {
            Text("Set Up Pipeline downloads the speaker model (30 MB), creates the pipeline's Python environment, downloads Qwen3-ASR (4.1 GB) once, and checks that Claude Code is logged in.")
        }
        .task { await setup.refresh() }

        Section {
            LabeledContent("Vault folder") {
                HStack {
                    Text(settings.value.vaultPath.isEmpty ? "Not chosen" : (settings.value.vaultPath as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(settings.value.vaultPath.isEmpty ? .orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseVault() }
                }
            }
            TextField("Log Book subfolder", text: $settings.value.logBookFolder, prompt: Text(Settings.DEFAULT_LOG_BOOK_FOLDER))
            TextField("Transcripts subfolder", text: $settings.value.transcriptsFolder,
                      prompt: Text(Settings.DEFAULT_TRANSCRIPTS_FOLDER))
            TextField("Glossary", text: $settings.value.glossaryPath, prompt: Text(Settings.DEFAULT_GLOSSARY_PATH))
            TextField("Your name", text: $settings.value.myName, prompt: Text("Me"))
        } header: {
            Text("Obsidian")
        } footer: {
            Text("The vault is required. Folders and the glossary note are relative to it. Exclude the transcripts subfolder from Obsidian Sync so transcripts stay on this Mac. Your name labels your microphone in calls.")
        }

        Section {
            Stepper(value: $settings.value.transcriptRetentionDays, in: 0...365) {
                Text("Keep transcripts for \(settings.value.transcriptRetentionDays) \(settings.value.transcriptRetentionDays == 1 ? "day" : "days")")
            }
            Picker("Draft with", selection: $settings.value.draftModel) {
                ForEach(Settings.DraftModel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Look up the meeting in Outlook", isOn: $settings.value.looksUpCalendar)
        } header: {
            Text("Notes")
        } footer: {
            Text("A transcript can say retain: keep or retain: none to override how long it is kept. The Outlook lookup gives the note its title and attendees.")
        }
    }

    private var isChecking: Bool {
        external.pipeline == .checking || setup.claude == .checking
    }

    /// Set Up Pipeline, with each step in the Pipeline row and the pill.
    private func runSetup() async {
        let appState = self.appState
        let problem = await setup.run { step in
            guard !appState.phase.isRecording else { return }
            appState.transition(to: .processing(.external(step)))
        }
        guard case .processing(.external) = appState.phase else { return }
        if let problem {
            appState.transition(to: .error(problem), resetAfter: 6)
        } else {
            appState.transition(to: .idle)
        }
    }

    @ViewBuilder
    private var pipelineSummary: some View {
        if let progress = setup.progress {
            HStack {
                ProgressView().controlSize(.small)
                Text(progress).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            let text = setup.summary(vaultChosen: !settings.value.vaultPath.isEmpty)
            switch text {
            case "Ready": Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case "Checking…":
                HStack {
                    ProgressView().controlSize(.small)
                    Text(text).foregroundStyle(.secondary)
                }
            default: Text(text).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var speechStatus: some View {
        switch external.pipeline {
        case .unknown: Text("Unknown").foregroundStyle(.secondary)
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing(let what): Text("Missing: \(what)").foregroundStyle(.orange)
        case .settingUp(let stage):
            HStack {
                ProgressView().controlSize(.small)
                Text(stage).foregroundStyle(.secondary).lineLimit(1)
            }
        case .failed(let message): Text(message).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    @ViewBuilder
    private var claudeStatus: some View {
        switch setup.claude {
        case .unknown: Text("Unknown").foregroundStyle(.secondary)
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .ready: Label("Claude: ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notLoggedIn: Text("Claude: not logged in").foregroundStyle(.orange)
        case .notInstalled: Text("Claude: not installed").foregroundStyle(.orange)
        case .failed(let message): Text(message).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    /// One line on what to do when Claude Code is missing or logged out; EchoPad never logs in itself.
    @ViewBuilder
    private var claudeInstructions: some View {
        switch setup.claude {
        case .notLoggedIn:
            HStack {
                Text("In Terminal, run \(Text(ClaudeCLI.LOGIN_COMMAND).font(.body.monospaced())), then set up again.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ClaudeCLI.LOGIN_COMMAND, forType: .string)
                }
            }
        case .notInstalled:
            HStack {
                Text("Install Claude Code, log in, then set up again.").foregroundStyle(.secondary)
                Spacer()
                Link("Install Page", destination: ClaudeCLI.INSTALL_PAGE)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var speakerModelStatus: some View {
        switch speakers.model {
        case .unknown: Text("Unknown").foregroundStyle(.secondary)
        case .notDownloaded: Text("Not downloaded").foregroundStyle(.orange)
        case .downloading(let detail):
            HStack {
                ProgressView().controlSize(.small)
                Text(detail).foregroundStyle(.secondary).lineLimit(1)
            }
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Text(message).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.message = "Choose your Obsidian vault (the folder that contains .obsidian)."
        if !settings.value.vaultPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: settings.value.vaultPath) }
        if panel.runModal() == .OK, let url = panel.url { settings.value.vaultPath = url.path }
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch appState.model {
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notLoaded: Text("Not loaded").foregroundStyle(.secondary)
        case .loading(let fraction, let detail):
            HStack {
                if let fraction { ProgressView(value: fraction).frame(width: 100) } else { ProgressView().controlSize(.small) }
                Text(detail).foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack {
                Text(message).foregroundStyle(.secondary).lineLimit(2)
                Button("Try Again", action: actions.retryModel)
            }
        }
    }
}

enum Languages {
    struct Language { let code: String; let name: String }

    /// Parakeet v3 languages, by English name.
    static let all: [Language] = [
        ("bg", "Bulgarian"), ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"),
        ("en", "English"), ("et", "Estonian"), ("fi", "Finnish"), ("fr", "French"), ("de", "German"),
        ("el", "Greek"), ("hu", "Hungarian"), ("it", "Italian"), ("lv", "Latvian"), ("lt", "Lithuanian"),
        ("mt", "Maltese"), ("pl", "Polish"), ("pt", "Portuguese"), ("ro", "Romanian"), ("ru", "Russian"),
        ("sk", "Slovak"), ("sl", "Slovenian"), ("es", "Spanish"), ("sv", "Swedish"), ("uk", "Ukrainian"),
    ].map { Language(code: $0.0, name: $0.1) }
}

struct GeneralSettingsView: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Shortcut") {
                LabeledContent("Start or stop recording") { HotkeyRecorder(hotkey: $settings.value.hotkey) }
            }
            Section {
                Toggle("Notify me when a call starts", isOn: $settings.value.detectsMeetings)
            } header: {
                Text("Meetings")
            } footer: {
                Text("When Zoom, Teams, Meet, Slack, FaceTime or another call app starts using the microphone, EchoPad offers to record. Recordings started this way stop when the call ends.")
            }
            Section("While recording") {
                Toggle("Show the floating recording pill", isOn: $settings.value.showsPill)
                Toggle("Play sounds", isOn: $settings.value.playsSounds)
                Toggle("Ask for a title when stopping", isOn: $settings.value.asksForTitle)
            }
            Section {
                Picker("Keep audio of the last", selection: $settings.value.libraryLimit) {
                    ForEach(Settings.LIBRARY_LIMITS, id: \.self) { limit in
                        Text(limit == 0 ? "None" : "\(limit) conversations").tag(limit)
                    }
                }
                Button("Show Library in Finder") { NSWorkspace.shared.open(AppDirectories.library) }
            } header: {
                Text("Library")
            } footer: {
                Text("EchoPad keeps the original tracks so you can transcribe again. Transcripts in your save locations are never deleted.")
            }
            Section {
                LaunchAtLoginToggle()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
            Text("EchoPad").font(.largeTitle.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Transcribes your calls and conversations on this Mac, with speakers, and saves them wherever you want. Nothing leaves your computer.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://echopad.lucaspiera.com")!)
                Link("Source", destination: URL(string: "https://github.com/pieralukasz/echopad")!)
            }
            Text("Built with ScribeKit, SystemAudioKit and FluidAudio.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}
