import AppKit
import ApplicationServices
import CoreFoundation
import CoreGraphics
import Foundation

private func invalid(_ message: String) -> Failure {
    Failure("INVALID_ARGUMENT", message)
}

private struct SessionParams {
    let raw: Object

    func optionalString(_ key: String) throws -> String? {
        guard let value = raw[key] else { return nil }
        guard let string = value as? String else {
            throw invalid("\(key) must be a string.")
        }
        return string
    }

    func string(_ key: String, empty: Bool = false) throws -> String {
        guard let value = try optionalString(key), empty || !value.isEmpty else {
            throw invalid("Missing or empty \(key).")
        }
        return value
    }

    func bool(_ key: String, _ fallback: Bool) throws -> Bool {
        guard let value = raw[key] else { return fallback }
        guard let n = value as? NSNumber,
              CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw invalid("\(key) must be a boolean.")
        }
        return n.boolValue
    }

    func number(_ key: String) throws -> Double {
        guard let n = raw[key] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite else {
            throw invalid("\(key) must be a finite number.")
        }
        return n.doubleValue
    }

    func int(_ key: String, _ range: ClosedRange<Int>,
             _ fallback: Int? = nil) throws -> Int {
        if raw[key] == nil, let fallback { return fallback }
        guard let value = Int(exactly: try number(key)), range.contains(value) else {
            throw invalid("\(key) is outside its integer range.")
        }
        return value
    }

    func point(_ x: String, _ y: String) throws -> CGPoint {
        CGPoint(x: try number(x), y: try number(y))
    }

    func windowID() throws -> CGWindowID? {
        guard raw["window_id"] != nil else { return nil }
        return CGWindowID(try int("window_id", 1...Int(UInt32.max)))
    }
}

private struct SessionTarget {
    let ax: AXTarget
    let owned: [Window]
    let windowID: CGWindowID?

    func window() throws -> Window {
        let matches = owned.filter {
            $0.layer == 0 && $0.shown && !$0.bounds.isEmpty &&
            (windowID == nil || $0.id == windowID)
        }
        guard matches.count == 1, let window = matches.first else {
            throw Failure("WINDOW_AMBIGUOUS", "Specify a unique visible target window.")
        }
        return window
    }

    func check(_ item: AXUIElement, in required: Window? = nil) throws {
        let policy = ax.policy
        try checkElement(item, policy)
        guard !policy.protectedControl(
            role: stringAttr(item, kAXRoleAttribute),
            subrole: stringAttr(item, kAXSubroleAttribute),
            title: stringAttr(item, kAXTitleAttribute),
            description: stringAttr(item, kAXDescriptionAttribute)
        ) else {
            throw Failure("SENSITIVE_TARGET", "Protected or unidentified control.")
        }

        let root = element(item, kAXWindowAttribute) ?? item
        guard ax.roots.contains(where: { CFEqual($0, root) }) else {
            throw Failure("STALE_WINDOW", "Element is outside the target windows.")
        }
        guard required != nil || windowID != nil else { return }
        let wanted = try required ?? window()
        let title = stringAttr(root, kAXTitleAttribute)
        let bounds = axRect(attr(root, kAXPositionAttribute), attr(root, kAXSizeAttribute))
        func titleCompatible(_ wTitle: String?, _ axTitle: String) -> Bool {
            guard let wt = wTitle, !wt.isEmpty else { return true }
            return wt == axTitle || axTitle.hasPrefix(wt + " –") || axTitle.hasPrefix(wt + " -") || axTitle.hasPrefix(wt + " —")
        }
        let sameBoundsWindows = owned.filter { $0.layer == wanted.layer && $0.bounds == bounds }
        let sameBoundsRoots = ax.roots.filter {
            axRect(attr($0, kAXPositionAttribute), attr($0, kAXSizeAttribute)) == wanted.bounds
        }
        if sameBoundsWindows.count == 1 && sameBoundsWindows.first?.id == wanted.id &&
           sameBoundsRoots.count == 1, let only = sameBoundsRoots.first, CFEqual(only, root) {
            return
        }
        let matchingWindows = sameBoundsWindows.filter { titleCompatible($0.title, title) }
        let matchingRoots = sameBoundsRoots.filter { titleCompatible(wanted.title, stringAttr($0, kAXTitleAttribute)) }
        guard matchingWindows.count == 1, matchingWindows.first?.id == wanted.id,
              matchingRoots.count == 1, let only = matchingRoots.first,
              CFEqual(only, root) else {
            throw Failure("STALE_WINDOW", "Cannot uniquely bind the element to the window.")
        }
    }

    func keyboardTarget(_ expected: AXUIElement?) throws -> AXUIElement {
        guard CGPreflightPostEventAccess() else {
            throw Failure("EVENT_PERMISSION", guide)
        }
        guard let control = element(ax.app, kAXFocusedUIElementAttribute),
              let focusedWindow = element(ax.app, kAXFocusedWindowAttribute),
              let root = element(control, kAXWindowAttribute) ??
                (ax.roots.contains(where: { CFEqual($0, control) }) ? control : nil),
              CFEqual(focusedWindow, root),
              expected.map({ CFEqual($0, control) }) ?? true else {
            throw Failure("NO_FOCUSED_CONTROL", "Cannot verify the destination of keyboard input.")
        }
        try check(focusedWindow)
        try check(control)
        return control
    }

    func hit(_ local: CGPoint, in window: Window,
             expected: AXUIElement?) throws -> CGPoint {
        guard local.x >= 0, local.y >= 0,
              local.x < window.bounds.width, local.y < window.bounds.height else {
            throw Failure("OUT_OF_BOUNDS", "Point is outside the window.")
        }
        let global = CGPoint(x: window.bounds.minX + local.x,
                             y: window.bounds.minY + local.y)
        var item: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            ax.app, Float(global.x), Float(global.y), &item
        ) == .success, let item else {
            throw Failure("TARGET_UNAVAILABLE", "Cannot verify the pointer destination.")
        }
        try check(item, in: window)
        if let expected, !CFEqual(expected, item) {
            throw Failure("STALE_ELEMENT", "Pointer destination differs from ref.")
        }
        return global
    }
}

@MainActor
private final class HelperSession {
    let pid: pid_t
    let settler = UISettler()

    private var process: NSRunningApplication?
    private var policySeen: Guardrails?
    private var richAXEnabled = false

    private var cache = AXElementCache()
    private var latest: AXFrame?
    private var scope: CGWindowID?
    private var initialFrame: AXFrame?
    private var previousFrame: AXFrame?
    private var frames: [String: AXFrame] = [:]
    private var order: [String] = []

    init(pid: pid_t) {
        self.pid = pid
    }

    private func invalidate() {
        cache = AXElementCache()
        latest = nil
        initialFrame = nil
        previousFrame = nil
        frames.removeAll()
        order.removeAll()
    }

    private func target(_ policy: Guardrails, _ id: CGWindowID?) throws -> SessionTarget {
        guard let live = NSRunningApplication(processIdentifier: pid),
              !live.isTerminated,
              process.map({ !$0.isTerminated && $0.isEqual(live) }) ?? true else {
            invalidate()
            throw Failure("TARGET_UNAVAILABLE", "Original target process is unavailable.")
        }

        if let old = policySeen,
           old.identities != policy.identities ||
           old.bundlePrefixes != policy.bundlePrefixes ||
           old.markers != policy.markers {
            invalidate()
        }
        policySeen = policy
        process = live

        let owned = try processWindows(pid, policy)
        if let id, !owned.contains(where: { $0.id == id }) {
            throw Failure("STALE_WINDOW", "Window is no longer owned by the target.")
        }
        let ax = try AXTarget(pid, policy, enableRichAX: !richAXEnabled)
        richAXEnabled = true
        return SessionTarget(ax: ax, owned: owned, windowID: id)
    }

    private func capture(_ t: SessionTarget, _ p: SessionParams,
                         using destination: AXElementCache) throws -> AXFrame {
        try captureCompactFrame(
            target: t.ax, windowID: t.windowID, cache: destination,
            maxDepth: p.int("max_depth", 0...32, 12),
            maxNodes: p.int("max_nodes", 1...10_000, 300),
            timeBudgetMs: 1500
        )
    }

    private func publish(_ frame: AXFrame) {
        latest = frame
        guard frame.complete, !frame.truncated else { return }
        if initialFrame == nil { initialFrame = frame }
        previousFrame = frame
        frames[frame.frameID] = frame
        order.append(frame.frameID)
        if order.count > 16 {
            frames.removeValue(forKey: order.removeFirst())
        }
    }

    private func baseline(_ id: String?) -> AXFrame? {
        guard let id else { return previousFrame }
        if id == "initial" || id == initialFrame?.frameID { return initialFrame }
        return frames[id]
    }

    private func resolve(_ p: SessionParams, _ t: SessionTarget) throws -> AXUIElement? {
        let snapshot = try p.optionalString("snapshot")
        if let snapshot, latest?.frameID != snapshot || scope != t.windowID {
            throw Failure("STALE_FRAME", "Snapshot is outside the current window scope.")
        }
        guard let ref = try p.optionalString("ref") else { return nil }
        guard let snapshot else { throw invalid("ref requires snapshot.") }
        let item = try cache.resolve(ref: ref, snapshot: snapshot, in: t.ax)
        try t.check(item)
        return item
    }

    private func assertion(_ p: SessionParams, _ t: SessionTarget) throws -> Object {
        let condition = try p.string("condition")
        guard ["exists", "absent", "focused", "enabled"].contains(condition) else {
            throw invalid("Unknown assertion condition.")
        }
        let ref = try p.optionalString("ref")
        let role = try p.optionalString("role")
        let title = try p.optionalString("title")
        guard ref != nil || role != nil || title != nil else {
            throw invalid("assert requires ref, role or title.")
        }

        let scratch = AXElementCache()
        let scan = try capture(t, p, using: scratch)
        var matches = scan.nodes.filter {
            !$0.protected && (role == nil || $0.role == role) &&
            (title == nil || $0.title == title)
        }

        if let ref {
            let snapshot = try p.string("snapshot")
            guard scope == t.windowID, let latest, latest.frameID == snapshot else {
                throw Failure("STALE_FRAME", "Assertion snapshot is stale.")
            }
            if latest.complete && !latest.nodes.contains(where: { $0.ref == ref }) {
                matches.removeAll()
            } else {
                // Scratch refs have their own numeric namespace.
                let expected = try cache.resolve(ref: ref, snapshot: snapshot, in: t.ax)
                try t.check(expected)
                matches = try matches.filter { node in
                    let item = try scratch.resolve(
                        ref: node.ref, snapshot: scan.frameID, in: t.ax
                    )
                    return CFEqual(expected, item)
                }
            }
        }

        let passed: Bool
        switch condition {
        case "absent": passed = matches.isEmpty && scan.complete && !scan.truncated
        case "exists": passed = !matches.isEmpty
        case "enabled":
            passed = (ref != nil || (scan.complete && !scan.truncated)) &&
                matches.count == 1 && matches[0].enabled == true
        default:
            passed = (ref != nil || (scan.complete && !scan.truncated)) &&
                matches.count == 1 && matches[0].focused == true
        }
        guard passed else {
            throw Failure("ASSERTION_FAILED", "Current state did not establish \(condition).")
        }
        return ["asserted": true, "condition": condition]
    }

    private func input(_ op: String, _ p: SessionParams, _ t: SessionTarget,
                       _ item: AXUIElement?, refresh: () throws -> SessionTarget)
        async throws -> Object {
        switch op {
        case "ax_press", "ax_set_value", "perform_secondary_action", "select_text":
            guard let item else { throw invalid("\(op) requires ref and snapshot.") }
            try t.check(item)
            guard attr(item, kAXEnabledAttribute) as? Bool != false else {
                throw Failure("DISABLED_CONTROL", "Control is disabled.")
            }
            switch op {
            case "ax_press":
                return try performSecondaryAction(name: kAXPressAction, on: item,
                                                  policy: t.ax.policy)
            case "perform_secondary_action":
                return try performSecondaryAction(name: p.string("action"), on: item,
                                                  policy: t.ax.policy)
            case "select_text":
                return try performSelectText(
                    on: item, query: try p.optionalString("text") ?? p.string("query"),
                    prefix: p.optionalString("prefix"), suffix: p.optionalString("suffix"),
                    selectionType: p.optionalString("selection_type") ?? "text",
                    policy: t.ax.policy
                )
            default:
                let value = try p.string("value", empty: true)
                let key = kAXValueAttribute as CFString
                var writable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(item, key, &writable) == .success,
                      writable.boolValue else {
                    throw Failure("READ_ONLY", "AXValue is not settable.")
                }
                guard AXUIElementSetAttributeValue(item, key, value as CFString) == .success else {
                    throw Failure("AX_ACTION_FAILED", "AXSetValue failed.")
                }
                return ["delivery": "ax_success"]
            }

        case "press_key", "type_text", "paste":
            let focused = try t.keyboardTarget(item)
            switch op {
            case "press_key":
                return try postKeyChord(parseKeyChord(p.string("key")), to: pid)
            case "paste":
                func checkEditable(_ targetItem: AXUIElement) throws {
                    guard attr(targetItem, kAXEnabledAttribute) as? Bool != false else {
                        throw Failure("DISABLED_CONTROL", "Control is disabled.")
                    }
                    var writable = DarwinBoolean(false)
                    let valueWritable = AXUIElementIsAttributeSettable(targetItem, kAXValueAttribute as CFString, &writable) == .success && writable.boolValue
                    var selWritable = DarwinBoolean(false)
                    let rangeWritable = AXUIElementIsAttributeSettable(targetItem, kAXSelectedTextRangeAttribute as CFString, &selWritable) == .success && selWritable.boolValue
                    let role = stringAttr(targetItem, kAXRoleAttribute)
                    let editableRole = ["AXTextField", "AXTextArea", "AXComboBox", "AXWebArea"].contains(role)
                    guard valueWritable || (editableRole && rangeWritable) else {
                        throw Failure("READ_ONLY", "Target control is not editable.")
                    }
                }
                // 无论是否显式传入 ref，均校验实际聚焦控件可编辑；投递 Cmd+V 前再次核验。
                try checkEditable(focused)
                let waitMs = try p.int("paste_wait_ms", 50...1000, 600)
                let chord = try parseKeyChord("cmd+v")
                return try await performPasteTransaction(
                    text: p.string("text", empty: true),
                    format: p.optionalString("format") ?? "text",
                    board: SystemPasteboardAdapter(),
                    sendCmdV: {
                        let liveTarget = try refresh()
                        let liveFocused = try liveTarget.keyboardTarget(focused)
                        try checkEditable(liveFocused)
                        _ = try postKeyChord(chord, to: self.pid)
                    },
                    settleWait: {
                        // 在协作时限内等待目标读取剪贴板，留足还原时间。
                        try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
                    }
                )
            default:
                let text = try p.string("text")
                try validateSingleLineText(text)
                guard let source = CGEventSource(stateID: .privateState) else {
                    throw Failure("EVENT_ERROR", "Cannot create keyboard source.")
                }
                func send(_ units: [UInt16]) throws {
                    _ = try refresh().keyboardTarget(focused)
                    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0,
                                             keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 0,
                                           keyDown: false) else {
                        throw Failure("EVENT_ERROR", "Cannot construct keyboard events.")
                    }
                    for event in [down, up] {
                        event.flags = []
                        event.keyboardSetUnicodeString(stringLength: units.count,
                                                       unicodeString: units)
                        event.postToPid(pid)
                    }
                }
                var units: [UInt16] = []
                for scalar in text.unicodeScalars {
                    let next = String(scalar).utf16
                    if units.count + next.count > 20 {
                        try send(units)
                        units.removeAll(keepingCapacity: true)
                    }
                    units.append(contentsOf: next)
                }
                if !units.isEmpty { try send(units) }
                return ["delivery": "posted_unverified"]
            }

        case "click", "scroll", "drag":
            guard CGPreflightPostEventAccess() else {
                throw Failure("EVENT_PERMISSION", guide)
            }
            let w = try t.window()
            if op == "drag" {
                let allowActivate = try p.bool("allow_activate", false)
                var pathPoints: [CGPoint] = []
                if let rawPoints = p.raw["points"] {
                    guard let arr = rawPoints as? [Object], (2...256).contains(arr.count) else {
                        throw invalid("points must be an array of 2..256 {x,y} objects.")
                    }
                    for pt in arr {
                        let sp = SessionParams(raw: pt)
                        pathPoints.append(try sp.point("x", "y"))
                    }
                } else {
                    pathPoints = [try p.point("from_x", "from_y"), try p.point("to_x", "to_y")]
                }
                if !allowActivate {
                    _ = try t.hit(pathPoints[0], in: w, expected: item)
                }
                return try await postDragPath(
                    pid: pid, window: w, points: pathPoints,
                    durationMs: p.int("duration_ms", 0...5000, 300),
                    allowActivate: allowActivate,
                    target: t.ax, policy: t.ax.policy,
                    validateStep: {
                        let live = try refresh()
                        guard try live.window().bounds == w.bounds else {
                            throw Failure("STALE_WINDOW", "Drag window moved.")
                        }
                        let policy = live.ax.policy
                        guard policy.identities == t.ax.policy.identities,
                              policy.bundlePrefixes == t.ax.policy.bundlePrefixes,
                              policy.markers == t.ax.policy.markers else {
                            throw Failure("POLICY_CHANGED", "Policy changed during drag.")
                        }
                    }
                )
            }

            let local = try p.point("x", "y")
            let point = try t.hit(local, in: w, expected: item)
            guard let source = CGEventSource(stateID: .privateState) else {
                throw Failure("EVENT_ERROR", "Cannot create pointer source.")
            }
            func post(_ event: CGEvent) {
                event.flags = []
                event.location = point
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer,
                                           value: Int64(w.id))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                           value: Int64(w.id))
                event.postToPid(pid)
            }

            if op == "scroll" {
                let dy = try p.int("dy", -100_000...100_000)
                guard dy != 0 else { throw invalid("dy must be nonzero.") }
                guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                          wheelCount: 1, wheel1: Int32(dy),
                                          wheel2: 0, wheel3: 0) else {
                    throw Failure("EVENT_ERROR", "Cannot construct scroll event.")
                }
                post(event)
            } else {
                let button = try p.optionalString("button") ?? "left"
                guard ["left", "right"].contains(button) else {
                    throw invalid("Unknown mouse button.")
                }
                let clicks = try p.int("clicks", 1...2, 1)
                let right = button == "right"
                for count in 1...clicks {
                    let live = try refresh()
                    let current = try live.window()
                    guard current.id == w.id, current.bounds == w.bounds else {
                        throw Failure("STALE_WINDOW", "Click window changed.")
                    }
                    _ = try live.hit(local, in: current, expected: item)
                    let button: CGMouseButton = right ? .right : .left
                    guard let down = CGEvent(mouseEventSource: source,
                                             mouseType: right ? .rightMouseDown : .leftMouseDown,
                                             mouseCursorPosition: point, mouseButton: button),
                          let up = CGEvent(mouseEventSource: source,
                                           mouseType: right ? .rightMouseUp : .leftMouseUp,
                                           mouseCursorPosition: point, mouseButton: button) else {
                        throw Failure("EVENT_ERROR", "Cannot construct click events.")
                    }
                    for event in [down, up] {
                        event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                        post(event)
                    }
                }
            }
            return ["delivery": "posted_unverified", "windowId": w.id]

        default:
            throw invalid("Unknown operation.")
        }
    }

    func handle(_ op: String, _ p: SessionParams,
                load: () throws -> Guardrails) async throws -> Object {
        if op == "close" {
            settler.invalidate()
            return ["closed": true]
        }

        let writes: Set<String> = [
            "ax_press", "ax_set_value", "perform_secondary_action", "select_text",
            "type_text", "press_key", "paste", "click", "scroll", "drag"
        ]
        guard op == "get_state" || op == "assert" || writes.contains(op) else {
            throw invalid("Unknown operation.")
        }
        do {
            let id = try p.windowID()
            func fresh() throws -> SessionTarget {
                try target(load(), id)
            }
            let t = try fresh()
            if op == "assert" { return try assertion(p, t) }

            let lines = try p.int("diff_lines", 0...10_000, 400)
            if op == "get_state" {
                let since = try p.optionalString("since")
                let full = try p.bool("full", false)
                let advance = try p.bool("advance_baseline", true)
                if !advance {
                    let scratch = AXElementCache()
                    let frame = try capture(t, p, using: scratch)
                    let state = computeAXDiff(from: nil, to: frame,
                                              lineBudget: lines, fallbackReason: "internal_read")
                    return ["state": state]
                }
                if scope != id {
                    invalidate()
                    scope = id
                }
                let base = baseline(since)
                let frame = try capture(t, p, using: cache)
                let reason = full ? "requested_full" :
                    (since != nil && base == nil ? "unknown_baseline" : nil)
                let state = computeAXDiff(from: base, to: frame,
                                          lineBudget: lines, fallbackReason: reason)
                publish(frame)
                return ["state": state]
            }

            let returnDiff = try p.bool("return_diff", true)
            let restore = try p.bool("restore_focus", false)
            let maxMs = try p.int("settle_ms", 1000...5000, 5000)
            let baseID = try p.optionalString("diff_base")
            let item = try resolve(p, t)

            if scope != id {
                invalidate()
                scope = id
            }
            let generation = cache
            let explicitBase = baseID.flatMap { baseline($0) }
            var before: AXFrame?
            // Capture with the session allocator so unchanged nodes keep their IDs.
            // Resolve the caller's ref first: capture advances AXElementCache.latest.
            if returnDiff && baseID == nil {
                before = try capture(t, p, using: cache)
                latest = nil
            }

            settler.arm(pid: pid, target: item ?? t.ax.roots.first ?? t.ax.app)
            var receipt = try await guardWrite(
                pid, t.ax.policy, restoreRequested: restore,
                settle: { _ = await self.settler.wait(maxMs: maxMs) },
                verifyRestoration: {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            ) {
                let live = try fresh()
                guard generation === self.cache else {
                    throw Failure("POLICY_CHANGED", "Inspect state under the new policy.")
                }
                if let ref = try p.optionalString("ref"), let item {
                    let token = try before?.frameID ?? p.string("snapshot")
                    let verified = try self.cache.resolve(ref: ref, snapshot: token, in: live.ax)
                    guard CFEqual(verified, item) else {
                        throw Failure("STALE_ELEMENT", "Element changed before delivery.")
                    }
                }
                return try await self.input(op, p, live, item, refresh: fresh)
            }

            if returnDiff {
                do {
                    let live = try fresh()
                    let frame = try capture(live, p, using: cache)
                    let samePolicy = generation === cache
                    let reason: String?
                    if !samePolicy {
                        reason = "policy_changed"
                    } else if baseID != nil && explicitBase == nil {
                        reason = "unknown_baseline"
                    } else {
                        reason = nil
                    }
                    let state = computeAXDiff(from: explicitBase ?? before, to: frame,
                                              lineBudget: lines, fallbackReason: reason)
                    if samePolicy, let before, state["kind"] as? String == "diff" {
                        // The caller has never received this private pre-action snapshot.
                        receipt["before_state"] = computeAXDiff(
                            from: nil, to: before, lineBudget: lines
                        )
                    }
                    receipt["state"] = state
                    publish(frame)
                } catch {
                    // Delivery already returned a receipt. A failed readback must
                    // preserve that receipt and its focus audit.
                    invalidate()
                    let reason = (error as? Failure)?.code ?? "STATE_UNAVAILABLE"
                    receipt["state"] = ["kind": "unavailable", "reason": reason]
                }
            }
            return receipt
        } catch let error as Failure {
            if error.code == "SENSITIVE_TARGET" { invalidate() }
            throw error
        }
    }
}

@MainActor
func runSession(pid: pid_t, policyLoader: () throws -> Guardrails) async throws {
    guard pid > 0 else { throw invalid("pid must be positive.") }
    let session = HelperSession(pid: pid)
    defer { session.settler.invalidate() }

    // Keep byte framing independent of Unicode line separators inside JSON strings.
    var input = FileHandle.standardInput.bytes.makeAsyncIterator()
    var line = Data()
    var oversized = false
    let limit = 4 * 1024 * 1024

    while true {
        let byte = try await input.next()
        if let byte, byte != 10 {
            if line.count < limit {
                line.append(byte)
            } else {
                oversized = true
            }
            continue
        }
        if byte == nil && line.isEmpty && !oversized { return }

        var id: Any = null
        var close = false
        var response: Object
        do {
            guard !oversized else { throw invalid("JSON request exceeds 4 MiB.") }
            let decoded: Any
            do {
                decoded = try JSONSerialization.jsonObject(with: line)
            } catch {
                throw Failure("INVALID_JSON", "Invalid JSON request.")
            }
            guard let request = decoded as? Object,
                  let requestID = request["id"] as? String else {
                throw invalid("Request requires a string id.")
            }
            id = requestID
            guard let op = request["op"] as? String else {
                throw invalid("Request requires a string op.")
            }
            let params: Object
            if let raw = request["params"] {
                guard let object = raw as? Object else {
                    throw invalid("params must be an object.")
                }
                params = object
            } else {
                params = [:]
            }

            response = try await session.handle(op, SessionParams(raw: params),
                                                 load: policyLoader)
            response["ok"] = true
            close = op == "close"
        } catch {
            let failure = error as? Failure ?? Failure("NATIVE_ERROR", "Native request failed.")
            response = [
                "ok": false,
                "error": ["code": failure.code, "message": failure.message],
                "focusAudit": failure.focusAudit as Any? ?? null
            ]
        }
        response["id"] = id
        var output = try JSONSerialization.data(withJSONObject: response)
        output.append(10)
        try FileHandle.standardOutput.write(contentsOf: output)
        if close || byte == nil { return }
        line.removeAll(keepingCapacity: true)
        oversized = false
    }
}
