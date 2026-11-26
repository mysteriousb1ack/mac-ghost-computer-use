import AppKit
import ApplicationServices

enum WindowFocus<ID: Equatable>: Equatable {
    case focused(ID), noWindow, unknown
}

struct Frontmost<ID: Equatable> {
    let pid: pid_t?
    let bundle: String?
    let window: WindowFocus<ID>
    var details: Object = [:]

    var json: Object {
        var active = details
        switch window {
        case .focused: active["status"] = "focused"
        case .noWindow: active["status"] = "no_window"
        case .unknown: active["status"] = "unknown"
        }
        return ["pid": pid as Any? ?? null, "bundleId": bundle as Any? ?? null, "activeWindow": active]
    }
    func comparison(to other: Self) -> String {
        guard let pid, let otherPID = other.pid else { return "unverified" }
        if pid != otherPID || (bundle != nil && other.bundle != nil && bundle != other.bundle) { return "changed" }
        if window == .unknown || other.window == .unknown { return "unverified" }
        return window == other.window ? "preserved" : "changed"
    }
}

struct WindowToken: Equatable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
}

@MainActor
func readFocus(_ policy: Guardrails) -> Frontmost<WindowToken> {
    guard let app = NSWorkspace.shared.frontmostApplication else { return Frontmost(pid: nil, bundle: nil, window: .unknown) }
    let pid = app.processIdentifier, bundle = app.bundleIdentifier
    guard !policy.sensitive(app.localizedName ?? "", bundle ?? ""), AXIsProcessTrusted() else {
        return Frontmost(pid: pid, bundle: bundle, window: .unknown)
    }
    let root = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(root, 0.15)
    var raw: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &raw)
    if status == .noValue { return Frontmost(pid: pid, bundle: bundle, window: .noWindow) }
    guard status == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
        return Frontmost(pid: pid, bundle: bundle, window: .unknown)
    }
    let item = raw as! AXUIElement
    AXUIElementSetMessagingTimeout(item, 0.15)
    // AX identity distinguishes same-title windows. Do not copy foreground titles into the audit.
    let bounds = axRect(attr(item, kAXPositionAttribute), attr(item, kAXSizeAttribute))
    let matches = bounds.flatMap { rect in
        try? windows(true).filter { $0.pid == pid && $0.layer == 0 && $0.bounds == rect }
    }
    let windowID = matches?.count == 1 ? matches?.first?.id : nil
    return Frontmost(pid: pid, bundle: bundle, window: .focused(WindowToken(element: item)),
                     details: ["frame": bounds.map(rectJSON) as Any? ?? null, "windowId": windowID as Any? ?? null])
}

enum RestoreAttempt: String {
    case skipped, requested, rejected
}

@MainActor
func auditedWrite<ID: Equatable>(target: pid_t, restoreRequested: Bool,
    sample: () -> Frontmost<ID>, settle: () async -> Void,
    verifyRestoration: (() async -> Void)? = nil,
    restore: (Frontmost<ID>, Frontmost<ID>) -> RestoreAttempt, write: () async throws -> Object) async throws -> Object {
    let before = sample()
    let operation: Result<Object, Error>
    do { operation = .success(try await write()) }
    catch { operation = .failure(error) }
    let immediate = sample()
    await settle()
    let after = sample()
    let observations = [before.comparison(to: immediate), before.comparison(to: after)]
    let status = observations.contains("changed") ? "changed" : observations.contains("unverified") ? "unverified" : "preserved"
    var audit: Object = ["beforeFrontmost": before.json, "afterFrontmost": after.json,
                         "focusPreserved": status == "preserved", "status": status]
    if status != "preserved" {
        audit["warning"] = status == "changed" ? "Foreground app or focused window changed during observation." : "Foreground focus could not be verified."
        audit["immediateFrontmost"] = immediate.json
    }
    if restoreRequested && status == "changed" {
        let current = sample()
        if before.comparison(to: current) == "preserved" {
            audit["restoration"] = "already_restored"
        } else if current.pid == target, after.comparison(to: current) == "preserved",
                  before.comparison(to: current) == "changed" {
            let attempt = restore(before, current)
            audit["restoreRequest"] = attempt.rawValue
            if attempt == .skipped {
                audit["restoration"] = "skipped_or_unavailable"
            } else {
                if let verifyRestoration { await verifyRestoration() }
                else { await settle() }
                let final = sample()
                audit["afterRestoreFrontmost"] = final.json
                audit["restoration"] = before.comparison(to: final) == "preserved" ? "verified" : "unverified"
            }
        } else {
            audit["restoration"] = "skipped_or_unavailable"
        }
    }
    switch operation {
    case .success(var response):
        response["focusAudit"] = audit
        return response
    case .failure(let error):
        var failure = error as? Failure ?? Failure("NATIVE_ERROR", "Native write failed.")
        failure.focusAudit = audit
        throw failure
    }
}

@MainActor
func guardWrite(_ pid: pid_t, _ policy: Guardrails, restoreRequested: Bool,
    settle: (() async -> Void)? = nil,
    verifyRestoration: (() async -> Void)? = nil,
    write: () async throws -> Object) async throws -> Object {
    let defaultWait: () async -> Void = { try? await Task.sleep(nanoseconds: 150_000_000) }
    return try await auditedWrite(target: pid, restoreRequested: restoreRequested,
        sample: { readFocus(policy) }, settle: settle ?? defaultWait,
        verifyRestoration: verifyRestoration ?? defaultWait,
        restore: { previous, observed in
            guard let original = previous.pid, let app = NSRunningApplication(processIdentifier: original),
                  app.bundleIdentifier == previous.bundle, (try? processWindows(original, policy)) != nil,
                  let target = try? AXTarget(original, policy), case .focused(let token) = previous.window,
                  target.roots.contains(where: { CFEqual($0, token.element) }),
                  observed.comparison(to: readFocus(policy)) == "preserved" else { return .skipped }
            if original != pid && !app.activate(options: []) { return .rejected }
            return AXUIElementPerformAction(token.element, kAXRaiseAction as CFString) == .success ? .requested : .rejected
        }, write: write)
}

@MainActor
func guardWrite(_ pid: pid_t, _ policy: Guardrails, _ opt: Options, write: () async throws -> Object) async throws -> Object {
    try await guardWrite(pid, policy, restoreRequested: opt.values["--restore-focus"] == "true", write: write)
}
