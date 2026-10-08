import ScribeKit
import SwiftUI
import SystemAudioKit

/// The menu bar popover: status, one big record button, where it will be saved, recent conversations.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsModel.self) private var settings
    @Environment(ConversationLibrary.self) private var library
    @Environment(\.appActions) private var actions

    static let WIDTH: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            recordButton
            if appState.phase.isRecording { recordingDetails } else { destinationPicker }
            if !library.conversations.isEmpty { recent }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: Self.WIDTH)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(StatusText.color(appState)).frame(width: 8, height: 8)
            Text(StatusText.title(appState)).font(.headline)
            Spacer()
            if let meeting = appState.detectedMeeting, !appState.phase.isRecording {
                Label(meeting, systemImage: "video.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        let recording = appState.phase.isRecording
        Button(action: actions.toggleRecording) {
            HStack(spacing: 10) {
                Image(systemName: recording ? "stop.fill" : "record.circle")
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                if recording, case .recording(let since) = appState.phase {
                    Text("Stop")
                    Spacer()
                    ElapsedText(start: since).foregroundStyle(.secondary)
                } else {
                    Text("Start Recording")
                    Spacer()
                    Text(HotkeyLabel.describe(settings.value.hotkey))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glassProminent)
        .tint(recording ? .red : .accentColor)
        .disabled(!recording && appState.phase.isBusy)
    }

    @ViewBuilder
    private var recordingDetails: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $appState.currentTitle)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                levelRow("mic.fill", appState.microphoneLevels)
                if settings.value.systemAudio != .off {
                    levelRow("speaker.wave.2.fill", appState.systemLevels)
                }
            }
            if let notice = appState.microphoneNotice {
                Label(notice, systemImage: "laptopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if appState.systemAudioLooksSilent {
                Label("No sound from the other side. Check System Audio Recording in Privacy settings.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .symbolRenderingMode(.multicolor)
            }
            destinationPicker
            Button("Discard Recording", role: .destructive, action: actions.discardRecording)
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private func levelRow(_ symbol: String, _ levels: [Float]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary).frame(width: 14)
            WaveformView(levels: Array(levels.suffix(16)), barWidth: 2.5, spacing: 2, maxHeight: 14, minHeight: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var destinationPicker: some View {
        @Bindable var appState = appState
        let destinations = settings.value.destinations
        HStack {
            Label("Save to", systemImage: "folder").foregroundStyle(.secondary)
            Spacer()
            Picker("Save to", selection: Binding(
                get: { appState.currentDestinationID ?? settings.value.defaultDestinationID },
                set: { appState.currentDestinationID = $0 })) {
                ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .font(.callout)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(library.conversations.prefix(3)) { conversation in
                Button { actions.openConversation(conversation.id) } label: {
                    HStack {
                        Text(conversation.title).lineLimit(1)
                        Spacer()
                        ConversationStatusBadge(conversation: conversation, compact: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open EchoPad") { actions.openMainWindow(nil) }
            Spacer()
            Button { actions.openMainWindow(.general) } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button { actions.quit() } label: { Image(systemName: "power") }
                .help("Quit EchoPad")
        }
        .buttonStyle(.borderless)
    }
}

/// A small status marker for a conversation row.
struct ConversationStatusBadge: View {
    let conversation: Conversation
    var compact = false

    var body: some View {
        switch conversation.status {
        case .done:
            Text(compact ? relative : durationText(conversation.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .transcribing, .recorded:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.caption)
        }
    }

    private var relative: String {
        conversation.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

