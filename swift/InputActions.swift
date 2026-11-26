import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Carbon

enum ChordModifier: Hashable {
    case command, control, option, shift

    var code: CGKeyCode {
        switch self {
        case .command: return CGKeyCode(kVK_Command)
        case .control: return CGKeyCode(kVK_Control)
        case .option:  return CGKeyCode(kVK_Option)
        case .shift:   return CGKeyCode(kVK_Shift)
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .control: return .maskControl
        case .option:  return .maskAlternate
        case .shift:   return .maskShift
        }
    }
}

struct KeyChord {
    let keyCode: CGKeyCode
    let modifiers: [ChordModifier]

    var flags: CGEventFlags {
        modifiers.reduce(CGEventFlags()) { $0.union($1.flag) }
    }
}

private let modifierNames: [String: ChordModifier] = [
    "cmd": .command, "super": .command,
    "ctrl": .control, "control": .control,
    "alt": .option, "option": .option, "shift": .shift
]

private let namedKeyCodes: [String: CGKeyCode] = {
    var codes = [
        "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
        "backspace": kVK_Delete, "delete": kVK_ForwardDelete,
        "space": kVK_Space, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "home": kVK_Home,
        "end": kVK_End, "page_up": kVK_PageUp, "page_down": kVK_PageDown
    ]
    let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
        kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14,
        kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]
    let keypad = [
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2,
        kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
        kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8,
        kVK_ANSI_Keypad9
    ]
    for (i, key) in functionKeys.enumerated() { codes["f\(i + 1)"] = key }
    for (i, key) in keypad.enumerated() { codes["kp_\(i)"] = key }
    return codes.mapValues { CGKeyCode($0) }
}()

typealias PrintableKeyResolver = (Character) throws -> (CGKeyCode, [ChordModifier])

private func currentLayoutKey(_ character: Character) throws
    -> (CGKeyCode, [ChordModifier]) {
    guard Thread.isMainThread else {
        return try DispatchQueue.main.sync { try currentLayoutKey(character) }
    }
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { throw Failure("LAYOUT_UNAVAILABLE", "Keyboard layout is unavailable.") }

    let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
    guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
          let bytes = CFDataGetBytePtr(data)
    else { throw Failure("LAYOUT_UNAVAILABLE", "Keyboard layout has no mapping.") }

    return try withExtendedLifetime((source, data)) {
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let states: [(UInt32, [ChordModifier])] = [
            (0, []), (UInt32(shiftKey) >> 8, [.shift]),
            (UInt32(optionKey) >> 8, [.option]),
            (UInt32(shiftKey | optionKey) >> 8, [.shift, .option])
        ]
        let keypad = Set(namedKeyCodes.filter { $0.key.hasPrefix("kp_") }.values)
        let keyboardType = UInt32(LMGetKbdType())
        for (state, modifiers) in states {
            for code in UInt16(0)...UInt16(127) where !keypad.contains(code) {
                var dead: UInt32 = 0
                var count = 0
                var units = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), state, keyboardType,
                    0, &dead, 8, &count, &units
                )
                if status == noErr, dead == 0, count == 1,
                   units[0] == String(character).utf16.first {
                    return (code, modifiers)
                }
            }
        }
        throw Failure("UNMAPPABLE_KEY", "Key is unavailable in the current layout.")
    }
}

func parseKeyChord(_ raw: String) throws -> KeyChord {
    try parseKeyChord(raw, resolvePrintable: currentLayoutKey)
}

func parseKeyChord(_ raw: String, resolvePrintable: PrintableKeyResolver) throws -> KeyChord {
    let parts = raw.components(separatedBy: "+").map {
        $0.trimmingCharacters(in: .whitespaces).lowercased()
    }
    guard (1...5).contains(parts.count), let main = parts.last, !main.isEmpty else {
        throw Failure("INVALID_CHORD", "Expected up to four modifiers and one main key.")
    }
    var modifiers: [ChordModifier] = []
    for token in parts.dropLast() {
        guard let modifier = modifierNames[token], !modifiers.contains(modifier) else {
            throw Failure("INVALID_CHORD", "Unknown or duplicate modifier.")
        }
        modifiers.append(modifier)
    }
    if let code = namedKeyCodes[main] {
        return KeyChord(keyCode: code, modifiers: modifiers)
    }
    guard main.utf8.count == 1, let byte = main.utf8.first,
          (97...122).contains(byte) || (48...57).contains(byte),
          let character = main.first else {
        throw Failure("INVALID_CHORD", "Unsupported main key.")
    }
    let (code, required) = try resolvePrintable(character)
    for modifier in required where !modifiers.contains(modifier) {
        modifiers.append(modifier)
    }
    return KeyChord(keyCode: code, modifiers: modifiers)
}

func postKeyChord(_ chord: KeyChord, to pid: pid_t) throws -> Object {
    guard pid > 0, let source = CGEventSource(stateID: .privateState) else {
        throw Failure("EVENT_ERROR", "Invalid destination or event source.")
    }
    var flags = CGEventFlags()
    var events: [CGEvent] = []
    func append(_ key: CGKeyCode, down: Bool) throws {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        else { throw Failure("EVENT_ERROR", "Cannot construct keyboard event.") }
        event.flags = flags
        events.append(event)
    }
    for modifier in chord.modifiers {
        flags.insert(modifier.flag)
        try append(modifier.code, down: true)
    }
    try append(chord.keyCode, down: true)
    try append(chord.keyCode, down: false)
    for modifier in chord.modifiers.reversed() {
        flags.remove(modifier.flag)
        try append(modifier.code, down: false)
    }
    for event in events { event.postToPid(pid) }
    return ["deliveryMode": deliveryMode, "posted": true]
}

private func checkActionElement(_ item: AXUIElement, policy: Guardrails) throws {
    try checkElement(item, policy)
    guard !policy.protectedControl(
        role: stringAttr(item, kAXRoleAttribute),
        subrole: stringAttr(item, kAXSubroleAttribute),
        title: stringAttr(item, kAXTitleAttribute),
        description: stringAttr(item, kAXDescriptionAttribute)
    ) else { throw Failure("SENSITIVE_TARGET", "Protected or unidentified control.") }
}

/// 支持单段或多点一笔画路径拖动。
/// 默认 `allowActivate == false` 走无激活 `postToPid`；
/// 显式 `allowActivate == true` 时短暂激活目标窗口并经 `.cghidEventTap` 投递真实鼠标路径（供 PencilKit/画布等需要 Key Window 路由的应用），
/// 结束后恢复原鼠标位置，遇任何异常必补发 `leftMouseUp`。
@MainActor
func postDragPath(
    pid: pid_t, window: Window, points localPoints: [CGPoint], durationMs: Int,
    allowActivate: Bool, target: AXTarget?, policy: Guardrails, validateStep: () throws -> Void
) async throws -> Object {
    guard pid > 0, window.pid == pid, window.layer == 0, durationMs >= 0,
          localPoints.count >= 2, localPoints.count <= 256,
          let process = NSRunningApplication(processIdentifier: pid),
          let source = CGEventSource(stateID: allowActivate ? .hidSystemState : .privateState)
    else { throw Failure("INVALID_DRAG", "Invalid drag destination, path or duration.") }

    func global(_ p: CGPoint) throws -> CGPoint {
        guard p.x.isFinite, p.y.isFinite, p.x >= 0, p.y >= 0,
              p.x < window.bounds.width, p.y < window.bounds.height else {
            throw Failure("OUT_OF_BOUNDS", "Point is outside the target window.")
        }
        return CGPoint(x: window.bounds.minX + p.x, y: window.bounds.minY + p.y)
    }
    let globalPoints = try localPoints.map(global)
    let start = globalPoints.first!

    func sameInstance() -> Bool {
        guard !process.isTerminated,
              let live = NSRunningApplication(processIdentifier: pid) else { return false }
        return live.isEqual(process)
    }
    func validate(_ point: CGPoint) throws {
        try Task.checkCancellation()
        try validateStep()
        guard sameInstance() else {
            throw Failure("TARGET_UNAVAILABLE", "Original process is unavailable.")
        }
        let owned = try processWindows(pid, policy)
        guard owned.contains(where: {
            $0.id == window.id && $0.layer == 0 && $0.shown && $0.bounds == window.bounds
        }) else { throw Failure("STALE_WINDOW", "Target window changed.") }

        let live = try AXTarget(pid, policy)
        if let target, !CFEqual(target.app, live.app) {
            throw Failure("STALE_WINDOW", "Accessibility application changed.")
        }
        if !allowActivate {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                live.app, Float(point.x), Float(point.y), &hit
            ) == .success, let hit else {
                throw Failure("TARGET_UNAVAILABLE", "Cannot verify the drag point.")
            }
            let root = element(hit, kAXWindowAttribute) ?? hit
            guard live.roots.contains(where: { CFEqual($0, root) }),
                  axRect(attr(root, kAXPositionAttribute), attr(root, kAXSizeAttribute))
                    == window.bounds,
                  owned.filter({ $0.layer == 0 && $0.shown && $0.bounds == window.bounds }).count == 1
            else { throw Failure("STALE_WINDOW", "Drag point cannot be tied to the window.") }
            try checkActionElement(hit, policy: policy)
        }
    }

    func buildEvent(_ type: CGEventType, at point: CGPoint) throws -> CGEvent {
        guard let value = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left)
        else { throw Failure("EVENT_ERROR", "Cannot construct mouse event.") }
        value.flags = []
        value.setIntegerValueField(.mouseEventClickState, value: 1)
        if !allowActivate {
            value.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
            value.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                       value: Int64(window.id))
        }
        return value
    }

    func emit(_ ev: CGEvent) {
        if allowActivate { ev.post(tap: .cghidEventTap) }
        else { ev.postToPid(pid) }
    }

    // 预检起终点
    try validate(start)
    try validate(globalPoints.last!)

    let savedCursor = allowActivate ? CGEvent(source: nil)?.location : nil
    if allowActivate {
        // 显式前台手势：短暂激活目标应用并抬起目标窗口
        _ = process.activate(options: [.activateIgnoringOtherApps])
        if let live = try? AXTarget(pid, policy),
           let axWin = live.roots.first(where: {
               axRect(attr($0, kAXPositionAttribute), attr($0, kAXSizeAttribute)) == window.bounds
           }) {
            _ = AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
        }
        try await Task.sleep(nanoseconds: 180_000_000)
        // 先将鼠标移动到起点，让画布追踪区完成进入
        let move = try buildEvent(.mouseMoved, at: start)
        emit(move)
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    // 按弧长采样路径点，保证曲线各段匀速平滑
    var segLengths: [Double] = []
    var totalLen: Double = 0
    for i in 0..<(globalPoints.count - 1) {
        let dx = globalPoints[i + 1].x - globalPoints[i].x
        let dy = globalPoints[i + 1].y - globalPoints[i].y
        let d = hypot(dx, dy)
        segLengths.append(d)
        totalLen += d
    }

    func pointAt(_ t: Double) -> CGPoint {
        if totalLen <= 0 || t >= 1 { return globalPoints.last! }
        if t <= 0 { return start }
        var targetDist = t * totalLen
        for i in 0..<segLengths.count {
            let d = segLengths[i]
            if targetDist <= d || i == segLengths.count - 1 {
                let f = d > 0 ? min(1, max(0, targetDist / d)) : 1
                let a = globalPoints[i], b = globalPoints[i + 1]
                return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            }
            targetDist -= d
        }
        return globalPoints.last!
    }

    let release = try buildEvent(.leftMouseUp, at: start)
    let down = try buildEvent(.leftMouseDown, at: start)
    try validate(start)
    emit(down)
    if allowActivate { try await Task.sleep(nanoseconds: 25_000_000) }
    var last = start
    let steps = max(globalPoints.count * 2, min(180, max(8, durationMs / 8)))
    let stepNs: UInt64 = durationMs > 0 ? UInt64(max(4, durationMs / steps)) * 1_000_000 : 0
    do {
        for s in 1...steps {
            let t = Double(s) / Double(steps)
            let p = pointAt(t)
            if s % 6 == 0 || s == steps { try validate(p) }
            emit(try buildEvent(.leftMouseDragged, at: p))
            last = p
            if stepNs > 0 { try await Task.sleep(nanoseconds: stepNs) }
        }
        try validate(last)
    } catch {
        let canRelease = sameInstance()
        if canRelease {
            release.location = last
            emit(release)
        }
        if let savedCursor, let restoreMove = try? buildEvent(.mouseMoved, at: savedCursor) {
            restoreMove.post(tap: .cghidEventTap)
        }
        return ["partial": true, "mouseUpPosted": canRelease,
                "code": (error as? Failure)?.code ??
                    (error is CancellationError ? "CANCELLED" : "VALIDATION_FAILED"),
                "windowId": window.id,
                "deliveryMode": allowActivate ? "cg_hid_activated" : deliveryMode]
    }
    release.location = last
    emit(release)
    if allowActivate {
        try await Task.sleep(nanoseconds: 40_000_000)
        if let savedCursor, let restoreMove = try? buildEvent(.mouseMoved, at: savedCursor) {
            restoreMove.post(tap: .cghidEventTap)
        }
    }
    return ["partial": false, "mouseUpPosted": true, "windowId": window.id,
            "pointCount": globalPoints.count,
            "deliveryMode": allowActivate ? "cg_hid_activated" : deliveryMode]
}

@MainActor
func postDrag(
    pid: pid_t, window: Window, from: CGPoint, to: CGPoint, durationMs: Int,
    target: AXTarget?, policy: Guardrails, validateStep: () throws -> Void
) async throws -> Object {
    try await postDragPath(
        pid: pid, window: window, points: [from, to], durationMs: durationMs,
        allowActivate: false, target: target, policy: policy, validateStep: validateStep
    )
}

func performSecondaryAction(name: String, on item: AXUIElement, policy: Guardrails) throws -> Object {
    try checkActionElement(item, policy: policy)
    var raw: CFArray?
    guard AXUIElementCopyActionNames(item, &raw) == .success,
          let names = raw as? [String] else {
        throw Failure("AX_UNAVAILABLE", "Cannot read available actions.")
    }
    guard names.contains(where: { $0.utf8.elementsEqual(name.utf8) }) else {
        let data = try JSONEncoder().encode(names)
        throw Failure("UNSUPPORTED_ACTION", "Available actions: " + String(decoding: data, as: UTF8.self))
    }
    guard AXUIElementPerformAction(item, name as CFString) == .success else {
        throw Failure("AX_ACTION_FAILED", "Accessibility action failed.")
    }
    return ["performed": true, "action": name]
}

func computeUTF16SelectionRange(
    in text: String, query: String, prefix: String?, suffix: String?, selectionType: String
) throws -> CFRange {
    guard ["text", "cursor_before", "cursor_after"].contains(selectionType) else {
        throw Failure("INVALID_SELECTION_TYPE", "Unknown selection type.")
    }
    guard !query.isEmpty else { throw Failure("INVALID_QUERY", "Empty selection query.") }
    let source = Array(text.utf16)
    let needle = Array(query.utf16)
    let before = Array((prefix ?? "").utf16)
    let after = Array((suffix ?? "").utf16)
    var match: Int?
    if needle.count <= source.count {
        for i in 0...(source.count - needle.count) {
            let end = i + needle.count
            guard i >= before.count, source.count - end >= after.count,
                  source[i..<end].elementsEqual(needle),
                  source[(i - before.count)..<i].elementsEqual(before),
                  source[end..<(end + after.count)].elementsEqual(after) else { continue }
            guard match == nil else {
                throw Failure("AMBIGUOUS_TEXT", "Multiple ranges match the supplied context.")
            }
            match = i
        }
    }
    guard let i = match else { throw Failure("TEXT_NOT_FOUND", "No matching range.") }
    return CFRange(location: selectionType == "cursor_after" ? i + needle.count : i,
                   length: selectionType == "text" ? needle.count : 0)
}

func performSelectText(
    on item: AXUIElement, query: String, prefix: String? = nil, suffix: String? = nil,
    selectionType: String = "text", policy: Guardrails
) throws -> Object {
    try checkActionElement(item, policy: policy)
    let key = kAXSelectedTextRangeAttribute as CFString
    var writable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(item, key, &writable) == .success,
          writable.boolValue else {
        throw Failure("AX_NOT_SETTABLE", "Selection range is not writable.")
    }
    guard let original = attr(item, kAXValueAttribute) as? String else {
        throw Failure("AX_UNAVAILABLE", "Cannot read control text.")
    }
    var range = try computeUTF16SelectionRange(in: original, query: query, prefix: prefix,
                                               suffix: suffix, selectionType: selectionType)
    try checkActionElement(item, policy: policy)
    guard let current = attr(item, kAXValueAttribute) as? String,
          current.utf16.elementsEqual(original.utf16) else {
        throw Failure("STALE_TEXT", "Control text changed before selection.")
    }
    guard let value = AXValueCreate(.cfRange, &range),
          AXUIElementSetAttributeValue(item, key, value) == .success else {
        throw Failure("AX_WRITE_FAILED", "Cannot set selection range.")
    }
    var actual = CFRange(location: 0, length: 0)
    guard let raw = attr(item, kAXSelectedTextRangeAttribute),
          CFGetTypeID(raw) == AXValueGetTypeID(),
          AXValueGetValue(raw as! AXValue, .cfRange, &actual),
          actual.location == range.location, actual.length == range.length else {
        throw Failure("SELECTION_UNVERIFIED", "Selection range readback differs or is unavailable.")
    }
    return ["location": actual.location, "length": actual.length, "verified": true]
}

func validateSingleLineText(_ text: String) throws {
    let forbidden: Set<UInt32> = [13, 10, 0x85, 0x2028, 0x2029]
    if text.unicodeScalars.contains(where: { forbidden.contains($0.value) }) {
        throw Failure("MULTILINE_TEXT", "Single-line input contains a line separator.")
    }
}
