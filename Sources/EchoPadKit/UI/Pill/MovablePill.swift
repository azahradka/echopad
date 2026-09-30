import AppKit
import Observation
import SwiftUI

/// Lets the user drag the floating pill anywhere and close it. The panel
/// stays click-through except right over the pill, and the spot is
/// remembered between launches.
@MainActor
@Observable
final class MovablePill {
    static let DEFAULTS_KEY = "pillPlacement"
    /// Extra room around the pill that still counts as "over it", so the
    /// close badge on its corner can be reached.
    static let HIT_SLACK: CGFloat = 12
    static let POLL_INTERVAL: TimeInterval = 1.0 / 20

    /// True while the pointer is over the pill; shows the close badge.
    private(set) var isHovered = false
    /// Set by `close()`, cleared by the controller once there is nothing to show.
    private(set) var isDismissed = false

    @ObservationIgnored let panel: NSPanel
    @ObservationIgnored var onDismiss: () -> Void = {}
    @ObservationIgnored private let defaultBottom: CGFloat
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var placement: PillPlacement?
    @ObservationIgnored private var pillFrame: CGRect = .zero
    @ObservationIgnored private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var dragMonitor: Any?

    /// Pass `defaults: nil` to neither read nor write the saved spot.
    init(panel: NSPanel, defaultBottom: CGFloat, defaults: UserDefaults? = .standard) {
        self.panel = panel
        self.defaultBottom = defaultBottom
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.DEFAULTS_KEY) {
            placement = try? JSONDecoder().decode(PillPlacement.self, from: data)
        }
        panel.ignoresMouseEvents = true
    }

    // MARK: Controller

    /// Moves the panel to the saved spot on the screen the pointer is on.
    func place() {
        guard let visible = Self.screen(containing: NSEvent.mouseLocation)?.visibleFrame else { return }
        let origin = PillPlacement.origin(for: placement, size: panel.frame.size, in: visible, defaultBottom: defaultBottom)
        panel.setFrameOrigin(origin)
    }

    func didShow() {
        panel.alphaValue = 1
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: Self.POLL_INTERVAL, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHitTesting() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        updateHitTesting()
    }

    func didHide() {
        pollTimer?.invalidate()
        pollTimer = nil
        endDrag()
        isHovered = false
        panel.ignoresMouseEvents = true
    }

    func clearDismissal() {
        isDismissed = false
    }

    // MARK: View

    /// Hides the pill until the current recording is over.
    func close() {
        guard !isDismissed else { return }
        isDismissed = true
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }
        onDismiss()
    }

    /// Starts moving the panel with the pointer. The panel moves under the
    /// cursor, so SwiftUI stops seeing any change; the drag follows AppKit's
    /// mouse events instead, until the button is released.
    func beginDrag() {
        guard dragStart == nil else { return }
        dragStart = (NSEvent.mouseLocation, panel.frame.origin)
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseUp { self.endDrag() } else { self.follow() }
            return event
        }
    }

    private func follow() {
        let mouse = NSEvent.mouseLocation
        guard let start = dragStart,
              let visible = Self.screen(containing: mouse)?.visibleFrame else { return }
        let origin = CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y)
        panel.setFrameOrigin(PillPlacement.clamp(origin, size: panel.frame.size, in: visible))
    }

    func endDrag() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        guard dragStart != nil else { return }
        dragStart = nil
        let frame = panel.frame
        guard let visible = Self.screen(containing: CGPoint(x: frame.midX, y: frame.midY))?.visibleFrame else { return }
        placement = PillPlacement.placement(droppedAt: frame.origin, size: frame.size, in: visible, defaultBottom: defaultBottom)
        save()
        if placement == nil { settle(in: visible) }
    }

    /// Puts the pill back above the Dock.
    func reset() {
        placement = nil
        save()
        if let visible = (panel.screen ?? Self.screen(containing: NSEvent.mouseLocation))?.visibleFrame {
            settle(in: visible)
        }
    }

    /// Where the pill is drawn, in the hosting view's top-left coordinates.
    func reportFrame(_ frame: CGRect) {
        pillFrame = frame
    }

    // MARK: Private

    private func settle(in visible: CGRect) {
        let origin = PillPlacement.origin(for: placement, size: panel.frame.size, in: visible, defaultBottom: defaultBottom)
        panel.setFrame(NSRect(origin: origin, size: panel.frame.size), display: true, animate: true)
    }

    /// Takes clicks only over the pill, so the rest of the panel never
    /// blocks the app underneath.
    private func updateHitTesting() {
        guard !isDismissed else { return }
        let inside = hitRect.contains(NSEvent.mouseLocation)
        let active = inside || dragStart != nil
        if panel.ignoresMouseEvents == active { panel.ignoresMouseEvents = !active }
        if isHovered != active { isHovered = active }
    }

    /// The pill's rect on screen, with some slack for the close badge.
    private var hitRect: CGRect {
        guard !pillFrame.isEmpty else { return .null }
        let frame = panel.frame
        let rect = CGRect(
            x: frame.minX + pillFrame.minX,
            y: frame.maxY - pillFrame.maxY,
            width: pillFrame.width,
            height: pillFrame.height
        )
        return rect.insetBy(dx: -Self.HIT_SLACK, dy: -Self.HIT_SLACK)
    }

    private func save() {
        guard let defaults else { return }
        if let placement, let data = try? JSONEncoder().encode(placement) {
            defaults.set(data, forKey: Self.DEFAULTS_KEY)
        } else {
            defaults.removeObject(forKey: Self.DEFAULTS_KEY)
        }
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}

/// Buttons on the pill work on the first click, even though the panel is
/// never the key window.
final class PillHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension View {
    /// Makes the pill draggable, adds a close badge on hover and a context
    /// menu. With `nil` the pill stays put, as in screenshots.
    func movablePill(_ mover: MovablePill?, closeLabel: String) -> some View {
        modifier(MovablePillModifier(mover: mover, closeLabel: closeLabel))
    }
}

private struct MovablePillModifier: ViewModifier {
    let mover: MovablePill?
    let closeLabel: String

    func body(content: Content) -> some View {
        if let mover {
            content
                .contentShape(.capsule)
                .overlay(alignment: .topLeading) {
                    if mover.isHovered {
                        Button(action: mover.close) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: .circle)
                        .offset(x: -6, y: -6)
                        .help(closeLabel)
                        .accessibilityLabel(closeLabel)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: mover.isHovered)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { _ in mover.beginDrag() }
                        .onEnded { _ in mover.endDrag() }
                )
                .contextMenu {
                    Button(closeLabel, action: mover.close)
                    Button("Move Back Above the Dock", action: mover.reset)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mover.reportFrame($0) }
        } else {
            content
        }
    }
}
