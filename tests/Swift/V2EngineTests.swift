import Foundation
import AppKit
import CoreGraphics
import XCTest
@testable import MacGhostHelper

@MainActor
private final class MockPasteboard: PasteboardLike {
    var changeCount: Int = 10
    var items: [PasteItemData]
    var failRead = false
    var mutateAfterWrite: (() -> Void)?

    init(items: [PasteItemData]) {
        self.items = items
    }

    func readItems() throws -> [PasteItemData] {
        if failRead { throw Failure("CLIPBOARD_UNREADABLE", "Mock unreadable.") }
        return items
    }

    func replaceItems(_ items: [PasteItemData], ifUnchanged expected: Int) throws -> Int {
        guard changeCount == expected else { throw PasteboardMutationError.changed }
        self.items = items
        changeCount += 1
        let owned = changeCount
        if let hook = mutateAfterWrite {
            mutateAfterWrite = nil
            hook()
        }
        return owned
    }
}

final class V2EngineTests: XCTestCase {
    private func node(_ id: UInt64, parent: String? = nil, order: Int = 0, role: String = "AXButton",
                      title: String? = nil, value: String? = nil, path: [Int]) -> CompactNode {
        CompactNode(ref: "e\(id)", id: id, parentRef: parent, order: order, role: role,
                    title: title, description: nil, value: value, enabled: true,
                    focused: false, selected: false, actions: ["AXPress"],
                    frame: CGRect(x: 10, y: 20, width: 80, height: 30), protected: false, path: path)
    }

    func testRemovalRangesAndDiffRoundTrip() throws {
        XCTAssertEqual(removalRanges([]), [])
        XCTAssertEqual(removalRanges([4, 5, 6, 9, 10, 10, 15]), [[4, 6], [9, 10], [15, 15]])

        let n1 = node(1, order: 0, role: "AXWindow", title: "主窗", path: [0])
        let n2 = node(2, parent: "e1", order: 0, title: "确定", path: [0, 0])
        let n3 = node(3, parent: "e1", order: 1, title: "取消", path: [0, 1])
        let n4 = node(4, parent: "e1", order: 2, title: "临时1", path: [0, 2])
        let n5 = node(5, parent: "e1", order: 3, title: "临时2", path: [0, 3])
        let base = AXFrame(frameID: "f1", nodes: [n1, n2, n3, n4, n5], complete: true, truncated: false)

        // 删除 n4/n5（连续折叠为 [4,5]），更新 n2，重排 n3，新增 n6
        let n2Updated = node(2, parent: "e1", order: 1, title: "已保存", value: "ok", path: [0, 1])
        let n3Moved = node(3, parent: "e1", order: 0, title: "取消", path: [0, 0])
        let n6Added = node(6, parent: "e1", order: 2, title: "新建", path: [0, 2])
        let current = AXFrame(frameID: "f2", nodes: [n1, n3Moved, n2Updated, n6Added], complete: true, truncated: false)

        let diff = computeAXDiff(from: base, to: current, lineBudget: 100)
        XCTAssertEqual(diff["kind"] as? String, "diff")
        XCTAssertEqual(diff["base"] as? String, "f1")
        XCTAssertEqual(diff["snapshot"] as? String, "f2")
        XCTAssertEqual(diff["remove_ranges"] as? [[UInt64]], [[4, 5]])

        let reconstructed = try XCTUnwrap(applyAXDiff(base: base, payload: diff))
        XCTAssertEqual(reconstructed, current.nodes)

        // 空 Diff
        let same = AXFrame(frameID: "f3", nodes: current.nodes, complete: true, truncated: false)
        let emptyDiff = computeAXDiff(from: current, to: same, lineBudget: 100)
        XCTAssertEqual(emptyDiff["kind"] as? String, "diff")
        XCTAssertEqual((emptyDiff["remove_ranges"] as? [[UInt64]])?.count, 0)
        XCTAssertEqual((emptyDiff["upsert"] as? [Object])?.count, 0)

        // 超行预算回退全树
        let overBudget = computeAXDiff(from: base, to: current, lineBudget: 2)
        XCTAssertEqual(overBudget["kind"] as? String, "full")
        XCTAssertEqual(overBudget["fallback_reason"] as? String, "diff_line_budget")

        // 截断或采集不完整必须回退全树且不发删除
        let incomplete = AXFrame(frameID: "f4", nodes: [n1], complete: false, truncated: true)
        let fallback = computeAXDiff(from: base, to: incomplete, lineBudget: 100)
        XCTAssertEqual(fallback["kind"] as? String, "full")
        XCTAssertEqual(fallback["fallback_reason"] as? String, "incomplete_capture")
        XCTAssertEqual((fallback["remove_ranges"] as? [[UInt64]])?.count, 0)
    }

    func testKeyChordParsingAndSingleLineValidation() throws {
        let resolver: PrintableKeyResolver = { ch in
            switch ch {
            case "a": return (0, [])
            case "s": return (1, [])
            case "v": return (9, [])
            default: throw Failure("UNMAPPABLE_KEY", "unmapped")
            }
        }
        let chord = try parseKeyChord("super+shift+Left", resolvePrintable: resolver)
        XCTAssertEqual(chord.modifiers, [.command, .shift])
        XCTAssertTrue(chord.flags.contains(.maskCommand))
        XCTAssertTrue(chord.flags.contains(.maskShift))

        let kp = try parseKeyChord("ctrl+KP_0", resolvePrintable: resolver)
        XCTAssertEqual(kp.modifiers, [.control])

        let save = try parseKeyChord("cmd+s", resolvePrintable: resolver)
        XCTAssertEqual(save.keyCode, 1)
        XCTAssertEqual(save.modifiers, [.command])

        for bad in ["", "super+super+a", "unknown+a", "super+ctrl+alt+shift+cmd+a", "notakey"] {
            XCTAssertThrowsError(try parseKeyChord(bad, resolvePrintable: resolver), bad)
        }

        // 单行校验：拒绝真实换行，放行字面量两字符 \n
        XCTAssertNoThrow(try validateSingleLineText("示例输入🙂\\n--pid"))
        for multiline in ["a\nb", "a\rb", "a\r\nb", "a\u{0085}b", "a\u{2028}b", "a\u{2029}b"] {
            XCTAssertThrowsError(try validateSingleLineText(multiline))
        }
    }

    func testUTF16SelectionWithEmojiAndDisambiguation() throws {
        // "😀" 占 2 个 UTF-16 code unit；"a😀b hello world hello!"
        let sample = "a😀b hello world hello!"
        let r1 = try computeUTF16SelectionRange(in: sample, query: "hello", prefix: "a😀b ", suffix: " world", selectionType: "text")
        // a(1) + 😀(2) + b(1) + space(1) = 5
        XCTAssertEqual(r1.location, 5)
        XCTAssertEqual(r1.length, 5)

        let before = try computeUTF16SelectionRange(in: sample, query: "hello", prefix: "world ", suffix: "!", selectionType: "cursor_before")
        XCTAssertEqual(before.location, 17)
        XCTAssertEqual(before.length, 0)

        let after = try computeUTF16SelectionRange(in: sample, query: "hello", prefix: "world ", suffix: "!", selectionType: "cursor_after")
        XCTAssertEqual(after.location, 22)
        XCTAssertEqual(after.length, 0)

        XCTAssertThrowsError(try computeUTF16SelectionRange(in: sample, query: "hello", prefix: nil, suffix: nil, selectionType: "text")) { err in
            XCTAssertEqual((err as? Failure)?.code, "AMBIGUOUS_TEXT")
        }
        XCTAssertThrowsError(try computeUTF16SelectionRange(in: sample, query: "missing", prefix: nil, suffix: nil, selectionType: "text")) { err in
            XCTAssertEqual((err as? Failure)?.code, "TEXT_NOT_FOUND")
        }
    }

    @MainActor
    func testPasteTransactionRestoresMultiItemAndRespectsExternalChange() async throws {
        let sentinel = "SECRET_SENTINEL_99812"
        let origItem1: PasteItemData = [.string: Data("原文本1".utf8), .html: Data("<b>原文本1</b>".utf8)]
        let origItem2: PasteItemData = [.string: Data("原文本2".utf8)]

        // 1. 正常粘贴 + 无损还原 + 零哨兵泄漏
        let board1 = MockPasteboard(items: [origItem1, origItem2])
        var cmdVCount = 0
        let receipt1 = try await performPasteTransaction(
            text: "**\(sentinel)**",
            format: "md",
            board: board1,
            sendCmdV: {
                cmdVCount += 1
                XCTAssertEqual(board1.items.count, 1)
                XCTAssertNotNil(board1.items[0][.html])
                XCTAssertNotNil(board1.items[0][.string])
            },
            settleWait: {}
        )
        XCTAssertEqual(cmdVCount, 1)
        XCTAssertEqual(receipt1["clipboardRestore"] as? String, "restored")
        XCTAssertEqual(board1.items, [origItem1, origItem2])
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: receipt1), as: UTF8.self)
        XCTAssertFalse(serialized.contains(sentinel))
        XCTAssertFalse(serialized.contains("原文本1"))

        // 2. 粘贴等待期间外部程序复制了新内容 -> 必须保留外部内容
        let board2 = MockPasteboard(items: [origItem1])
        let externalItem: PasteItemData = [.string: Data("用户刚复制的新内容".utf8)]
        let receipt2 = try await performPasteTransaction(
            text: sentinel,
            format: "text",
            board: board2,
            sendCmdV: {},
            settleWait: {
                board2.items = [externalItem]
                board2.changeCount += 1
            }
        )
        XCTAssertEqual(receipt2["clipboardRestore"] as? String, "changed_externally")
        XCTAssertEqual(board2.items, [externalItem])

        // 3. 原剪贴板无法快照 -> 清空前即报错，不破坏原剪贴板
        let board3 = MockPasteboard(items: [origItem1])
        board3.failRead = true
        do {
            _ = try await performPasteTransaction(text: sentinel, format: "text", board: board3, sendCmdV: { XCTFail() }, settleWait: {})
            XCTFail("Expected failure")
        } catch let err as Failure {
            XCTAssertEqual(err.code, "CLIPBOARD_UNREADABLE")
            XCTAssertEqual(board3.items, [origItem1])
            XCTAssertFalse(err.message.contains(sentinel))
        }
    }

    @MainActor
    func testFocusGuardSplitSettleAndVerifyRestoration() async throws {
        let front = Frontmost<String>(pid: 10, bundle: "front", window: .focused("A"))
        let target = Frontmost<String>(pid: 20, bundle: "target", window: .focused("X"))
        var queue = [front, target, target, target, front]
        var settleCalls = 0, verifyCalls = 0
        let res = try await auditedWrite(
            target: 20,
            restoreRequested: true,
            sample: { queue.removeFirst() },
            settle: { settleCalls += 1 },
            verifyRestoration: { verifyCalls += 1 },
            restore: { _, _ in .requested },
            write: { ["delivery": "ax_success"] }
        )
        XCTAssertEqual(settleCalls, 1, "焦点恢复后绝不能重启 5s settle 闭包")
        XCTAssertEqual(verifyCalls, 1)
        let audit = try XCTUnwrap(res["focusAudit"] as? Object)
        XCTAssertEqual(audit["restoration"] as? String, "verified")
        XCTAssertEqual(audit["focusPreserved"] as? Bool, false)
    }
}
