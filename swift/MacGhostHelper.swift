import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

typealias Object = [String: Any]
let null = NSNull()
let guide = "系统设置 → 隐私与安全性。按需开启「辅助功能」或「屏幕与系统音频录制」，重新启动系统列出的宿主，再运行 permissions。"
let deliveryMode = "cg_post_to_pid_no_activate"

struct Failure: Error {
    let code: String
    var focusAudit: Object?
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

let usage: [String: String] = [
    "permissions": "", "windows": "[--app <name>] [--visible-only]",
    "capture": "--window-id <id> [--out <new.png>] [--save-path <name.png>] [--crop <json>] [--grid <cols>x<rows>] [--max-width 1440]",
    "ax-tree": "--pid <pid> [--window-title <exact title>] [--max-depth 5] [--max-nodes 200]",
    "find-controls": "--pid <pid> [--window-title <exact>] [--role <role>] [--title-contains <text>] [--value-contains <text>] [--action <action>] [--max-results 20]",
    "ax-press": "[--restore-focus] --pid <pid> --path <windowIndex/childIndex/...>",
    "ax-set-value": "[--restore-focus] --pid <pid> --path <path> --value <text>",
    "bg-click": "[--restore-focus] --pid <pid> [--window-id <id>] --x <points> --y <points> [--button left|right] [--clicks 1|2]",
    "bg-scroll": "[--restore-focus] --pid <pid> [--window-id <id>] --x <points> --y <points> --dy <pixels>",
    "bg-key": "[--restore-focus] --pid <pid> --text <text>",
    "session": "--pid <pid>"
]

struct Options {
    var values: [String: String] = [:]
    let command: String
    init(_ args: [String]) throws {
        guard let name = args.first, let spec = usage[name] else {
            throw Failure("INVALID_ARGUMENT", "Unknown or missing command. Use --help.")
        }
        command = name
        var i = 1
        let keys = Set(spec.split { $0 == " " || $0 == "[" || $0 == "]" }.filter { $0.hasPrefix("--") }.map(String.init))
        while i < args.count {
            let key = args[i]
            guard keys.contains(key), values[key] == nil else { throw Failure("INVALID_ARGUMENT", "Unknown or duplicate option.") }
            i += 1
            if key == "--visible-only" || key == "--restore-focus" { values[key] = "true"; continue }
            let literal = ["--text", "--value", "--window-title", "--app", "--role", "--title-contains", "--value-contains", "--action"].contains(key)
            guard i < args.count, literal || !keys.contains(args[i]) else { throw Failure("INVALID_ARGUMENT", "Missing value for \(key).") }
            values[key] = args[i]
            i += 1
        }
    }
    func required(_ key: String, empty: Bool = false) throws -> String {
        guard let s = values[key], (empty || !s.isEmpty), s.utf8.count <= 65536 else { throw Failure("INVALID_ARGUMENT", "Invalid or missing \(key).") }
        return s
    }
    func integer(_ key: String, _ range: ClosedRange<Int>, _ fallback: Int? = nil) throws -> Int {
        if values[key] == nil, let fallback { return fallback }
        guard let n = Int(try required(key)), range.contains(n) else { throw Failure("INVALID_ARGUMENT", "\(key) outside allowed integer range.") }
        return n
    }
    func point(_ key: String) throws -> Double {
        guard let n = Double(try required(key)), n.isFinite, n >= 0 else { throw Failure("INVALID_ARGUMENT", "\(key) requires non-negative finite points.") }
        return n
    }
    func pid() throws -> pid_t { try pid_t(integer("--pid", 1...Int(Int32.max))) }
    func windowID() throws -> CGWindowID { try CGWindowID(integer("--window-id", 1...Int(UInt32.max))) }
}

struct Guardrails: Decodable {
    let identities, bundlePrefixes, markers: [String]
    static func load() throws -> Self {
        let file = try pluginRoot().appendingPathComponent("src/guardrails.json")
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file)) }
        catch { throw Failure("POLICY_UNAVAILABLE", "Cannot load the bundled guardrails.") }
    }
    func sensitive(_ identity: String, _ bundle: String = "", _ title: String = "") -> Bool {
        let name = identity.lowercased(), id = bundle.lowercased(), label = title.lowercased()
        return identities.contains { name == $0.lowercased() } || bundlePrefixes.contains { id.hasPrefix($0) }
            || markers.contains { label.contains($0) || name.contains($0) }
    }
    func protectedControl(role: String, subrole: String, title: String, description: String) -> Bool {
        role.isEmpty || subrole == kAXSecureTextFieldSubrole || subrole == kAXSystemDialogSubrole
            || sensitive("", "", title) || sensitive("", "", description)
    }
    func check(_ identity: String = "", _ bundle: String = "", _ title: String = "") throws {
        if sensitive(identity, bundle, title) { throw Failure("SENSITIVE_TARGET", "Protected process, window or control.") }
    }
}

func rectJSON(_ r: CGRect) -> Object {
    ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height]
}
struct Window {
    let id: CGWindowID, pid: pid_t, name: String, title: String?, bounds: CGRect, layer: Int, shown: Bool
    init?(_ record: NSDictionary) {
        guard let id = record[kCGWindowNumber] as? NSNumber, let pid = record[kCGWindowOwnerPID] as? NSNumber,
              let box = record[kCGWindowBounds] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: box),
              let layer = record[kCGWindowLayer] as? Int else { return nil }
        self.id = id.uint32Value; self.pid = pid.int32Value; bounds = rect; self.layer = layer
        name = record[kCGWindowOwnerName] as? String ?? ""
        title = record[kCGWindowName] as? String
        shown = record[kCGWindowIsOnscreen] as? Bool ?? false
    }
    func json(_ policy: Guardrails, bundle: String) -> Object {
        let blocked = policy.sensitive(name, bundle, title ?? "")
        return ["windowId": id, "pid": pid, "appName": name, "bundleId": bundle,
                "title": blocked ? null : (title as Any? ?? null), "bounds": rectJSON(bounds),
                "layer": layer, "isOnScreen": shown, "protected": blocked]
    }
}

func windows(_ visible: Bool = false) throws -> [Window] {
    guard let records = CGWindowListCopyWindowInfo(visible ? .optionOnScreenOnly : .optionAll, kCGNullWindowID) as? [NSDictionary]
    else { throw Failure("WINDOWS_UNAVAILABLE", "No WindowServer session or window information available.") }
    return records.compactMap(Window.init)
}

func processWindows(_ pid: pid_t, _ policy: Guardrails, inventory: [Window]? = nil) throws -> [Window] {
    let running = NSRunningApplication(processIdentifier: pid)
    let bundle = running?.bundleIdentifier ?? ""
    try policy.check(running?.localizedName ?? "", bundle)
    let owned = try (inventory ?? windows()).filter { $0.pid == pid }
    guard !owned.isEmpty else { throw Failure("TARGET_UNAVAILABLE", "Process has no identifiable windows.") }
    for w in owned {
        guard !w.name.isEmpty || !bundle.isEmpty else { throw Failure("TARGET_UNAVAILABLE", "Unknown window owner.") }
        try policy.check(w.name, bundle, w.title ?? "")
    }
    return owned
}

func requireAX() throws {
    guard AXIsProcessTrusted() else { throw Failure("AX_PERMISSION", guide) }
}

func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
}
func stringAttr(_ e: AXUIElement, _ key: String) -> String { attr(e, key) as? String ?? "" }
func elements(_ e: AXUIElement, _ key: String) -> [AXUIElement] {
    attr(e, key) as? [AXUIElement] ?? []
}
func element(_ e: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = attr(e, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func axRect(_ position: CFTypeRef?, _ dimensions: CFTypeRef?) -> CGRect? {
    guard let pos = position, let size = dimensions,
          CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s),
          p.x.isFinite, p.y.isFinite, s.width.isFinite, s.height.isFinite else { return nil }
    return CGRect(origin: p, size: s)
}
func frame(_ position: CFTypeRef?, _ dimensions: CFTypeRef?) -> Any {
    axRect(position, dimensions).map(rectJSON) as Any? ?? null
}
func actions(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(e, &names) == .success else { return [] }
    return names as? [String] ?? []
}
func verifiedAXValue(_ status: AXError, _ value: CFTypeRef?, optional: Bool = false,
                     roleVerified: Bool = false) throws -> CFTypeRef? {
    switch status {
    case .success: return value
    case .attributeUnsupported, .noValue: return nil
    case .notImplemented where optional: return nil
    case .failure where optional && roleVerified: return nil
    default: throw Failure("AX_UNAVAILABLE", "Cannot verify target accessibility attributes.")
    }
}

func policyAttribute(_ item: AXUIElement, _ key: String, optional: Bool = false,
                     verifiedRole: String? = nil) throws -> CFTypeRef? {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(item, key as CFString, &value)
    return try verifiedAXValue(status, value, optional: optional,
                               roleVerified: verifiedRole?.isEmpty == false)
}

func requiredRole(_ item: AXUIElement) throws -> String {
    guard let role = try policyAttribute(item, kAXRoleAttribute) as? String, !role.isEmpty else {
        throw Failure("AX_UNAVAILABLE", "Cannot inspect control role.")
    }
    return role
}

@discardableResult
func checkElement(_ e: AXUIElement, _ policy: Guardrails, verifiedRole: String? = nil) throws -> String? {
    let role = try verifiedRole ?? requiredRole(e)
    let subrole = try policyAttribute(e, kAXSubroleAttribute, optional: true, verifiedRole: role) as? String
    if subrole == kAXSecureTextFieldSubrole || subrole == kAXSystemDialogSubrole {
        throw Failure("SENSITIVE_TARGET", "Protected input field or system dialog.")
    }
    for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
        try policy.check("", "", policyAttribute(e, key, optional: true, verifiedRole: role) as? String ?? "")
    }
    return subrole
}

// Read public dialog labels and secure-field subroles before acting on a sibling
// control. Some authorization sheets put the question in static text, not the title.
func checkDialog(_ root: AXUIElement, _ policy: Guardrails) throws {
    var pending = [root], visited = 0
    while let item = pending.popLast() {
        visited += 1
        let role = try requiredRole(item)
        try checkElement(item, policy, verifiedRole: role)
        if role == kAXStaticTextRole {
            try policy.check("", "", policyAttribute(item, kAXValueAttribute) as? String ?? "")
        }
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &raw)
        let children: [AXUIElement]
        if status == .attributeUnsupported || status == .noValue { children = [] }
        else if status == .success, let items = raw as? [AXUIElement] { children = items }
        else { throw Failure("AX_UNAVAILABLE", "Cannot inspect child controls.") }
        guard children.count + pending.count + visited <= 192 else {
            throw Failure("TARGET_UNAVAILABLE", "Cannot fully inspect the active dialog.")
        }
        pending.append(contentsOf: children)
    }
}

func requiresDialogScan(role: String, subrole: String?, modal: Bool?) -> Bool {
    role == kAXSheetRole || subrole == kAXDialogSubrole || modal == true
}

func checkWindow(_ root: AXUIElement, _ policy: Guardrails) throws {
    let role = try requiredRole(root)
    let subrole = try checkElement(root, policy, verifiedRole: role)
    let modal = try policyAttribute(root, kAXModalAttribute, optional: true, verifiedRole: role) as? Bool
    if requiresDialogScan(role: role, subrole: subrole, modal: modal) {
        try checkDialog(root, policy)
        return
    }
    for child in try policyAttribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        let childRole = try requiredRole(child)
        if childRole == kAXSheetRole {
            try checkDialog(child, policy)
        } else if childRole == kAXWindowRole {
            // Embedded dialog windows need the same checks as top-level windows.
            let subrole = try checkElement(child, policy, verifiedRole: childRole)
            let modal = try policyAttribute(child, kAXModalAttribute, optional: true, verifiedRole: childRole) as? Bool
            if requiresDialogScan(role: childRole, subrole: subrole, modal: modal) {
                try checkDialog(child, policy)
            }
        }
    }
}

struct AXTarget {
    let app: AXUIElement, roots: [AXUIElement], policy: Guardrails
    init(_ pid: pid_t, _ policy: Guardrails, enableRichAX: Bool = false) throws {
        try requireAX()
        self.policy = policy
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        if enableRichAX { _ = enableAccessibility(app) }
        roots = elements(app, kAXWindowsAttribute)
        guard !roots.isEmpty else { throw Failure("AX_UNAVAILABLE", "No accessible window for this process.") }
        for root in roots { try checkWindow(root, policy) }
    }
    func resolve(_ path: [Int]) throws -> AXUIElement {
        guard let first = path.first, roots.indices.contains(first) else {
            throw Failure("STALE_PATH", "Inspect the current UI tree again.")
        }
        var item = roots[first]
        try checkElement(item, policy)
        for index in path.dropFirst() {
            var result: CFArray?
            guard AXUIElementCopyAttributeValues(item, kAXChildrenAttribute as CFString, index, 1, &result) == .success,
                  let children = result as? [AXUIElement], let child = children.first else {
                throw Failure("STALE_PATH", "Inspect the current UI tree again.")
            }
            item = child
            try checkElement(item, policy)
        }
        return item
    }
    func tree(_ title: String?, _ depth: Int, _ limit: Int) throws -> Object {
        var nodes = [Object](), truncated = false, matched = false
        let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                    kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute]
        func walk(_ e: AXUIElement, _ path: String, _ level: Int) {
            guard nodes.count < limit else { truncated = true; return }
            var metadata = attributes(e, keys) ?? [:]
            if metadata.isEmpty { for key in keys { metadata[key] = attr(e, key) } }
            let role = metadata[kAXRoleAttribute] as? String ?? ""
            let title = metadata[kAXTitleAttribute] as? String ?? ""
            let description = metadata[kAXDescriptionAttribute] as? String ?? ""
            let protected = policy.protectedControl(role: role, subrole: metadata[kAXSubroleAttribute] as? String ?? "",
                                                    title: title, description: description)
            var row: Object = ["nodeId": path, "role": role, "title": "", "description": "", "value": null,
                               "frame": frame(metadata[kAXPositionAttribute], metadata[kAXSizeAttribute]),
                               "actions": [String](), "enabled": (metadata[kAXEnabledAttribute] as? Bool) as Any? ?? null,
                               "protected": protected]
            if !protected {
                row["title"] = String(title.prefix(1024))
                row["description"] = String(description.prefix(1024))
                if let value = attr(e, kAXValueAttribute) {
                    if let s = value as? String { row["value"] = String(s.prefix(1024)) }
                    else if let n = value as? NSNumber, n.doubleValue.isFinite { row["value"] = n }
                }
                row["actions"] = actions(e)
            }
            nodes.append(row)
            guard !protected else { return }
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(e, kAXChildrenAttribute as CFString, &count) == .success, count > 0 else { return }
            guard level < depth, nodes.count < limit else { truncated = true; return }
            var result: CFArray?
            let take = min(count, limit - nodes.count)
            guard AXUIElementCopyAttributeValues(e, kAXChildrenAttribute as CFString, 0, take, &result) == .success,
                  let children = result as? [AXUIElement] else { truncated = true; return }
            if take < count { truncated = true }
            for (i, child) in children.enumerated() {
                if nodes.count == limit { truncated = true; break }
                walk(child, "\(path)/\(i)", level + 1)
            }
        }
        for (i, root) in roots.enumerated() where title == nil || stringAttr(root, kAXTitleAttribute) == title {
            matched = true
            if nodes.count == limit { truncated = true; break }
            walk(root, "\(i)", 0)
        }
        guard matched else { throw Failure("WINDOW_NOT_FOUND", "No exact AX window title match.") }
        return ["nodes": nodes, "truncated": truncated]
    }
}

func parsePath(_ s: String) throws -> [Int] {
    let pieces = s.split(separator: "/", omittingEmptySubsequences: false)
    guard (1...33).contains(pieces.count) else { throw Failure("INVALID_ARGUMENT", "Invalid AX path depth.") }
    return try pieces.map {
        guard !$0.isEmpty, $0.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int($0), n <= 1_000_000
        else { throw Failure("INVALID_ARGUMENT", "AX paths use zero-based decimal indices separated by /.") }
        return n
    }
}

func parseGrid(_ s: String?) throws -> (Int, Int)? {
    guard let s else { return nil }
    let parts = s.split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2, let c = Int(parts[0]), let r = Int(parts[1]), (1...26).contains(c), (1...50).contains(r)
    else { throw Failure("INVALID_ARGUMENT", "Grid must be 1...26 columns x 1...50 rows, e.g. 6x4.") }
    return (c, r)
}

func drawGrid(_ image: CGImage, _ grid: (Int, Int)) throws -> CGImage {
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure("IMAGE_ERROR", "Cannot allocate grid bitmap.") }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let cw = CGFloat(w) / CGFloat(grid.0), ch = CGFloat(h) / CGFloat(grid.1)
    let fontSize = max(6, min(13, min(cw / 6, ch / 3)))
    let style: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
        .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.65)]
    ctx.setStrokeColor(CGColor(red: 0, green: 0.85, blue: 1, alpha: 0.7))
    ctx.setLineWidth(1)
    for c in 0..<grid.0 {
        let x = CGFloat(c) * cw
        ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: CGFloat(h)))
    }
    for r in 0..<grid.1 {
        let y = CGFloat(h) - CGFloat(r) * ch
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: CGFloat(w), y: y))
    }
    ctx.strokePath()
    for r in 0..<grid.1 {
        for c in 0..<grid.0 {
            let x = CGFloat(c) * cw, top = CGFloat(r) * ch
            let cell = "\(UnicodeScalar(65 + c)!)\(r + 1)"
            let tick = (r == 0 ? " x\(Int(x))" : "") + (c == 0 ? " y\(Int(top))" : "")
            (cell + tick as NSString).draw(at: CGPoint(x: x + 2, y: CGFloat(h) - top - fontSize - 4), withAttributes: style)
        }
    }
    guard let output = ctx.makeImage() else { throw Failure("IMAGE_ERROR", "Cannot render grid.") }
    return output
}

func capture(_ opt: Options, _ policy: Guardrails) async throws -> Object {
    let id = try opt.windowID(), grid = try parseGrid(opt.values["--grid"])
    let crop = try Crop.parse(opt.values["--crop"])
    let widthLimit = try opt.integer("--max-width", 1...8192, 1440)
    guard (opt.values["--out"] == nil) != (opt.values["--save-path"] == nil) else {
        throw Failure("INVALID_ARGUMENT", "Specify exactly one capture destination.")
    }
    let file = try opt.values["--save-path"].map { try CaptureFile(root: pluginRoot(), requested: $0) }
    let out = try opt.values["--out"].map { _ in URL(fileURLWithPath: try opt.required("--out")) }
    if let out, out.pathExtension.lowercased() != "png" { throw Failure("INVALID_ARGUMENT", "--out requires a new PNG file.") }
    guard CGPreflightScreenCaptureAccess() else { throw Failure("SCREEN_PERMISSION", guide) }
    let inventory = try windows()
    guard let record = inventory.first(where: { $0.id == id }) else { throw Failure("WINDOW_NOT_FOUND", "Unknown window ID.") }
    _ = try processWindows(record.pid, policy, inventory: inventory)
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let window = content.windows.first(where: { $0.windowID == id }), let owner = window.owningApplication,
          owner.processID == record.pid else { throw Failure("WINDOW_UNAVAILABLE", "Window closed or unavailable to ScreenCaptureKit.") }
    try policy.check(owner.applicationName, owner.bundleIdentifier, window.title ?? "")
    func verifyCaptureTarget() throws {
        let ax = try AXTarget(record.pid, policy)
        let target = SessionTarget(ax: ax, owned: try processWindows(record.pid, policy), windowID: id)
        let live = try target.window()
        guard live.bounds == record.bounds,
              let root = ax.roots.first(where: {
                  axRect(attr($0, kAXPositionAttribute), attr($0, kAXSizeAttribute)) == live.bounds &&
                      (try? target.check($0, in: live)) != nil
              }) else { throw Failure("STALE_WINDOW", "Cannot verify capture window.") }
        try checkWindow(root, policy)
        if let raw = try policyAttribute(ax.app, kAXFocusedUIElementAttribute) {
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw Failure("AX_UNAVAILABLE", "Cannot identify focused control.")
            }
            let focused = raw as! AXUIElement
            try checkElement(focused, policy)
        }
    }
    try verifyCaptureTarget()
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let size = filter.contentRect.size, scale = CGFloat(filter.pointPixelScale)
    guard size.width > 0, size.height > 0, scale > 0 else { throw Failure("IMAGE_ERROR", "Window has no capture area.") }
    guard window.frame.size == record.bounds.size else { throw Failure("WINDOW_CHANGED", "Window size changed. Capture again.") }
    let pixelScale = min(scale, CGFloat(widthLimit) / size.width)
    let dw = (size.width * pixelScale).rounded(), dh = (size.height * pixelScale).rounded()
    guard dw.isFinite, dh.isFinite, dh <= 16384, dw * dh <= 16_777_216 else { throw Failure("IMAGE_LIMIT", "Reduce --max-width.") }
    let config = SCStreamConfiguration()
    config.width = max(1, Int(dw)); config.height = max(1, Int(dh))
    config.ignoreShadowsSingleWindow = true; config.ignoreGlobalClipSingleWindow = true; config.showsCursor = false
    if #available(macOS 14.2, *) { config.includeChildWindows = false }
    var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    try verifyCaptureTarget()
    let geometry = CaptureGeometry(crop: crop, width: image.width, height: image.height, window: window.frame.size)
    image = try geometry.clip(image)
    if let grid { image = try drawGrid(image, grid) }
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure("IMAGE_ERROR", "PNG encoding failed.") }
    var meta = geometry.metadata(grid: grid)
    meta["windowId"] = id
    meta["pid"] = record.pid
    meta["width"] = image.width
    meta["height"] = image.height
    meta["bounds"] = rectJSON(window.frame)
    meta["grid"] = opt.values["--grid"] as Any? ?? null
    if let file {
        try file.save(png)
        meta["savedPath"] = file.path
    } else if let out {
        let fd = open(out.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure("OUTPUT_ERROR", "Cannot create PNG. Use a fresh filename.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: png); try handle.close() }
        catch { try? FileManager.default.removeItem(at: out); throw Failure("OUTPUT_ERROR", "Incomplete PNG removed.") }
        meta["out"] = out.path
    }
    return meta
}

@MainActor
func postEvents(_ opt: Options, _ pid: pid_t, _ policy: Guardrails) async throws -> Object {
    let key = opt.command == "bg-key", scroll = opt.command == "bg-scroll"
    let text = key ? try opt.required("--text") : ""
    if key { try validateSingleLineText(text) }
    let x = key ? 0 : try opt.point("--x"), y = key ? 0 : try opt.point("--y")
    let clicks = try opt.integer("--clicks", 1...2, 1), button = opt.values["--button"] ?? "left"
    guard ["left", "right"].contains(button) else { throw Failure("INVALID_ARGUMENT", "Use left or right.") }
    let dy = scroll ? try opt.integer("--dy", -100000...100000) : 0
    guard !scroll || dy != 0 else { throw Failure("INVALID_ARGUMENT", "Use a nonzero scroll delta.") }
    let wanted = opt.values["--window-id"] == nil ? nil : try opt.windowID()
    try requireAX()
    guard CGPreflightPostEventAccess() else { throw Failure("EVENT_PERMISSION", guide) }
    let owned = try processWindows(pid, policy)
    guard let source = CGEventSource(stateID: .privateState) else { throw Failure("EVENT_ERROR", "Cannot create event source.") }
    var result: Object = ["pid": pid, "mode": deliveryMode, "delivery": "posted_unverified",
        "guidance": "Read back the UI. If ignored use ax-press / ax-set-value, or an already authorized browser CDP session."]
    if key {
        let target = try AXTarget(pid, policy)
        guard let focused = element(target.app, kAXFocusedUIElementAttribute),
              let focusedWindow = element(target.app, kAXFocusedWindowAttribute),
              target.roots.contains(where: { CFEqual($0, focusedWindow) }) else {
            throw Failure("NO_FOCUSED_CONTROL", "Target app has no identifiable focused control/window. Use ax-set-value.")
        }
        try checkElement(focusedWindow, policy); try checkElement(focused, policy)
        func send(_ units: [UInt16]) throws {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw Failure("EVENT_ERROR", "Cannot construct keyboard events.")
            }
            for event in [down, up] {
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.postToPid(pid)
            }
        }
        return try await guardWrite(pid, policy, opt) {
            var units = [UInt16]()
            for scalar in text.unicodeScalars {
                let next = String(scalar).utf16
                if units.count + next.count > 20 { try send(units); units.removeAll(keepingCapacity: true) }
                units.append(contentsOf: next)
            }
            if !units.isEmpty { try send(units) }
            return result
        }
    } else {
        let candidates = owned.filter { $0.layer == 0 && !$0.bounds.isEmpty && (wanted == nil || $0.id == wanted) }
        guard candidates.count == 1, let w = candidates.first else {
            throw Failure("WINDOW_AMBIGUOUS", "Specify a current layer-0 --window-id owned by this PID.")
        }
        guard x < w.bounds.width, y < w.bounds.height else { throw Failure("OUT_OF_BOUNDS", "Use window-local points inside its bounds.") }
        let p = CGPoint(x: w.bounds.minX + x, y: w.bounds.minY + y)
        func post(_ event: CGEvent) {
            event.flags = []
            event.location = p
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.id))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.id))
            event.postToPid(pid)
        }
        return try await guardWrite(pid, policy, opt) {
            let live = SessionTarget(ax: try AXTarget(pid, policy), owned: try processWindows(pid, policy), windowID: w.id)
            guard try live.window().bounds == w.bounds else { throw Failure("STALE_WINDOW", "Window moved.") }
            _ = try live.hit(CGPoint(x: x, y: y), in: w, expected: nil)
            if scroll {
                guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0)
                else { throw Failure("EVENT_ERROR", "Cannot construct scroll event.") }
                post(event)
            } else {
                let right = button == "right"
                for i in 1...clicks {
                    for type: CGEventType in [right ? .rightMouseDown : .leftMouseDown, right ? .rightMouseUp : .leftMouseUp] {
                        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: right ? .right : .left)
                        else { throw Failure("EVENT_ERROR", "Cannot construct mouse event.") }
                        event.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                        post(event)
                    }
                }
            }
            result["windowId"] = w.id
            return result
        }
    }
}

@MainActor
func run(_ args: [String]) async throws -> Object {
    if args == ["--help"] || args == ["-h"] || (args.count == 2 && args[1] == "--help" && usage[args[0]] != nil) {
        return ["commands": args.count == 2 ? [args[0]: usage[args[0]]!] : usage,
                "coordinates": "Window-local points from top left; use cellToPoint or pointOrigin plus scaled pixel offsets."]
    }
    let opt = try Options(args)
    if opt.command == "permissions" {
        return ["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(),
                "postEvents": CGPreflightPostEventAccess(), "guidance": guide]
    }
    let policy = try Guardrails.load()
    if opt.command == "windows" {
        let filter = try opt.values["--app"].map { _ in try opt.required("--app") }
        if let filter { try policy.check(filter) }
        let list = try windows(opt.values["--visible-only"] != nil)
        var bundles = [pid_t: String]()
        let rows: [Object] = list.filter { filter == nil || $0.name.localizedCaseInsensitiveContains(filter!) }.map {
            if bundles[$0.pid] == nil { bundles[$0.pid] = NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier ?? "" }
            return $0.json(policy, bundle: bundles[$0.pid] ?? "")
        }
        return ["windows": rows]
    }
    if opt.command == "capture" { return try await capture(opt, policy) }
    let pid = try opt.pid()
    if opt.command.hasPrefix("bg-") { return try await postEvents(opt, pid, policy) }
    let depth = try opt.integer("--max-depth", 0...32, 5), limit = try opt.integer("--max-nodes", 1...1000, 200)
    let search = opt.command == "find-controls"
    let count = try opt.integer("--max-results", 1...100, 20)
    let path = (search || opt.command == "ax-tree") ? [] : try parsePath(opt.required("--path"))
    let value = opt.command == "ax-set-value" ? try opt.required("--value", empty: true) : ""
    try requireAX()
    _ = try processWindows(pid, policy)
    let target = try AXTarget(pid, policy)
    if opt.command == "ax-tree" { return try target.tree(opt.values["--window-title"], depth, limit) }
    if search {
        let query = ControlQuery(role: opt.values["--role"], title: opt.values["--title-contains"], value: opt.values["--value-contains"],
                                 action: opt.values["--action"], maxResults: count)
        return try target.find(opt.values["--window-title"], query)
    }
    let item = try target.resolve(path)
    if attr(item, kAXEnabledAttribute) as? Bool == false { throw Failure("DISABLED_CONTROL", "Control is disabled.") }
    if opt.command == "ax-press" {
        guard actions(item).contains(kAXPressAction) else { throw Failure("UNSUPPORTED_ACTION", "Control does not expose AXPress.") }
    } else {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(item, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue
        else { throw Failure("READ_ONLY", "AXValue is not settable.") }
    }
    return try await guardWrite(pid, policy, opt) {
        let status = opt.command == "ax-press" ? AXUIElementPerformAction(item, kAXPressAction as CFString)
            : AXUIElementSetAttributeValue(item, kAXValueAttribute as CFString, value as CFString)
        guard status == .success else { throw Failure("AX_ACTION_FAILED", "AX returned \(status.rawValue). Inspect state before retrying.") }
        return ["pid": pid, "nodeId": opt.values["--path"]!, "mode": "ax_no_activate", "delivery": "ax_success"]
    }
}

@main
struct MacGhostHelper {
    static func main() async {
        var response: Object
        var status: Int32 = 0
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "session", args != ["session", "--help"] {
                let opt = try Options(args)
                try await runSession(pid: opt.pid(), policyLoader: Guardrails.load)
                return
            }
            if args == ["--stdin-args"] {
                var data = Data()
                while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
                    guard data.count + chunk.count <= 1024 * 1024 else {
                        throw Failure("INVALID_ARGUMENT", "Argument payload too large.")
                    }
                    data.append(chunk)
                }
                guard let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                    throw Failure("INVALID_ARGUMENT", "Expected a JSON argument array.")
                }
                response = try await run(decoded)
            } else {
                response = try await run(args)
            }
            response["ok"] = true
        }
        catch {
            let e = error as? Failure ?? Failure("NATIVE_ERROR", "Apple API error \((error as NSError).domain) \((error as NSError).code).")
            response = ["ok": false, "error": ["code": e.code, "message": e.message]]
            response["focusAudit"] = e.focusAudit
            status = e.code == "INVALID_ARGUMENT" ? 2 : 1
        }
        do { FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) }
        catch { FileHandle.standardOutput.write(Data(#"{"ok":false,"error":{"code":"ENCODING_ERROR","message":"JSON encoding failed."}}"#.utf8)); status = 1 }
        FileHandle.standardOutput.write(Data([10]))
        exit(status)
    }
}
