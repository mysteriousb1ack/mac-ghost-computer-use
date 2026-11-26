import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import MacGhostHelper

// Exercise the production renderer in memory, with no window, capture or input event.
final class NativeChecks: XCTestCase {
    func testRenderedGrid() throws {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 90))
        let original = ctx.makeImage()!
        let painted = try drawGrid(original, (4, 3))
        let pixels = NSBitmapImageRep(cgImage: painted)
        let baseline = NSBitmapImageRep(cgImage: original)
        func changed(_ x: Int, _ y: Int) -> Bool {
            let c = pixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            let before = baseline.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return abs(c.redComponent - before.redComponent) + abs(c.greenComponent - before.greenComponent)
                + abs(c.blueComponent - before.blueComponent) > 0.15
        }
        // Bitmap row ordering varies by API; both rows border the vertical line.
        let ruler = changed(100, 150) || changed(99, 150)
        let interior = changed(65, 150) || changed(65, 245) || changed(65, 55)
        let horizontal = changed(65, 100) || changed(65, 99)
        let label = (3..<40).contains { x in (3..<24).contains { y in changed(x, y) } }
        XCTAssertEqual(painted.width, 400)
        XCTAssertEqual(painted.height, 300)
        XCTAssertTrue(ruler)
        XCTAssertTrue(horizontal)
        XCTAssertTrue(label)
        XCTAssertFalse(interior)
    }
}

extension NativeChecks {
    func testCropSelectsTopLeftImageRowsBeforeGrid() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 50, width: 50, height: 50))
        let image = try XCTUnwrap(ctx.makeImage())
        let geometry = CaptureGeometry(crop: Crop(x: 0.1, y: 0.1, width: 0.2, height: 0.2), width: 100, height: 100, window: CGSize(width: 50, height: 50))
        let clipped = try geometry.clip(image)
        XCTAssertEqual(clipped.width, 20)
        XCTAssertEqual(clipped.height, 20)
        let pixels = NSBitmapImageRep(cgImage: clipped)
        let color = try XCTUnwrap(pixels.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.9)
        XCTAssertLessThan(color.blueComponent, 0.1)
    }

    func testGuardrailsPruneSensitiveNodesBeforeSearchingValuesOrChildren() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let rules = try JSONDecoder().decode(Guardrails.self, from: Data(contentsOf: root.appendingPathComponent("src/guardrails.json")))
        for node in [("", "", "", ""), ("AXTextField", "AXSecureTextField", "", ""),
                     ("AXWindow", "AXSystemDialog", "", ""), ("AXGroup", "", "Apple Pay", ""),
                     ("AXTextField", "", "", "输入密码")] {
            XCTAssertTrue(rules.protectedControl(role: node.0, subrole: node.1, title: node.2, description: node.3))
        }
        XCTAssertFalse(rules.protectedControl(role: "AXButton", subrole: "", title: "保存", description: ""))
    }
}
