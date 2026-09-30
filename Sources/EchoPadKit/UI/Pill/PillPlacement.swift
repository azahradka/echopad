import CoreGraphics

/// Where the user left the pill, stored relative to the visible screen area so
/// the spot carries over to other displays. `nil` means the default spot,
/// centred just above the Dock.
struct PillPlacement: Codable, Equatable {
    /// Horizontal centre of the panel as a fraction of the visible width, 0...1.
    var centerX: Double
    /// Gap between the bottom of the visible area and the panel, in points.
    var bottom: Double

    /// A drop this close to the default spot, or to the centre line, snaps to it.
    static let SNAP: CGFloat = 24

    /// The panel origin for `placement`, kept fully inside `visible`.
    static func origin(for placement: PillPlacement?, size: CGSize, in visible: CGRect, defaultBottom: CGFloat) -> CGPoint {
        let centerX = placement.map { visible.minX + CGFloat($0.centerX) * visible.width } ?? visible.midX
        let bottom = placement.map { CGFloat($0.bottom) } ?? defaultBottom
        return clamp(CGPoint(x: centerX - size.width / 2, y: visible.minY + bottom), size: size, in: visible)
    }

    /// Keeps a panel of `size` inside `visible`.
    static func clamp(_ origin: CGPoint, size: CGSize, in visible: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        )
    }

    /// The placement for a panel dropped at `origin`, or `nil` when the drop
    /// is close enough to the default spot to snap back to it.
    static func placement(droppedAt origin: CGPoint, size: CGSize, in visible: CGRect, defaultBottom: CGFloat) -> PillPlacement? {
        let home = self.origin(for: nil, size: size, in: visible, defaultBottom: defaultBottom)
        if hypot(origin.x - home.x, origin.y - home.y) <= SNAP { return nil }
        var centerX = origin.x + size.width / 2
        if abs(centerX - visible.midX) <= SNAP { centerX = visible.midX }
        return PillPlacement(
            centerX: Double((centerX - visible.minX) / visible.width),
            bottom: Double(origin.y - visible.minY)
        )
    }
}
