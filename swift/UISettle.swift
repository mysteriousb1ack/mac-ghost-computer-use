import Foundation
import ApplicationServices

private final class SettleSignal {
    private let lock = NSLock()
    private var revision: UInt64 = 0

    func mark() {
        lock.lock()
        revision &+= 1
        lock.unlock()
    }

    func read() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }
}

private struct SettleFingerprint: Equatable {
    let focus: AXUIElement?
    let window: AXUIElement?
    let children: Int
    let busy: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        func equal(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (a?, b?): return CFEqual(a, b)
            default: return false
            }
        }
        return equal(lhs.focus, rhs.focus) && equal(lhs.window, rhs.window) &&
            lhs.children == rhs.children && lhs.busy == rhs.busy
    }
}

// Synchronous AX messaging can outlive a wait deadline. Keep it off the
// observer run loop, with at most one outstanding sample per observation.
private final class SettleSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacGhost.UISettle.sample")
    private let lock = NSLock()
    private let app: AXUIElement
    private let target: AXUIElement
    private var pending = false
    private var sequence: UInt64 = 0
    private var result: SettleFingerprint?

    init(app: AXUIElement, target: AXUIElement) {
        self.app = app
        self.target = target
    }

    func latest() -> (UInt64, SettleFingerprint?) {
        lock.lock()
        defer { lock.unlock() }
        return (sequence, result)
    }

    func sample() {
        lock.lock()
        if pending { lock.unlock(); return }
        pending = true
        lock.unlock()

        queue.async { [self] in
            var count = 0
            let status = AXUIElementGetAttributeValueCount(
                target, kAXChildrenAttribute as CFString, &count
            )
            let focus = element(app, kAXFocusedUIElementAttribute)
            let window = element(app, kAXFocusedWindowAttribute)
            let role = stringAttr(target, kAXRoleAttribute)
            var busy = attr(target, "AXElementBusy") as? Bool == true
            if let window {
                busy = busy || (attr(window, "AXElementBusy") as? Bool == true)
            }
            // Inspect immediate indicator roles only. No text or values are sampled.
            if !busy && status == .success && count > 0 {
                var page: CFArray?
                if AXUIElementCopyAttributeValues(target, kAXChildrenAttribute as CFString,
                                                  0, min(16, count), &page) == .success,
                   let children = page as? [AXUIElement] {
                    busy = children.contains { child in
                        let role = stringAttr(child, kAXRoleAttribute)
                        return role == "AXBusyIndicator" ||
                            (role == "AXProgressIndicator" &&
                             attr(child, "AXElementBusy") as? Bool == true)
                    }
                }
            }
            let usable = !role.isEmpty && (status == .success ||
                status == .attributeUnsupported || status == .noValue)
            let fingerprint = usable ? SettleFingerprint(
                focus: focus, window: window, children: count,
                busy: busy || role == "AXBusyIndicator"
            ) : nil

            lock.lock()
            result = fingerprint
            sequence &+= 1
            pending = false
            lock.unlock()
        }
    }
}

@MainActor
final class UISettler {
    private var observer: AXObserver?
    private var registrations = [(AXUIElement, CFString)]()
    private var signal = SettleSignal()
    private var sampler: SettleSampler?
    private var generation: UInt64 = 0

    func arm(pid: pid_t, target: AXUIElement) {
        invalidate()
        var actual: pid_t = 0
        guard AXUIElementGetPid(target, &actual) == .success, actual == pid else { return }
        let app = AXUIElementCreateApplication(pid)
        sampler = SettleSampler(app: app, target: target)
        sampler?.sample()

        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, context in
            if let context {
                Unmanaged<SettleSignal>.fromOpaque(context).takeUnretainedValue().mark()
            }
        }, &created)
        guard status == .success, let created else { return }
        let context = Unmanaged.passUnretained(signal).toOpaque()
        let names = [
            "AXFocusedUIElementChanged", "AXFocusedWindowChanged", "AXWindowCreated",
            "AXCreated", "AXUIElementDestroyed", "AXValueChanged",
            "AXSelectedChildrenChanged", "AXSelectedTextChanged", "AXLayoutChanged",
            "AXMoved", "AXResized"
        ]
        let sources = CFEqual(app, target) ? [app] : [app, target]
        for source in sources {
            for name in names {
                let key = name as CFString
                if AXObserverAddNotification(created, source, key, context) == .success {
                    registrations.append((source, key))
                }
            }
        }
        guard !registrations.isEmpty else { return }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created),
                           .commonModes)
    }

    func arm(pid: pid_t, target: AXTarget) {
        arm(pid: pid, target: target.roots.first ?? target.app)
    }

    func wait(minMs: Int = 1000, quietMs: Int = 200,
              maxMs: Int = 5000) async -> Object {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .milliseconds(max(0, maxMs)))
        let earliest = start.advanced(by: .milliseconds(max(0, minMs)))
        let quiet = Duration.milliseconds(max(0, quietMs))
        let token = generation
        let method = observer == nil ? "poll" : "observer"
        func receipt(_ status: String) -> Object {
            ["method": method, "settle": status]
        }
        guard let sampler else { return receipt("unverified") }
        defer { if token == generation { invalidate() } }

        var lastChange = start
        var revision = signal.read()
        var sequence = sampler.latest().0
        var previous: SettleFingerprint?
        var readings = 0
        var nextSample = start
        while true {
            guard generation == token, !Task.isCancelled else {
                return receipt("unverified")
            }
            let now = clock.now
            guard now < deadline else {
                return receipt(readings == 0 ? "unverified" : "timeout")
            }

            let observed = signal.read()
            if observed != revision {
                revision = observed
                lastChange = now
            }
            let (sampleID, fingerprint) = sampler.latest()
            if sampleID != sequence {
                if fingerprint != previous { lastChange = now }
                previous = fingerprint
                sequence = sampleID
                readings = fingerprint == nil ? 0 : readings + 1
            }
            let enoughSamples = readings >= (observer == nil ? 2 : 1)
            if enoughSamples, previous?.busy == false, now >= earliest,
               now >= lastChange.advanced(by: quiet) {
                return receipt("settled")
            }
            if now >= nextSample {
                sampler.sample()
                nextSample = now.advanced(by: .milliseconds(75))
            }
            let wake = min(deadline, now.advanced(by: .milliseconds(15)))
            do {
                try await clock.sleep(until: wake, tolerance: .zero)
            } catch {
                return receipt("unverified")
            }
        }
    }

    func invalidate() {
        generation &+= 1
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer), .commonModes)
            for (source, key) in registrations {
                AXObserverRemoveNotification(observer, source, key)
            }
        }
        registrations.removeAll()
        observer = nil
        sampler = nil
        signal = SettleSignal()
    }
}
