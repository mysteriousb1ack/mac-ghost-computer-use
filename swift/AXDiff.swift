import Foundation
import CoreGraphics

struct CompactNode: Equatable {
    let ref: String
    let id: UInt64
    let parentRef: String?
    let order: Int
    let role: String
    let title: String?
    let description: String?
    let value: String?
    let enabled: Bool?
    let focused: Bool?
    let selected: Bool?
    let actions: [String]
    let frame: CGRect?
    let protected: Bool
    let path: [Int]
}

struct AXFrame: Equatable {
    let frameID: String
    let nodes: [CompactNode]
    let complete: Bool
    let truncated: Bool
}

private extension CompactNode {
    var row: Object {
        var result: Object = [
            "ref": ref, "parent": parentRef as Any? ?? null,
            "order": order, "role": role, "path": path
        ]
        result["title"] = title
        result["description"] = description
        result["value"] = value
        result["enabled"] = enabled
        result["focused"] = focused
        result["selected"] = selected
        if !actions.isEmpty { result["actions"] = actions }
        if let frame { result["frame"] = rectJSON(frame) }
        if protected { result["protected"] = true }
        return result
    }

    static func decode(_ row: Object) -> Self? {
        guard let ref = row["ref"] as? String, ref.first == "e",
              let id = UInt64(ref.dropFirst()), ref == "e\(id)",
              let role = row["role"] as? String,
              let order = row["order"] as? Int, order >= 0,
              let path = row["path"] as? [Int], !path.isEmpty,
              path.allSatisfy({ $0 >= 0 }),
              row["parent"] is NSNull || row["parent"] is String else {
            return nil
        }
        for key in ["title", "description", "value"] {
            if let value = row[key], !(value is String) { return nil }
        }
        for key in ["enabled", "focused", "selected", "protected"] {
            if let value = row[key], !(value is Bool) { return nil }
        }
        if let value = row["actions"], !(value is [String]) { return nil }

        var rect: CGRect?
        if let raw = row["frame"] {
            guard let box = raw as? Object,
                  let x = box["x"] as? NSNumber,
                  let y = box["y"] as? NSNumber,
                  let w = box["width"] as? NSNumber,
                  let h = box["height"] as? NSNumber,
                  [x, y, w, h].allSatisfy({ $0.doubleValue.isFinite }) else {
                return nil
            }
            rect = CGRect(x: x.doubleValue, y: y.doubleValue,
                          width: w.doubleValue, height: h.doubleValue)
        }
        return Self(
            ref: ref, id: id, parentRef: row["parent"] as? String,
            order: order, role: role, title: row["title"] as? String,
            description: row["description"] as? String,
            value: row["value"] as? String, enabled: row["enabled"] as? Bool,
            focused: row["focused"] as? Bool, selected: row["selected"] as? Bool,
            actions: row["actions"] as? [String] ?? [], frame: rect,
            protected: row["protected"] as? Bool ?? false, path: path
        )
    }
}

func removalRanges(_ sortedIDs: [UInt64]) -> [[UInt64]] {
    guard var low = sortedIDs.first else { return [] }
    var high = low
    var ranges = [[UInt64]]()
    for id in sortedIDs.dropFirst() {
        if id == high { continue }
        if high != UInt64.max && id == high + 1 {
            high = id
        } else {
            ranges.append([low, high])
            low = id
            high = id
        }
    }
    ranges.append([low, high])
    return ranges
}

func computeAXDiff(from base: AXFrame?, to current: AXFrame,
                   lineBudget: Int, fallbackReason: String? = nil) -> Object {
    func full(_ reason: String) -> Object {
        [
            "kind": "full", "base": null, "snapshot": current.frameID,
            "complete": current.complete && !current.truncated,
            "truncated": current.truncated, "fallback_reason": reason,
            "remove_ranges": [[UInt64]](), "upsert": current.nodes.map(\.row)
        ]
    }

    guard current.complete && !current.truncated else {
        return full("incomplete_capture")
    }
    if let fallbackReason { return full(fallbackReason) }
    guard let base else { return full("no_baseline") }
    guard base.complete && !base.truncated else { return full("incomplete_base") }

    var old = [UInt64: CompactNode]()
    for node in base.nodes {
        guard old.updateValue(node, forKey: node.id) == nil else {
            return full("invalid_base")
        }
    }
    var changed = [Object]()
    for node in current.nodes {
        if old.removeValue(forKey: node.id) != node {
            changed.append(node.row)
        }
    }

    let ranges = removalRanges(old.keys.sorted())
    guard changed.count + ranges.count <= max(0, lineBudget) else {
        return full("diff_line_budget")
    }
    let result: Object = [
        "kind": "diff", "base": base.frameID, "snapshot": current.frameID,
        "complete": true, "truncated": false,
        "remove_ranges": ranges, "upsert": changed
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: result),
          data.count <= 64 * 1024 else { return full("diff_byte_budget") }
    return result
}

func applyAXDiff(base: AXFrame, payload: Object) -> [CompactNode]? {
    guard let kind = payload["kind"] as? String,
          let ranges = payload["remove_ranges"] as? [[UInt64]],
          let rows = payload["upsert"] as? [Object],
          payload["snapshot"] is String else { return nil }

    var nodes = [UInt64: CompactNode]()
    switch kind {
    case "full":
        guard payload["base"] is NSNull, ranges.isEmpty else { return nil }
    case "diff":
        guard base.complete, !base.truncated,
              payload["base"] as? String == base.frameID,
              payload["complete"] as? Bool == true,
              payload["truncated"] as? Bool == false else { return nil }

        var last: UInt64?
        for range in ranges {
            guard range.count == 2, range[0] <= range[1],
                  last.map({ $0 < range[0] }) ?? true else { return nil }
            last = range[1]
        }
        var i = 0
        for node in base.nodes.sorted(by: { $0.id < $1.id }) {
            while i < ranges.count && ranges[i][1] < node.id { i += 1 }
            if i == ranges.count || node.id < ranges[i][0] {
                nodes[node.id] = node
            }
        }
    default:
        return nil
    }

    var seen = Set<UInt64>()
    for row in rows {
        guard let node = CompactNode.decode(row), seen.insert(node.id).inserted
        else { return nil }
        nodes[node.id] = node
    }
    // Original AX paths are unique and lexicographic order is tree preorder.
    return nodes.values.sorted { $0.path.lexicographicallyPrecedes($1.path) }
}
