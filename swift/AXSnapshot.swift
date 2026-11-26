import Foundation
import ApplicationServices
import CoreGraphics

func enableAccessibility(_ app: AXUIElement) -> Object {
    var report = Object()
    for key in ["AXManualAccessibility", "AXEnhancedUserInterface",
                "_AXExhibitsMacCatalystBehavior"] {
        let name = key as CFString
        var before: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(app, name, &before)
        var writable = DarwinBoolean(false)
        let probe = AXUIElementIsAttributeSettable(app, name, &writable)
        var item: Object = [
            "read": read.rawValue, "probe": probe.rawValue,
            "before": (before as? Bool) as Any? ?? null,
            "settable": writable.boolValue
        ]
        if before as? Bool != true && probe == .success && writable.boolValue {
            item["set"] = AXUIElementSetAttributeValue(
                app, name, kCFBooleanTrue
            ).rawValue
            var after: CFTypeRef?
            item["readback"] = AXUIElementCopyAttributeValue(
                app, name, &after
            ).rawValue
            item["after"] = (after as? Bool) as Any? ?? null
        } else {
            item["after"] = item["before"]
        }
        report[key] = item
    }
    return report
}

private struct SnapshotIdentity {
    let root: AXUIElement
    let element: AXUIElement
    let ancestors: [AXUIElement]
    let identifier: String?
    let role: String

    func sameWindow(_ other: Self) -> Bool { CFEqual(root, other.root) }

    func sameAncestors(_ other: Self) -> Bool {
        ancestors.count == other.ancestors.count &&
        zip(ancestors, other.ancestors).allSatisfy { CFEqual($0.0, $0.1) }
    }

    func sameKey(_ other: Self) -> Bool {
        identifier != nil && identifier == other.identifier &&
        role == other.role && sameWindow(other)
    }
}

// Session-owned. Capture and resolution run on the session's serial executor.
final class AXElementCache {
    fileprivate struct Entry {
        var identity: SnapshotIdentity
        var unique: Bool
    }

    fileprivate var entries = [UInt64: Entry]()
    fileprivate var nextID: UInt64 = 1
    fileprivate var latest: AXFrame?
    fileprivate var scope: CGWindowID?
    fileprivate var limits = (depth: 0, nodes: 0, ms: 0)

    fileprivate func id(for identity: SnapshotIdentity) throws -> UInt64 {
        if let old = entries.first(where: {
            $0.value.identity.sameWindow(identity) &&
            CFEqual($0.value.identity.element, identity.element)
        }) {
            return old.key
        }
        guard nextID < UInt64.max else {
            throw Failure("ID_EXHAUSTED", "Start a new accessibility session.")
        }
        let id = nextID
        nextID += 1
        entries[id] = Entry(identity: identity, unique: false)
        return id
    }

    func resolve(ref: String, snapshot: String, in target: AXTarget) throws -> AXUIElement {
        guard let latest, snapshot == latest.frameID else {
            throw Failure("STALE_FRAME", "Capture the current frame.")
        }
        let stale = Failure("STALE_ELEMENT", "Element identity cannot be verified.")
        guard let node = latest.nodes.first(where: { $0.ref == ref }),
              !node.protected, let old = entries[node.id] else { throw stale }

        // A private scan verifies current ancestry and policy without advancing
        // the public frame or modifying its baseline.
        let live = AXElementCache()
        let scan = try captureCompactFrame(
            target: target, windowID: scope, cache: live,
            maxDepth: limits.depth, maxNodes: limits.nodes, timeBudgetMs: limits.ms
        )
        let candidates = scan.nodes.compactMap { n -> SnapshotIdentity? in
            guard !n.protected else { return nil }
            return live.entries[n.id]?.identity
        }
        if let direct = candidates.first(where: {
            old.identity.sameWindow($0) && old.identity.role == $0.role &&
            CFEqual(old.identity.element, $0.element)
        }) {
            return direct.element
        }

        var ignored: CFTypeRef?
        let validity = AXUIElementCopyAttributeValue(
            old.identity.element, kAXRoleAttribute as CFString, &ignored
        )
        guard validity == .invalidUIElement, scan.complete, old.unique else {
            throw stale
        }
        let matches = candidates.filter { old.identity.sameKey($0) }
        guard matches.count == 1, let match = matches.first,
              old.identity.sameAncestors(match) else { throw stale }
        entries[node.id] = Entry(identity: match, unique: true)
        return match.element
    }
}

private func snapshotRoots(_ target: AXTarget, _ windowID: CGWindowID?) throws
    -> [(Int, AXUIElement)] {
    var pid: pid_t = 0
    guard AXUIElementGetPid(target.app, &pid) == .success else {
        throw Failure("STALE_ELEMENT", "The target application is unavailable.")
    }
    let owned = try processWindows(pid, target.policy)
    // Rebuild the target to recheck newly appeared windows and dialogs.
    let fresh = try AXTarget(pid, target.policy)
    let roots = fresh.roots.enumerated().map { ($0.offset, $0.element) }
    guard let windowID else { return roots }

    let stale = Failure("STALE_ELEMENT", "Cannot uniquely bind the requested window.")
    guard let requested = owned.first(where: { $0.id == windowID }) else { throw stale }
    // 优先按几何（layer + bounds）做双向唯一匹配；仅在同尺寸重叠窗口时再以标题（含主标题前缀，兼容“备忘录 – 14个备忘录”）消歧。
    func titleCompatible(_ wTitle: String?, _ axTitle: String) -> Bool {
        guard let wt = wTitle, !wt.isEmpty else { return true }
        return wt == axTitle || axTitle.hasPrefix(wt + " –") || axTitle.hasPrefix(wt + " -") || axTitle.hasPrefix(wt + " —")
    }
    let sameBoundsWindows = owned.filter { $0.layer == requested.layer && $0.bounds == requested.bounds }
    var byBounds = [(Int, AXUIElement, String)]()
    for (index, root) in roots {
        guard let box = axRect(try policyAttribute(root, kAXPositionAttribute),
                               try policyAttribute(root, kAXSizeAttribute)) else {
            throw stale
        }
        if box == requested.bounds {
            let role = try requiredRole(root)
            let title = try policyAttribute(root, kAXTitleAttribute, optional: true, verifiedRole: role) as? String ?? ""
            byBounds.append((index, root, title))
        }
    }
    if sameBoundsWindows.count == 1 && byBounds.count == 1 {
        return [(byBounds[0].0, byBounds[0].1)]
    }
    var found = [(Int, AXUIElement)]()
    for (index, root, title) in byBounds where titleCompatible(requested.title, title) {
        if sameBoundsWindows.filter({ titleCompatible($0.title, title) }).count == 1 {
            found.append((index, root))
        }
    }
    guard found.count == 1 else { throw stale }
    return found
}

func captureCompactFrame(target: AXTarget, windowID: CGWindowID?,
                         cache: AXElementCache, maxDepth: Int,
                         maxNodes: Int, timeBudgetMs: Int) throws -> AXFrame {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(max(0, timeBudgetMs)))
    let roots = try snapshotRoots(target, windowID)
    var nodes = [CompactNode]()
    var identities = [UInt64: SnapshotIdentity]()
    var orders = [String: Int]()
    var visited = 0
    var truncated = false
    var failed = false

    func hasBudget() -> Bool {
        if visited >= maxNodes || clock.now >= deadline {
            truncated = true
            return false
        }
        return true
    }

    func walk(_ item: AXUIElement, root: AXUIElement, ancestors: [AXUIElement],
              path: [Int], parent: String?) throws {
        guard hasBudget() else { return }
        visited += 1
        if ancestors.contains(where: { CFEqual($0, item) }) {
            failed = true
            return
        }

        var verifiedRole: String?
        func read(_ key: String) throws -> CFTypeRef? {
            guard clock.now < deadline else {
                truncated = true
                throw Failure("CAPTURE_TIMEOUT", "Capture deadline reached.")
            }
            return try policyAttribute(item, key, optional: key != kAXRoleAttribute, verifiedRole: verifiedRole)
        }
        func label(_ key: String) throws -> String? {
            guard let raw = try read(key) as? String, !raw.isEmpty else { return nil }
            return raw
        }

        var descendantParent = parent
        do {
            guard let role = try label(kAXRoleAttribute) else {
                throw Failure("AX_UNAVAILABLE", "Cannot inspect control role.")
            }
            verifiedRole = role
            let subrole = try label(kAXSubroleAttribute) ?? ""
            let title = try label(kAXTitleAttribute)
            let detail = try label(kAXDescriptionAttribute)
            let blocked = target.policy.protectedControl(
                role: role, subrole: subrole, title: title ?? "", description: detail ?? ""
            )
            let identifier = blocked ? nil : try label("AXIdentifier")
            var value: String?
            var enabled: Bool?
            var focused: Bool?
            var selected: Bool?
            var names = [String]()
            var box: CGRect?

            if !blocked {
                let raw = try read(kAXValueAttribute)
                value = raw as? String ?? (raw as? NSNumber)?.stringValue
                enabled = try read(kAXEnabledAttribute) as? Bool
                focused = try read(kAXFocusedAttribute) as? Bool
                selected = try read(kAXSelectedAttribute) as? Bool
                var actionNames: CFArray?
                let status = AXUIElementCopyActionNames(item, &actionNames)
                if status != .actionUnsupported {
                    let raw = try verifiedAXValue(status, actionNames, optional: true, roleVerified: true)
                    names = (raw as? [String] ?? []).sorted()
                }
                box = axRect(try read(kAXPositionAttribute), try read(kAXSizeAttribute))
            }
            let layout = ["AXGroup", "AXLayoutArea", "AXLayoutItem"].contains(role)
            let keep = blocked || ancestors.isEmpty || !layout || identifier != nil ||
                title != nil || detail != nil || value != nil || !names.isEmpty ||
                enabled != nil || focused != nil || selected != nil
            if keep {
                let identity = SnapshotIdentity(
                    root: root, element: item, ancestors: ancestors,
                    identifier: identifier, role: role
                )
                let id = try cache.id(for: identity)
                guard identities[id] == nil else { failed = true; return }
                identities[id] = identity
                let ref = "e\(id)"
                let key = parent ?? ""
                let order = orders[key, default: 0]
                orders[key] = order + 1
                nodes.append(CompactNode(
                    ref: ref, id: id, parentRef: parent, order: order,
                    role: role, title: blocked ? nil : title,
                    description: blocked ? nil : detail, value: value,
                    enabled: enabled, focused: focused, selected: selected,
                    actions: names, frame: box, protected: blocked, path: path
                ))
                descendantParent = ref
            }
            if blocked { return }
        } catch let error as Failure where ["ID_EXHAUSTED", "AX_UNAVAILABLE"].contains(error.code) {
            throw error
        } catch {
            failed = true
            return
        }

        var count: CFIndex = 0
        let key = kAXChildrenAttribute as CFString
        let countStatus = AXUIElementGetAttributeValueCount(item, key, &count)
        _ = try verifiedAXValue(countStatus, nil)
        guard countStatus == .success, count > 0 else { return }
        guard ancestors.count < maxDepth else { truncated = true; return }

        var offset = 0
        while offset < count {
            guard hasBudget() else { return }
            let length = min(32, count - offset, maxNodes - visited)
            var page: CFArray?
            let pageStatus = AXUIElementCopyAttributeValues(item, key, offset, length, &page)
            _ = try verifiedAXValue(pageStatus, page)
            guard pageStatus == .success,
                  let children = page as? [AXUIElement], children.count == length else {
                failed = true
                return
            }
            for (i, child) in children.enumerated() {
                guard hasBudget() else { return }
                try walk(child, root: root, ancestors: ancestors + [item],
                         path: path + [offset + i], parent: descendantParent)
            }
            offset += length
        }
    }

    for (index, root) in roots {
        guard hasBudget() else { break }
        try walk(root, root: root, ancestors: [], path: [index], parent: nil)
    }
    if clock.now >= deadline { truncated = true }
    let complete = !truncated && !failed
    for (id, identity) in identities {
        let unique = complete && identity.identifier != nil &&
            identities.values.lazy.filter { identity.sameKey($0) }.prefix(2).count == 1
        cache.entries[id] = .init(identity: identity, unique: unique)
    }
    let result = AXFrame(frameID: UUID().uuidString, nodes: nodes,
                         complete: complete, truncated: truncated)
    cache.latest = result
    cache.scope = windowID
    cache.limits = (maxDepth, maxNodes, timeBudgetMs)
    return result
}
