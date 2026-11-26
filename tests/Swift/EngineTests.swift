import Foundation
import XCTest
@testable import MacGhostHelper

final class EngineTests: XCTestCase {
    typealias Snapshot = Frontmost<String>
    let front = Snapshot(pid: 10, bundle: "test.front", window: .focused("document A"))
    let target = Snapshot(pid: 20, bundle: "test.target", window: .focused("document X"))
    let second = Snapshot(pid: 10, bundle: "test.front", window: .focused("document B"))

    @MainActor
    func exercise(_ samples: [Snapshot], restore: Bool = false, targetPID: pid_t = 20, failing: Bool = false,
                  expectedRestores: Int = 0) async throws -> Object {
        var queue = samples, restores = 0, writes = 0
        defer {
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(restores, expectedRestores)
            XCTAssertTrue(queue.isEmpty)
        }
        let result = try await auditedWrite(target: targetPID, restoreRequested: restore, sample: {
            XCTAssertFalse(queue.isEmpty)
            return queue.isEmpty ? self.front : queue.removeFirst()
        }, settle: {}, restore: { snapshot, _ in
            restores += 1
            XCTAssertEqual(snapshot.pid, samples.first?.pid)
            return .requested
        }, write: {
            XCTAssertEqual(queue.count, samples.count - 1)
            writes += 1
            if failing { throw Failure("EVENT_ERROR", "partial write") }
            return ["delivery": "posted_unverified"]
        })
        return try XCTUnwrap(result["focusAudit"] as? Object)
    }

    @MainActor func testStableAndDelayedDriftWithoutRestore() async throws {
        let stable = try await exercise([front, front, front], restore: true)
        XCTAssertEqual(stable["focusPreserved"] as? Bool, true)
        XCTAssertNil(stable["restoration"])
        let moved = try await exercise([front, front, target])
        XCTAssertEqual(moved["status"] as? String, "changed")
        XCTAssertEqual((moved["afterFrontmost"] as? Object)?["pid"] as? pid_t, 20)
        XCTAssertNotNil(moved["warning"])
        XCTAssertNil(moved["restoration"])
    }

    @MainActor func testRestoreReobservedWithoutErasingDrift() async throws {
        for (last, expected) in [(front, "verified"), (target, "unverified")] {
            let moved = try await exercise([front, target, target, target, last], restore: true, expectedRestores: 1)
            XCTAssertEqual(moved["restoration"] as? String, expected)
            XCTAssertEqual(moved["focusPreserved"] as? Bool, false)
            XCTAssertEqual((moved["afterFrontmost"] as? Object)?["pid"] as? pid_t, target.pid)
            XCTAssertEqual((moved["afterRestoreFrontmost"] as? Object)?["pid"] as? pid_t, last.pid)
        }
    }

    @MainActor func testWindowOnlyDriftAndConcurrentForegroundChange() async throws {
        let switched = try await exercise([front, second, second, second, front], restore: true, targetPID: 10, expectedRestores: 1)
        XCTAssertEqual(switched["status"] as? String, "changed")
        let third = Snapshot(pid: 30, bundle: "test.third", window: .focused("document Z"))
        let concurrent = try await exercise([front, target, target, third], restore: true)
        XCTAssertEqual(concurrent["restoration"] as? String, "skipped_or_unavailable")
        let transient = try await exercise([front, target, front, front], restore: true)
        XCTAssertEqual(transient["focusPreserved"] as? Bool, false)
        XCTAssertEqual(transient["restoration"] as? String, "already_restored")
    }

    @MainActor func testUnknownNeverReportsPreservedAndFailureRetainsAudit() async throws {
        let missing = Snapshot(pid: 10, bundle: "test.front", window: .unknown)
        let result = try await exercise([front, missing, front], restore: true)
        XCTAssertEqual(result["focusPreserved"] as? Bool, false)
        XCTAssertEqual(result["status"] as? String, "unverified")
        do {
            _ = try await exercise([front, target, target], failing: true)
            XCTFail("Write should fail.")
        } catch let error as Failure {
            XCTAssertEqual(error.code, "EVENT_ERROR")
            XCTAssertEqual(error.focusAudit?["status"] as? String, "changed")
        }
    }

    func testAllSemanticPredicatesAndLazyReads() {
        let query = ControlQuery(role: "AXButton", title: "aBc", value: "文件", action: "AXPress", maxResults: 2)
        XCTAssertTrue(query.matches(role: "AXButton", title: "ABC导航", value: { "新文件" }, actions: { ["AXPress"] }))
        XCTAssertFalse(query.matches(role: "AXGroup", title: "abc", value: { XCTFail(); return nil }, actions: { XCTFail(); return [] }))
        XCTAssertFalse(query.matches(role: "AXButton", title: "other", value: { XCTFail(); return nil }, actions: { XCTFail(); return [] }))
        XCTAssertFalse(query.matches(role: "AXButton", title: "abc", value: { nil }, actions: { XCTFail(); return [] }))
        XCTAssertFalse(query.matches(role: "AXButton", title: "abc", value: { "文件" }, actions: { ["AXShowMenu"] }))
    }

    func testSearchKeepsOriginalIndicesAndStopsWhenBounded() throws {
        var calls = [Int]()
        let result = searchControls(roots: [(4, 0)], maxResults: 2, hasTime: { true }) { id, path in
            calls.append(id)
            let children = id == 0 ? [11, 12, 13, 14] : []
            return SearchNode(row: id == 12 || id == 13 ? ["nodeId": path] : nil, children: children)
        }
        XCTAssertEqual((result["controls"] as? [Object])?.compactMap { $0["nodeId"] as? String }, ["4/1", "4/2"])
        XCTAssertEqual(calls, [0, 11, 12, 13])
        XCTAssertEqual(result["truncated"] as? Bool, true)
        let timed = searchControls(roots: [(0, 0)], maxResults: 1, hasTime: { false }) { _, _ in
            XCTFail(); return SearchNode<Int>(row: nil, children: [])
        }
        XCTAssertEqual(timed["visited"] as? Int, 0)
        XCTAssertEqual(timed["truncated"] as? Bool, true)
    }

    func testDeepAndWideTreeMatchesBeyondInspectLimit() {
        let result = searchControls(roots: [(3, -1)], maxResults: 1, hasTime: { true }) { node, path in
            SearchNode(row: node == 1999 ? ["nodeId": path] : nil, children: node == -1 ? Array(0..<2000) : [])
        }
        XCTAssertEqual((result["controls"] as? [Object])?.first?["nodeId"] as? String, "3/1999")
        XCTAssertEqual(result["truncated"] as? Bool, false)
        let cyclic = searchControls(roots: [(0, 1)], maxResults: 1, hasTime: { true }) { id, _ in
            SearchNode(row: nil, children: [id])
        }
        XCTAssertEqual(cyclic["visited"] as? Int, 33)
        XCTAssertEqual(cyclic["truncated"] as? Bool, true)
    }

    func testPixelSnappingAndCellCentersInOriginalPoints() throws {
        let crop = try Crop.parse(#"{"x":0.101,"y":0.251,"width":0.4,"height":0.5}"#)
        let geometry = CaptureGeometry(crop: crop, width: 200, height: 100, window: CGSize(width: 100, height: 50))
        XCTAssertEqual(geometry.pixels, CGRect(x: 20, y: 25, width: 81, height: 51))
        let cells = try XCTUnwrap(geometry.metadata(grid: (3, 2))["cellToPoint"] as? [String: [String: CGFloat]])
        XCTAssertEqual(cells["A1"], ["x": 16.75, "y": 18.875])
        XCTAssertEqual(cells["C2"], ["x": 43.75, "y": 31.625])
        let full = CaptureGeometry(crop: try Crop.parse(nil), width: 300, height: 99, window: CGSize(width: 600, height: 100))
        XCTAssertEqual(full.metadata(grid: nil)["pointsPerPixelY"] as? CGFloat, 100.0 / 99)
        let edge = CaptureGeometry(crop: try Crop.parse(#"{"x":0.999,"y":0.999,"width":0.001,"height":0.001}"#),
                                   width: 5, height: 4, window: CGSize(width: 5, height: 4))
        XCTAssertEqual(edge.pixels, CGRect(x: 4, y: 3, width: 1, height: 1))
        for raw in ["{}", #"{"x":0,"y":0,"width":0,"height":1}"#, #"{"x":0.8,"y":0,"width":0.3,"height":1}"#] {
            XCTAssertThrowsError(try Crop.parse(raw))
        }
    }

    func testSafePngPublishing() throws {
        let fm = FileManager.default
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = tests.appendingPathComponent(".capture-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let bytes = Data([1, 2, 3])
        let file = try CaptureFile(root: root, requested: "画面.png")
        try file.save(bytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path)), bytes)
        XCTAssertEqual(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertThrowsError(try file.save(Data([4])))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path)), bytes)
        XCTAssertNoThrow(try CaptureFile(root: root, requested: file.path))
        for invalid in ["../other.png", "sub/other.png", "/outside.png", ".secret.png", "a.jpg"] {
            XCTAssertThrowsError(try CaptureFile(root: root, requested: invalid))
        }
        let directory = root.appendingPathComponent(".local/captures")
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: directory.appendingPathComponent("link.png"), withDestinationURL: outside.appendingPathComponent("new.png"))
        XCTAssertThrowsError(try CaptureFile(root: root, requested: "link.png").save(bytes))
        try fm.removeItem(at: directory)
        try fm.createSymbolicLink(at: directory, withDestinationURL: outside)
        XCTAssertThrowsError(try file.save(bytes))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), [])
    }
}
