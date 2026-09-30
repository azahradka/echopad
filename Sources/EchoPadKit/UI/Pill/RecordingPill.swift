import AppKit
import SwiftUI

/// One piece of Liquid Glass at the bottom of the screen while recording: a red dot,
/// the elapsed time, a waveform and a stop button. It morphs into dots while
/// transcribing and into a check mark when the files are saved.
struct RecordingPillView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appActions) private var actions
    @Namespace private var namespace
    /// Drag and close support; `nil` keeps the pill still.
    var mover: MovablePill?

    static let HEIGHT: CGFloat = 44
    static let MORPH = Animation.spring(response: 0.42, dampingFraction: 0.72)

    var body: some View {
        GlassEffectContainer {
            if let content = PillContent(phase: appState.phase) {
                shape(for: content)
                    .glassEffect(content.glass, in: .capsule)
                    .glassEffectID("pill", in: namespace)
                    .movablePill(mover, closeLabel: "Hide for This Recording")
                    .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 10)
        .animation(Self.MORPH, value: PillContent(phase: appState.phase))
    }

    @ViewBuilder
    private func shape(for content: PillContent) -> some View {
        switch content {
        case .recording(let since):
            HStack(spacing: 12) {
                RecordingDot()
                ElapsedText(start: since)
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 44, alignment: .leading)
                WaveformView(levels: appState.combinedLevels, maxHeight: 20)
                if appState.systemAudioLooksSilent {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundStyle(.yellow)
                        .help("No sound from the other side yet. Check the system audio permission.")
                }
                Button(action: actions.toggleRecording) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Stop and transcribe")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: Self.HEIGHT)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recording")
        case .working(let text):
            HStack(spacing: 10) {
                WorkingDots()
                Text(text).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 18)
            .frame(height: Self.HEIGHT)
        case .saved:
            Label("Saved", systemImage: "checkmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 18)
                .frame(height: Self.HEIGHT)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .symbolRenderingMode(.multicolor)
                .lineLimit(2)
                .padding(.horizontal, 18)
                .frame(minHeight: Self.HEIGHT)
                .frame(maxWidth: 420)
        }
    }
}

enum PillContent: Equatable {
    case recording(since: Date)
    case working(String)
    case saved
    case failed(String)

    init?(phase: Phase) {
        switch phase {
        case .recording(let since): self = .recording(since: since)
        case .processing(let step): self = .working(step.title.replacingOccurrences(of: "…", with: ""))
        case .saved: self = .saved
        case .error(let message): self = .failed(message)
        case .idle: return nil
        }
    }

    var glass: Glass {
        switch self {
        case .failed: return .regular.tint(.red.opacity(0.25))
        default: return .regular.interactive()
        }
    }
}

/// Hosts the pill in a floating panel above every app, on every Space. Only the
/// pill itself takes clicks: the stop button, dragging it anywhere and closing
/// it. The rest of the panel is click-through.
@MainActor
final class RecordingPillController {
    static let PANEL_SIZE = NSSize(width: 480, height: 80)
    static let BOTTOM_MARGIN: CGFloat = 12
    static let HIDE_DELAY: Duration = .milliseconds(450)

    private let appState: AppState
    let panel: NSPanel
    private let mover: MovablePill
    private var hideTask: Task<Void, Never>?

    var isEnabled = true {
        didSet { update() }
    }

    init(appState: AppState, content: (MovablePill) -> some View) {
        self.appState = appState
        panel = Self.makePanel()
        mover = MovablePill(panel: panel, defaultBottom: Self.BOTTOM_MARGIN)
        let host = PillHostingView(rootView: content(mover))
        host.frame = NSRect(origin: .zero, size: Self.PANEL_SIZE)
        panel.contentView = host
        mover.onDismiss = { [weak self] in self?.update() }
        observeContinuously({ [weak self] in _ = self?.appState.phase }, onChange: { [weak self] in self?.update() })
    }

    private func update() {
        hideTask?.cancel()
        // A closed pill comes back with the next recording, or to show a problem.
        let content = PillContent(phase: appState.phase)
        switch content {
        case nil, .failed: mover.clearDismissal()
        default: break
        }
        guard isEnabled, !mover.isDismissed, content != nil else {
            hideTask = Task { [panel, mover] in
                try? await Task.sleep(for: Self.HIDE_DELAY)
                guard !Task.isCancelled else { return }
                panel.orderOut(nil)
                mover.didHide()
            }
            return
        }
        if !panel.isVisible {
            // Follows the pointer to the screen the user is working on.
            mover.place()
            panel.orderFrontRegardless()
        }
        mover.didShow()
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: PANEL_SIZE),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}
