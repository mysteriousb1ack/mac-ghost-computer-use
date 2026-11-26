import ApplicationServices
import Foundation

struct ControlQuery {
    let role, title, value, action: String?
    let maxResults: Int

    func matches(role actualRole: String, title actualTitle: String,
                 value getValue: () -> String?, actions getActions: () -> [String]) -> Bool {
        if let role, role != actualRole { return false }
        if let title, !actualTitle.localizedCaseInsensitiveContains(title) { return false }
        if let value, getValue()?.localizedCaseInsensitiveContains(value) != true { return false }
        if let action, !getActions().contains(action) { return false }
        return true
    }
}

struct SearchNode<Node> {
    var row: Object?
    var children: [Node]
    var incomplete = false
}

// Paths and limits apply to the original AX tree, including filtered-out siblings.
func searchControls<Node>(roots: [(Int, Node)], maxResults: Int,
                          hasTime: () -> Bool, read: (Node, String) -> SearchNode<Node>) -> Object {
    var rows = [Object](), visited = 0, truncated = false, stopped = false
    func visit(_ node: Node, _ path: String, _ depth: Int) {
        guard rows.count < maxResults, visited < 10000, hasTime() else { truncated = true; stopped = true; return }
        visited += 1
        let entry = read(node, path)
        if let row = entry.row { rows.append(row) }
        if entry.incomplete { truncated = true }
        if depth == 32 && !entry.children.isEmpty { truncated = true; return }
        for (index, child) in entry.children.enumerated() {
            visit(child, "\(path)/\(index)", depth + 1)
            if stopped { break }
        }
    }
    for (index, root) in roots {
        visit(root, String(index), 0)
        if stopped { break }
    }
    return ["controls": rows, "visited": visited, "truncated": truncated]
}

func attributes(_ item: AXUIElement, _ keys: [String]) -> [String: AnyObject]? {
    var batch: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(item, keys as CFArray, [], &batch) == .success,
          let values = batch as? [AnyObject], values.count == keys.count else { return nil }
    return Dictionary(uniqueKeysWithValues: zip(keys, values))
}

extension AXTarget {
    func find(_ windowTitle: String?, _ query: ControlQuery) throws -> Object {
        let start = DispatchTime.now().uptimeNanoseconds
        let rootsToSearch = roots.enumerated().filter { windowTitle == nil || stringAttr($0.element, kAXTitleAttribute) == windowTitle }
        guard !rootsToSearch.isEmpty else { throw Failure("WINDOW_NOT_FOUND", "No exact AX window title match.") }
        let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                    kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXChildrenAttribute]
        var result = searchControls(roots: rootsToSearch, maxResults: query.maxResults, hasTime: {
            DispatchTime.now().uptimeNanoseconds - start < 5_000_000_000
        }) { item, path -> SearchNode<AXUIElement> in
            guard let data = attributes(item, keys), let role = data[kAXRoleAttribute] as? String else {
                return SearchNode(row: nil, children: [], incomplete: true)
            }
            let title = data[kAXTitleAttribute] as? String ?? "", description = data[kAXDescriptionAttribute] as? String ?? ""
            let subrole = data[kAXSubroleAttribute] as? String ?? ""
            guard !policy.protectedControl(role: role, subrole: subrole, title: title, description: description) else {
                return SearchNode(row: nil, children: [])
            }
            let childValue = data[kAXChildrenAttribute]
            let children = childValue as? [AXUIElement] ?? []
            var names: [String]?
            func getActions() -> [String] {
                if let names { return names }
                let result = actions(item)
                names = result
                return result
            }
            let matched = query.matches(role: role, title: title, value: {
                let value = attr(item, kAXValueAttribute)
                return (value as? String) ?? (value as? NSNumber)?.stringValue
            }, actions: getActions)
            var row: Object?
            if matched {
                let enabled = data[kAXEnabledAttribute] as? Bool
                var writable = DarwinBoolean(false)
                let known = AXUIElementIsAttributeSettable(item, kAXValueAttribute as CFString, &writable) == .success
                row = ["nodeId": path, "role": role, "title": String(title.prefix(1024)), "description": String(description.prefix(1024)),
                       "frame": frame(data[kAXPositionAttribute], data[kAXSizeAttribute]), "actions": getActions(),
                       "enabled": enabled as Any? ?? null, "valueSettable": known ? writable.boolValue as Any : null]
            }
            var incomplete = false
            if let error = childValue, CFGetTypeID(error) == AXValueGetTypeID() {
                var status = AXError.success
                if AXValueGetValue(error as! AXValue, .axError, &status) {
                    incomplete = status != .attributeUnsupported && status != .noValue
                }
            }
            return SearchNode(row: row, children: children, incomplete: incomplete)
        }
        result["elapsedMs"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return result
    }
}
