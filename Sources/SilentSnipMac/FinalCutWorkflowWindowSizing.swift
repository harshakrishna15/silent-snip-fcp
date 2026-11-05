import AppKit
import ApplicationServices
import Foundation

struct WorkflowSizingHost: Equatable {
    let pid: pid_t
    let launched: Date
}

@MainActor protocol WorkflowSizingDriver: AnyObject {
    var trusted: Bool { get }
    func host() -> WorkflowSizingHost?
    func discover(host: WorkflowSizingHost, view: UUID) -> AnyObject?
    func valid(_ target: AnyObject, host: WorkflowSizingHost, view: UUID) -> Bool
    func readSize(_ target: AnyObject) -> CGSize?
    func writable(_ target: AnyObject) -> Bool
    func writeSize(_ target: AnyObject, size: CGSize) -> Int32
    func observe(_ target: AnyObject, resized: @escaping () -> Void, destroyed: @escaping () -> Void) -> Int32
    func stopObserving()
}

/// Controls only the size of the requesting native Workflow window. This is
/// separate from analysis/edit authorization and never activates an app.
@MainActor public final class FinalCutWorkflowWindowSizing: NSObject {
    static let queryName = "local.silentsnip.workflow.window.v1"
    static let desired = CGSize(width: 615, height: 736)
    private let driver: WorkflowSizingDriver
    private let isBusy: () -> Bool
    private let now: () -> TimeInterval
    private let systemTransport: Bool
    private var timer: Timer?
    private var running = false
    private var lease: (view: UUID, nonce: UUID, until: TimeInterval)?
    private var retired: [(UUID, UUID)] = []
    private var pinnedHost: WorkflowSizingHost?
    private var target: AnyObject?
    private var epoch = 0
    private var nextDiscovery = -Double.infinity
    private var nextCorrection = -Double.infinity
    private var nextIdentityCheck = -Double.infinity
    private var needsCorrection = true
    private var failures = 0
    private var lastReadback: CGSize?
    private var savedDiagnostic: Data?
    private(set) var state = "inactive"
    private(set) var corrections = 0
    private(set) var axCode: Int32?

    public init(isBusy: @escaping () -> Bool = { false }) {
        self.driver = NativeWorkflowSizingDriver()
        self.isBusy = isBusy
        self.now = { ProcessInfo.processInfo.systemUptime }
        self.systemTransport = true
        super.init()
    }

    init(driver: WorkflowSizingDriver, isBusy: @escaping () -> Bool = { false }, now: @escaping () -> TimeInterval) {
        self.driver = driver; self.isBusy = isBusy; self.now = now; self.systemTransport = false
        super.init()
    }

    public func start() {
        guard !running else { return }
        running = true
        if systemTransport {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)),
                name: Notification.Name(Self.queryName), object: nil, suspensionBehavior: .deliverImmediately)
            timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    public func stop() {
        if systemTransport { DistributedNotificationCenter.default().removeObserver(self) }
        timer?.invalidate(); timer = nil; running = false
        releaseLease(state: "inactive")
    }

    @discardableResult public func attach(view: UUID, nonce: UUID) -> Bool {
        guard running else { return false }
        expire()
        guard !retired.contains(where: { $0.0 == view && $0.1 == nonce }) else { return false }
        if let lease, lease.view != view || lease.nonce != nonce { return false }
        if lease == nil {
            epoch += 1; failures = 0; corrections = 0; axCode = nil
            needsCorrection = true; state = "waiting"
        }
        lease = (view, nonce, now() + 3.5)
        tick()
        return true
    }

    @discardableResult public func renew(view: UUID, nonce: UUID) -> Bool {
        guard running else { return false }
        expire()
        guard let lease, lease.view == view, lease.nonce == nonce else { return false }
        self.lease = (view, nonce, now() + 3.5)
        tick()
        return true
    }

    @discardableResult public func detach(view: UUID, nonce: UUID) -> Bool {
        guard let lease, lease.view == view, lease.nonce == nonce else { return false }
        releaseLease(state: "inactive")
        return true
    }

    private func releaseLease(state: String) {
        if let lease {
            retired.append((lease.view, lease.nonce))
            if retired.count > 64 { retired.removeFirst(retired.count - 64) }
        }
        epoch += 1; driver.stopObserving(); target = nil; pinnedHost = nil; lease = nil
        needsCorrection = true; self.state = state
        saveDiagnostic()
    }

    private func expire() {
        if let lease, now() >= lease.until { releaseLease(state: "expired") }
    }

    func tick() {
        defer { saveDiagnostic() }
        guard running else { return }
        expire()
        guard let lease else { return }
        let operationEpoch = epoch
        guard driver.trusted else { releaseLease(state: "unavailable"); return }
        guard let host = driver.host() else { releaseLease(state: "unavailable"); return }
        if let pinnedHost, pinnedHost != host { releaseLease(state: "unavailable"); return }
        pinnedHost = host
        guard !isBusy() else { state = "paused"; needsCorrection = true; return }
        if target == nil {
            guard now() >= nextDiscovery else { return }
            nextDiscovery = now() + 0.6
            guard let found = driver.discover(host: host, view: lease.view) else { state = "waiting"; return }
            guard driver.writable(found) else { releaseLease(state: "unavailable"); return }
            let capturedEpoch = epoch
            let code = driver.observe(found, resized: { [weak self] in
                guard let self, self.epoch == capturedEpoch else { return }
                self.needsCorrection = true
            }, destroyed: { [weak self] in
                guard let self, self.epoch == capturedEpoch else { return }
                self.releaseLease(state: "unavailable")
            })
            guard epoch == operationEpoch, running, self.lease?.nonce == lease.nonce else { return }
            guard code == 0 else { axCode = code; releaseLease(state: "unavailable"); return }
            target = found; needsCorrection = true; nextIdentityCheck = -Double.infinity
        }
        guard let target else { return }
        guard needsCorrection || now() >= nextIdentityCheck else { return }
        nextIdentityCheck = now() + 0.6
        guard driver.valid(target, host: host, view: lease.view) else { releaseLease(state: "unavailable"); return }
        guard epoch == operationEpoch, running, self.lease?.nonce == lease.nonce else { return }
        guard let size = driver.readSize(target), size.width.isFinite, size.height.isFinite else {
            releaseLease(state: "unavailable"); return
        }
        guard epoch == operationEpoch, running, self.lease?.nonce == lease.nonce else { return }
        lastReadback = size
        if Self.matches(size) { needsCorrection = false; state = "fixed"; failures = 0; return }
        guard now() >= nextCorrection else { return }
        nextCorrection = now() + 0.12
        needsCorrection = false
        let code = driver.writeSize(target, size: Self.desired)
        guard epoch == operationEpoch, running, self.lease?.nonce == lease.nonce else { return }
        axCode = code
        let returned = driver.readSize(target)
        guard epoch == operationEpoch, running, self.lease?.nonce == lease.nonce else { return }
        if let returned, returned.width.isFinite, returned.height.isFinite { lastReadback = returned }
        if code == 0, let returned, Self.matches(returned) {
            corrections += 1; failures = 0; state = "fixed"
        } else {
            failures += 1; state = "waiting"; needsCorrection = true
            if failures >= 3 { releaseLease(state: "unavailable") }
        }
    }

    static func matches(_ size: CGSize) -> Bool {
        abs(size.width - desired.width) <= 0.5 && abs(size.height - desired.height) <= 0.5
    }

    private func saveDiagnostic() {
        guard systemTransport else { return }
        var value: [String: Any] = ["state": state, "corrections": corrections]
        value["width"] = lastReadback.map { $0.width as Any } ?? NSNull()
        value["height"] = lastReadback.map { $0.height as Any } ?? NSNull()
        value["axCode"] = axCode.map { $0 as Any } ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              data != savedDiagnostic else { return }
        let url = IntegrationReport.reportURL.deletingLastPathComponent().appendingPathComponent("Workflow-Window-Sizing.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            savedDiagnostic = data
        } catch { /* Optional diagnostics must not affect host operations. */ }
    }

    struct Query {
        let command: String
        let view: UUID
        let nonce: UUID
        static func decode(_ object: Any?, userInfo: [AnyHashable: Any]?) -> Self? {
            guard userInfo == nil, let object = object as? String, let data = object.data(using: .utf8), data.count <= 2048,
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(value.keys) == ["version", "command", "view", "nonce"],
                  let version = value["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
                  "cCsSiIlLqQ".contains(String(cString: version.objCType)), version.int64Value == 1, version.doubleValue == 1,
                  let command = value["command"] as? String, ["attach", "renew", "detach"].contains(command),
                  let rawView = value["view"] as? String, let view = UUID(uuidString: rawView), view.uuidString == rawView,
                  let rawNonce = value["nonce"] as? String, let nonce = UUID(uuidString: rawNonce), nonce.uuidString == rawNonce else { return nil }
            return Self(command: command, view: view, nonce: nonce)
        }
    }

    @objc private func receive(_ notification: Notification) {
        guard let query = Query.decode(notification.object, userInfo: notification.userInfo) else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.handle(query) }
        } else { handle(query) }
    }

    private func handle(_ query: Query) {
        let accepted: Bool
        switch query.command {
        case "attach": accepted = attach(view: query.view, nonce: query.nonce)
        case "renew": accepted = renew(view: query.view, nonce: query.nonce)
        default: accepted = detach(view: query.view, nonce: query.nonce)
        }
        var value: [String: Any] = ["version": 1, "protocol": 1, "command": query.command,
            "view": query.view.uuidString, "nonce": query.nonce.uuidString, "accepted": accepted,
            "state": accepted ? state : "unavailable", "width": 615, "height": 736, "corrections": corrections]
        if let axCode { value["axCode"] = axCode }
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 2048,
              let object = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("\(Self.queryName).\(query.view.uuidString)"), object: object, userInfo: nil, deliverImmediately: true)
    }

    deinit { timer?.invalidate() }
}

@MainActor private final class NativeWorkflowSizingDriver: WorkflowSizingDriver {
    private final class Target {
        let window: AXUIElement
        let marker: AXUIElement
        let analyze: AXUIElement
        let apply: AXUIElement
        init(_ window: AXUIElement, _ marker: AXUIElement, _ analyze: AXUIElement, _ apply: AXUIElement) {
            self.window = window; self.marker = marker; self.analyze = analyze; self.apply = apply
        }
    }
    private var observer: AXObserver?
    private var resized: (() -> Void)?
    private var destroyed: (() -> Void)?
    private var readDeadline: TimeInterval?
    var trusted: Bool { AXIsProcessTrusted() }

    func host() -> WorkflowSizingHost? {
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FinalCut").filter { !$0.isTerminated }
        guard hosts.count == 1, let app = hosts.first, app.processIdentifier > 0, let date = app.launchDate else { return nil }
        return WorkflowSizingHost(pid: app.processIdentifier, launched: date)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let remaining = readDeadline.map { $0 - ProcessInfo.processInfo.systemUptime } ?? 0.15
        guard remaining > 0 else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, Float(min(0.15, remaining)))
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private func element(_ source: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(source, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func text(_ source: AXUIElement, _ name: String) -> String? { attribute(source, name) as? String }
    private func pid(_ element: AXUIElement) -> pid_t? {
        var value: pid_t = 0
        return AXUIElementGetPid(element, &value) == .success ? value : nil
    }
    private func eligible(_ window: AXUIElement, host: WorkflowSizingHost) -> Bool {
        guard pid(window) == host.pid, text(window, kAXRoleAttribute) == kAXWindowRole,
              text(window, kAXTitleAttribute) == "Silent Snip",
              (attribute(window, kAXMinimizedAttribute) as? NSNumber)?.boolValue != true,
              (attribute(window, kAXModalAttribute) as? NSNumber)?.boolValue != true,
              text(window, kAXSubroleAttribute) != kAXDialogSubrole else { return false }
        guard let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] else { return false }
        return !children.contains { text($0, kAXRoleAttribute) == kAXSheetRole }
    }
    private func belongs(_ child: AXUIElement, to window: AXUIElement) -> Bool {
        if let owner = element(child, kAXWindowAttribute) { return CFEqual(owner, window) }
        var current = child
        for _ in 0..<24 {
            guard let parent = element(current, kAXParentAttribute), !CFEqual(parent, current) else { return false }
            if CFEqual(parent, window) { return true }
            current = parent
        }
        return false
    }

    func discover(host: WorkflowSizingHost, view: UUID) -> AnyObject? {
        readDeadline = ProcessInfo.processInfo.systemUptime + 0.4
        defer { readDeadline = nil }
        let root = AXUIElementCreateApplication(host.pid)
        guard let raw = attribute(root, kAXWindowsAttribute) as? [AXUIElement], raw.count <= 32 else { return nil }
        var seen: [AXUIElement] = []
        var matches: [Target] = []
        for window in raw where !seen.contains(where: { CFEqual($0, window) }) {
            seen.append(window)
            guard eligible(window, host: host) else { continue }
            var pending = [(window, 0)], count = 0
            var marker: AXUIElement?, analyze: AXUIElement?, apply: AXUIElement?
            while let (node, depth) = pending.popLast(), count < 3000 {
                if let readDeadline, ProcessInfo.processInfo.systemUptime >= readDeadline { return nil }
                count += 1
                let id = text(node, kAXIdentifierAttribute) ?? ""
                if text(node, kAXRoleAttribute) == kAXButtonRole {
                    if id == "silentsnip.workflow.review.\(view.uuidString)" { marker = node }
                    if id == "silentsnip.workflow.analyze" || id.hasPrefix("silentsnip.workflow.analyze.requested.") { analyze = node }
                    if id == "silentsnip.workflow.apply" || id.hasPrefix("silentsnip.workflow.apply.requested.") { apply = node }
                }
                if marker != nil && analyze != nil && apply != nil { break }
                if depth < 24, let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                    pending.append(contentsOf: children.prefix(3000 - count).map { ($0, depth + 1) })
                }
            }
            if let marker, let analyze, let apply { matches.append(Target(window, marker, analyze, apply)) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func valid(_ target: AnyObject, host: WorkflowSizingHost, view: UUID) -> Bool {
        readDeadline = ProcessInfo.processInfo.systemUptime + 0.4
        defer { readDeadline = nil }
        guard let target = target as? Target, eligible(target.window, host: host),
              text(target.marker, kAXIdentifierAttribute) == "silentsnip.workflow.review.\(view.uuidString)" else { return false }
        let a = text(target.analyze, kAXIdentifierAttribute) ?? "", b = text(target.apply, kAXIdentifierAttribute) ?? ""
        return (a == "silentsnip.workflow.analyze" || a.hasPrefix("silentsnip.workflow.analyze.requested."))
            && (b == "silentsnip.workflow.apply" || b.hasPrefix("silentsnip.workflow.apply.requested."))
            && belongs(target.marker, to: target.window) && belongs(target.analyze, to: target.window) && belongs(target.apply, to: target.window)
    }
    func readSize(_ target: AnyObject) -> CGSize? {
        guard let target = target as? Target, let raw = attribute(target.window, kAXSizeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgSize, &size) ? size : nil
    }
    func writable(_ target: AnyObject) -> Bool {
        guard let target = target as? Target else { return false }
        var value: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(target.window, kAXSizeAttribute as CFString, &value) == .success && value.boolValue
    }
    func writeSize(_ target: AnyObject, size: CGSize) -> Int32 {
        guard let target = target as? Target else { return AXError.invalidUIElement.rawValue }
        var value = size
        guard let size = AXValueCreate(.cgSize, &value) else { return AXError.failure.rawValue }
        return AXUIElementSetAttributeValue(target.window, kAXSizeAttribute as CFString, size).rawValue
    }
    func observe(_ target: AnyObject, resized: @escaping () -> Void, destroyed: @escaping () -> Void) -> Int32 {
        stopObserving()
        guard let target = target as? Target, let process = pid(target.window) else { return AXError.invalidUIElement.rawValue }
        self.resized = resized; self.destroyed = destroyed
        var result: AXObserver?
        let callback: AXObserverCallback = { _, _, name, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let owner = Unmanaged<NativeWorkflowSizingDriver>.fromOpaque(context).takeUnretainedValue()
                if name as String == kAXUIElementDestroyedNotification { owner.destroyed?() }
                else { owner.resized?() }
            }
        }
        let created = AXObserverCreate(process, callback, &result)
        guard created == .success, let result else { return created.rawValue }
        observer = result
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXResizedNotification, kAXUIElementDestroyedNotification] {
            let code = AXObserverAddNotification(result, target.window, name as CFString, context)
            if code != .success { stopObserving(); return code.rawValue }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
        return 0
    }
    func stopObserving() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; resized = nil; destroyed = nil
    }
    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
    }
}
