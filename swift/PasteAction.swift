import Foundation
import AppKit

typealias PasteItemData = [NSPasteboard.PasteboardType: Data]

enum PasteboardMutationError: Error {
    case changed
    case preparationFailed
    // clearContents succeeded, but publishing the prepared items failed.
    case publishFailed(clearGeneration: Int)
}

@MainActor
protocol PasteboardLike {
    var changeCount: Int { get }
    func readItems() throws -> [PasteItemData]

    /// Prepare all representations before modifying the board. Return the
    /// generation acquired by this write, never a later observer's generation.
    func replaceItems(_ items: [PasteItemData], ifUnchanged expected: Int) throws -> Int
}

@MainActor
struct SystemPasteboardAdapter: PasteboardLike {
    let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func readItems() throws -> [PasteItemData] {
        guard let items = pasteboard.pasteboardItems else {
            guard pasteboard.types?.isEmpty != false else {
                throw Failure("CLIPBOARD_UNREADABLE", "Cannot enumerate pasteboard items.")
            }
            return []
        }
        return try items.map { item in
            guard !item.types.isEmpty else {
                throw Failure("CLIPBOARD_UNREADABLE", "An item has no materializable types.")
            }
            var representations: PasteItemData = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw Failure("CLIPBOARD_UNREADABLE", "Cannot materialize a representation.")
                }
                representations[type] = data
            }
            return representations
        }
    }

    func replaceItems(_ items: [PasteItemData], ifUnchanged expected: Int) throws -> Int {
        let objects: [NSPasteboardItem] = try items.map { representations in
            let item = NSPasteboardItem()
            guard !representations.isEmpty else { throw PasteboardMutationError.preparationFailed }
            for (type, data) in representations {
                guard item.setData(data, forType: type) else {
                    throw PasteboardMutationError.preparationFailed
                }
            }
            return item
        }

        guard changeCount == expected else { throw PasteboardMutationError.changed }
        let owned = pasteboard.clearContents()
        guard changeCount == owned else { throw PasteboardMutationError.changed }
        if !objects.isEmpty && !pasteboard.writeObjects(objects) {
            throw PasteboardMutationError.publishFailed(clearGeneration: owned)
        }
        guard changeCount == owned else { throw PasteboardMutationError.changed }
        return owned
    }
}

struct ClipboardSnapshot {
    let items: [PasteItemData]
    let generation: Int

    @MainActor
    init(board: PasteboardLike) throws {
        let before = board.changeCount
        do {
            items = try board.readItems()
        } catch {
            throw Failure("CLIPBOARD_UNREADABLE", "Cannot snapshot every pasteboard representation.")
        }
        guard board.changeCount == before else {
            throw Failure("CLIPBOARD_CHANGED", "Pasteboard changed during snapshot.")
        }
        generation = before
    }
}

@MainActor
func buildPasteItems(text: String, format: String) throws -> [[NSPasteboard.PasteboardType: Data]] {
    let source = Data(text.utf8)
    if format == "text" { return [[.string: source]] }

    var item: PasteItemData = [:]
    let rich: NSAttributedString
    switch format {
    case "md":
        do {
            let parsed = try AttributedString(markdown: text, options: .init(
                interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
            ))
            // Foundation stores Markdown emphasis and links as presentation
            // intents. Emit their HTML explicitly before importing into AppKit.
            func escape(_ s: String) -> String {
                s.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
            }
            var blocks: [String] = []
            var plain: [String] = []
            var inline = ""
            var readable = ""
            var previous: PresentationIntent?
            func finishBlock() {
                guard !inline.isEmpty || !readable.isEmpty else { return }
                var tag = "p"
                var listItem = false
                if let previous {
                    for component in previous.components {
                        switch component.kind {
                        case .header(let level): tag = "h\(min(6, max(1, level)))"
                        case .codeBlock: tag = "pre"
                        case .blockQuote: tag = "blockquote"
                        case .listItem: listItem = true
                        default: break
                        }
                    }
                }
                let marker = listItem ? "• " : ""
                blocks.append("<\(tag)>\(marker)\(inline)</\(tag)>")
                plain.append(marker + readable)
                inline = ""
                readable = ""
            }
            for run in parsed.runs {
                if run.presentationIntent != previous {
                    finishBlock()
                    previous = run.presentationIntent
                }
                let value = String(parsed[run.range].characters)
                var fragment = escape(value)
                let intent = run.inlinePresentationIntent ?? []
                if intent.contains(.code) { fragment = "<code>\(fragment)</code>" }
                if intent.contains(.emphasized) { fragment = "<em>\(fragment)</em>" }
                if intent.contains(.stronglyEmphasized) { fragment = "<strong>\(fragment)</strong>" }
                if intent.contains(.strikethrough) { fragment = "<del>\(fragment)</del>" }
                if intent.contains(.lineBreak) { fragment = "<br>" }
                if let url = run.link {
                    fragment = "<a href=\"\(escape(url.absoluteString))\">\(fragment)</a>"
                }
                inline += fragment
                readable += value
            }
            finishBlock()
            let html = Data(("<meta charset=\"utf-8\">" + blocks.joined(separator: "\n")).utf8)
            item[NSPasteboard.PasteboardType("net.daringfireball.markdown")] = source
            item[.html] = html
            item[.string] = Data(plain.joined(separator: "\n").utf8)
            rich = try importPasteHTML(html)
        } catch {
            throw Failure("PASTE_CONVERSION_FAILED", "Cannot convert Markdown representations.")
        }
    case "html":
        rich = try importPasteHTML(source)
        item[.html] = source
        item[.string] = Data(rich.string.utf8)
    default:
        throw Failure("INVALID_FORMAT", "Supported paste formats are text, md and html.")
    }

    let range = NSRange(location: 0, length: rich.length)
    if let rtf = rich.rtf(from: range, documentAttributes: [:]) {
        item[.rtf] = rtf
    }
    if rich.containsAttachments(in: range),
       let rtfd = rich.rtfd(from: range, documentAttributes: [:]) {
        item[.rtfd] = rtfd
    }
    return [item]
}

@MainActor
private func importPasteHTML(_ data: Data) throws -> NSAttributedString {
    do {
        return try NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                .baseURL: URL(string: "about:blank")!
            ],
            documentAttributes: nil
        )
    } catch {
        throw Failure("PASTE_CONVERSION_FAILED", "Cannot create rich-text representations.")
    }
}

// The main actor serializes individual AppKit calls. This gate also covers
// reentrancy during settleWait, including independent adapters for .general.
@MainActor
private enum PasteTransactionGate {
    static var busy = false
}

@MainActor
private func restoreSnapshot(
    _ original: ClipboardSnapshot, board: PasteboardLike, expected: Int
) -> String {
    guard board.changeCount == expected else { return "changed_externally" }
    do {
        _ = try board.replaceItems(original.items, ifUnchanged: expected)
        return "restored"
    } catch PasteboardMutationError.changed {
        return "changed_externally"
    } catch PasteboardMutationError.publishFailed(let generation) {
        // The first restore cleared the board. Reuse the in-memory snapshot
        // only if the board is still at that exact cleared generation.
        guard board.changeCount == generation else { return "changed_externally" }
        do {
            _ = try board.replaceItems(original.items, ifUnchanged: generation)
            return "restored"
        } catch PasteboardMutationError.changed {
            return "changed_externally"
        } catch {
            return "restore_failed"
        }
    } catch {
        return "restore_failed"
    }
}

@MainActor
func performPasteTransaction(
    text: String, format: String, board: PasteboardLike,
    sendCmdV: () throws -> Void, settleWait: () async -> Void
) async throws -> Object {
    guard !PasteTransactionGate.busy else {
        throw Failure("CLIPBOARD_BUSY", "Another paste transaction is active.")
    }
    PasteTransactionGate.busy = true
    defer { PasteTransactionGate.busy = false }

    let payload = try buildPasteItems(text: text, format: format)
    let original = try ClipboardSnapshot(board: board)
    let installed: Int
    do {
        installed = try board.replaceItems(payload, ifUnchanged: original.generation)
    } catch PasteboardMutationError.changed {
        return ["posted": false, "pasteEffect": "not_sent",
                "clipboardRestore": "changed_externally", "code": "CLIPBOARD_CHANGED"]
    } catch PasteboardMutationError.publishFailed(let generation) {
        let restore = restoreSnapshot(original, board: board, expected: generation)
        throw Failure("CLIPBOARD_WRITE_FAILED", "Pasteboard publish failed. Restore: \(restore).")
    } catch {
        throw Failure("CLIPBOARD_WRITE_FAILED", "Cannot prepare pasteboard representations.")
    }

    guard board.changeCount == installed else {
        return ["posted": false, "pasteEffect": "not_sent",
                "clipboardRestore": "changed_externally", "code": "CLIPBOARD_CHANGED"]
    }
    do {
        try Task.checkCancellation()
    } catch {
        let restore = restoreSnapshot(original, board: board, expected: installed)
        throw Failure("CANCELLED", "Paste cancelled before delivery. Restore: \(restore).")
    }

    do {
        // The caller revalidates focus and guardrails immediately before posting.
        try sendCmdV()
    } catch {
        // An injected sender can throw after posting. Allow the same consumption
        // interval before restoring, and never expose the sender's error text.
        await settleWait()
        let restore = restoreSnapshot(original, board: board, expected: installed)
        if restore == "changed_externally" {
            return ["posted": null, "pasteEffect": "unknown",
                    "clipboardRestore": restore, "code": "PASTE_SEND_FAILED"]
        }
        throw Failure("PASTE_SEND_FAILED", "Command-V delivery failed. Restore: \(restore).")
    }

    await settleWait()
    let restore = restoreSnapshot(original, board: board, expected: installed)
    var receipt: Object = [
        "posted": true, "pasteEffect": "unverified", "clipboardRestore": restore
    ]
    if restore == "changed_externally" { receipt["code"] = "CLIPBOARD_CHANGED" }
    if restore == "restore_failed" { receipt["code"] = "CLIPBOARD_RESTORE_FAILED" }
    return receipt
}
