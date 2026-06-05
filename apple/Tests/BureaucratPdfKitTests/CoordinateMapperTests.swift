import XCTest
import CoreGraphics
@testable import BureaucratPdfKit

final class CoordinateMapperTests: XCTestCase {
    let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)

    private func assertRectClose(_ a: CGRect, _ b: CGRect, tol: CGFloat = 0.01, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: tol, "minX \(msg)", file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: tol, "minY \(msg)", file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: tol, "w \(msg)", file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: tol, "h \(msg)", file: file, line: line)
    }

    // MARK: displayed size swaps for 90/270

    func testDisplayedSizeRotation() {
        XCTAssertEqual(CoordinateMapper(cropBox: a4, rotation: 0).displayedSize, CGSize(width: 595, height: 842))
        XCTAssertEqual(CoordinateMapper(cropBox: a4, rotation: 180).displayedSize, CGSize(width: 595, height: 842))
        XCTAssertEqual(CoordinateMapper(cropBox: a4, rotation: 90).displayedSize, CGSize(width: 842, height: 595))
        XCTAssertEqual(CoordinateMapper(cropBox: a4, rotation: 270).displayedSize, CGSize(width: 842, height: 595))
    }

    func testRotationNormalization() {
        XCTAssertEqual(CoordinateMapper(cropBox: a4, rotation: 360).rotation, 0)
        XCTAssertEqual(CoordinateMapper(cropBox: a4, rotation: -90).rotation, 270)
        XCTAssertEqual(CoordinateMapper(cropBox: a4, rotation: 450).rotation, 90)
    }

    // MARK: known mapping, rotation 0

    func testUserSpaceRotation0() {
        let m = CoordinateMapper(cropBox: a4, rotation: 0)
        // top-left 10%/10%, 20% wide, 10% tall.
        let n = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let r = m.userSpaceRect(normalized: n)
        assertRectClose(r, CGRect(x: 59.5, y: 673.6, width: 119, height: 84.2), tol: 0.05)
    }

    // MARK: corner landing per rotation
    // A small box hugging the displayed TOP-LEFT corner.

    func testTopLeftCornerAllRotations() {
        let n = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        // rot 0: displayed top-left == user-space top-left of cropBox.
        let r0 = CoordinateMapper(cropBox: a4, rotation: 0).userSpaceRect(normalized: n)
        assertRectClose(r0, CGRect(x: 0, y: 842 - 84.2, width: 59.5, height: 84.2), tol: 0.05, "rot0")
        // rot 180: displayed top-left maps to user-space bottom-right.
        let r180 = CoordinateMapper(cropBox: a4, rotation: 180).userSpaceRect(normalized: n)
        assertRectClose(r180, CGRect(x: 595 - 59.5, y: 0, width: 59.5, height: 84.2), tol: 0.05, "rot180")
    }

    // MARK: round-trip property — normalized → user → normalized

    func testRoundTripNormalizedAllRotations() {
        let boxes = [
            CGRect(x: 0.0, y: 0.0, width: 0.3, height: 0.2),
            CGRect(x: 0.5, y: 0.6, width: 0.4, height: 0.3),
            CGRect(x: 0.12, y: 0.34, width: 0.2, height: 0.15),
        ]
        for rot in [0, 90, 180, 270] {
            let m = CoordinateMapper(cropBox: a4, rotation: rot)
            for n in boxes {
                let user = m.userSpaceRect(normalized: n)
                let back = m.normalizedRect(userSpace: user)
                assertRectClose(back, n, tol: 0.0001, "rot \(rot) box \(n)")
            }
        }
    }

    // MARK: cropBox origin offset is honored

    func testCropBoxOffset() {
        let cb = CGRect(x: 10, y: 20, width: 595, height: 842)
        let m = CoordinateMapper(cropBox: cb, rotation: 0)
        let n = CGRect(x: 0, y: 0, width: 0.1, height: 0.1) // top-left
        let r = m.userSpaceRect(normalized: n)
        // x offset by cropBox.minX, top edge offset by cropBox.minY.
        assertRectClose(r, CGRect(x: 10, y: 20 + 842 - 84.2, width: 59.5, height: 84.2), tol: 0.05)
    }

    // MARK: zoom independence — view-space rect normalizes identically at any scale

    func testZoomIndependenceNormalize() {
        let m = CoordinateMapper(cropBox: a4, rotation: 0)
        // Same logical box (10%..30% x, 10%..20% y) at different render scales.
        for scale in [0.25, 0.5, 1.0, 2.0, 4.0] {
            let pageFrame = CGRect(x: 0, y: 0, width: 595 * scale, height: 842 * scale)
            let viewRect = CGRect(
                x: 0.1 * pageFrame.width, y: 0.1 * pageFrame.height,
                width: 0.2 * pageFrame.width, height: 0.1 * pageFrame.height)
            let n = m.normalize(viewRect: viewRect, in: pageFrame)
            assertRectClose(n, CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), tol: 0.0001, "scale \(scale)")
        }
    }

    // MARK: view rect round-trip

    func testViewRectRoundTrip() {
        let m = CoordinateMapper(cropBox: a4, rotation: 0)
        let pageFrame = CGRect(x: 30, y: 40, width: 595, height: 842)
        let viewRect = CGRect(x: 100, y: 120, width: 200, height: 80)
        let n = m.normalize(viewRect: viewRect, in: pageFrame)
        let back = m.viewRect(normalized: n, in: pageFrame)
        assertRectClose(back, viewRect, tol: 0.0001)
    }

    // MARK: full pipeline within ±2pt acceptance (view → user space)

    func testFullPipelineAccuracy() {
        let m = CoordinateMapper(cropBox: a4, rotation: 90)
        let pageFrame = CGRect(x: 0, y: 0, width: 842, height: 595) // displayed (rotated) at 100%
        let viewRect = CGRect(x: 84.2, y: 59.5, width: 168.4, height: 59.5)
        let n = m.normalize(viewRect: viewRect, in: pageFrame)
        let user = m.userSpaceRect(normalized: n)
        // Re-derive the view rect from the user space rect; must land within 2pt.
        let back = m.viewRect(normalized: m.normalizedRect(userSpace: user), in: pageFrame)
        assertRectClose(back, viewRect, tol: 2.0)
    }

    func testClampingOutOfBounds() {
        let m = CoordinateMapper(cropBox: a4, rotation: 0)
        let pageFrame = CGRect(x: 0, y: 0, width: 595, height: 842)
        // Rect partly off the top-left and oversized.
        let viewRect = CGRect(x: -50, y: -50, width: 700, height: 1000)
        let n = m.normalize(viewRect: viewRect, in: pageFrame)
        XCTAssertGreaterThanOrEqual(n.minX, 0)
        XCTAssertGreaterThanOrEqual(n.minY, 0)
        XCTAssertLessThanOrEqual(n.maxX, 1.0001)
        XCTAssertLessThanOrEqual(n.maxY, 1.0001)
    }
}
