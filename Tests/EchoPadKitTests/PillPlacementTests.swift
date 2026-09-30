import CoreGraphics
import XCTest
@testable import EchoPadKit

final class PillPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 80, width: 1440, height: 800)
    private let size = CGSize(width: 360, height: 72)

    func testDefaultSpotIsCentredAboveTheBottom() {
        let origin = PillPlacement.origin(for: nil, size: size, in: visible, defaultBottom: 12)
        XCTAssertEqual(origin, CGPoint(x: 540, y: 92))
    }

    func testDropNearTheDefaultSpotSnapsBack() {
        let dropped = CGPoint(x: 550, y: 100)
        XCTAssertNil(PillPlacement.placement(droppedAt: dropped, size: size, in: visible, defaultBottom: 12))
    }

    func testDropFarAwayIsKeptAndRestored() throws {
        let dropped = CGPoint(x: 1000, y: 600)
        let placement = try XCTUnwrap(PillPlacement.placement(droppedAt: dropped, size: size, in: visible, defaultBottom: 12))
        let restored = PillPlacement.origin(for: placement, size: size, in: visible, defaultBottom: 12)
        XCTAssertEqual(restored.x, dropped.x, accuracy: 0.001)
        XCTAssertEqual(restored.y, dropped.y, accuracy: 0.001)
    }

    func testDropNearTheCentreLineSnapsToIt() throws {
        let dropped = CGPoint(x: 550, y: 600)
        let placement = try XCTUnwrap(PillPlacement.placement(droppedAt: dropped, size: size, in: visible, defaultBottom: 12))
        XCTAssertEqual(placement.centerX, 0.5)
    }

    func testPlacementCarriesOverToASmallerScreen() throws {
        let placement = PillPlacement(centerX: 0.95, bottom: 790)
        let small = CGRect(x: 1440, y: 0, width: 1024, height: 600)
        let origin = PillPlacement.origin(for: placement, size: size, in: small, defaultBottom: 12)
        XCTAssertEqual(origin, CGPoint(x: small.maxX - size.width, y: small.maxY - size.height))
    }

    func testClampKeepsThePanelOnScreen() {
        let origin = PillPlacement.clamp(CGPoint(x: -50, y: 2000), size: size, in: visible)
        XCTAssertEqual(origin, CGPoint(x: 0, y: visible.maxY - size.height))
    }
}
