import AppKit
import ApplicationServices

struct SwitcherItem: Identifiable {
    let id: String
    let app: NSRunningApplication
    let element: AXUIElement? // nil for windowless apps
    let windowID: CGWindowID?
    let title: String
    let isMinimized: Bool
    let isFullscreen: Bool
    let spaceIndex: Int? // 1-based Mission Control index

    var appName: String { app.localizedName ?? "?" }
    var isHidden: Bool { app.isHidden }

    var displayTitle: String {
        guard windowID != nil else { return appName }
        return title.isEmpty || title == appName ? appName : "\(appName) - \(title)"
    }
}

/// Tracks windows of regular apps and their most-recently-used order.
final class WindowStore {
    /// Windows found via the remote-token brute force (other Spaces), keyed by pid.
    private var bruteForced: [pid_t: [AXUIElement]] = [:]
    private let bruteForceQueue = DispatchQueue(label: "cmdtab.bruteforce", qos: .utility)
    /// Window IDs, most recent first.
    private var mru: [CGWindowID] = []
    /// App pids, most recent first (for windowless apps).
    private var appMRU: [pid_t] = []
    private var observers: [pid_t: AXObserver] = [:]

    init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        seedMRUFromZOrder()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appActivated(app)
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Give the app a moment to create its windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self?.observe(app)
                self?.refreshBruteForce(pids: [app.processIdentifier])
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self?.bruteForced[pid] = nil
            self?.observers[pid] = nil
            self?.appMRU.removeAll { $0 == pid }
        }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshBruteForce()
        }

        for app in regularApps() { observe(app) }
        refreshBruteForce()
    }

    // MARK: - Snapshot

    func snapshot() -> [SwitcherItem] {
        let zOrder = existingWindowIDs()
        let alive = Set(zOrder)
        let spaceOrder = Private.orderedSpaceIDs()
        var items: [SwitcherItem] = []
        var seen = Set<CGWindowID>()
        var appsWithWindows = Set<pid_t>()

        for app in regularApps() {
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            let listed: [AXUIElement] = axApp.attribute(kAXWindowsAttribute) ?? []
            for el in listed + (bruteForced[pid] ?? []) {
                guard let wid = Private.windowID(of: el), alive.contains(wid), seen.insert(wid).inserted else { continue }
                let subrole: String? = el.attribute(kAXSubroleAttribute)
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
                let space = spaceOrder.count < 2 ? nil : Private.spaceIDs(for: wid).first.flatMap { spaceOrder.firstIndex(of: $0) }.map { $0 + 1 }
                items.append(SwitcherItem(
                    id: "w\(wid)",
                    app: app,
                    element: el,
                    windowID: wid,
                    title: el.attribute(kAXTitleAttribute) ?? "",
                    isMinimized: el.attribute(kAXMinimizedAttribute) ?? false,
                    isFullscreen: el.attribute("AXFullScreen") ?? false,
                    spaceIndex: space
                ))
                appsWithWindows.insert(pid)
            }
        }

        let rank = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let zRank = Dictionary(zOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        items.sort { a, b in
            // Minimized / hidden windows sink to the bottom, like AltTab.
            let aBack = a.isMinimized || a.isHidden, bBack = b.isMinimized || b.isHidden
            if aBack != bBack { return !aBack }
            let ra = rank[a.windowID!] ?? Int.max, rb = rank[b.windowID!] ?? Int.max
            if ra != rb { return ra < rb }
            return (zRank[a.windowID!] ?? Int.max) < (zRank[b.windowID!] ?? Int.max)
        }

        // Windowless apps at the end, in app MRU order.
        let appRank = Dictionary(appMRU.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let windowless = regularApps()
            .filter { !appsWithWindows.contains($0.processIdentifier) }
            .sorted { (appRank[$0.processIdentifier] ?? Int.max) < (appRank[$1.processIdentifier] ?? Int.max) }
        for app in windowless {
            items.append(SwitcherItem(id: "a\(app.processIdentifier)", app: app, element: nil, windowID: nil,
                                      title: "", isMinimized: false, isFullscreen: false, spaceIndex: nil))
        }
        return items
    }

    // MARK: - MRU tracking

    func markUsed(_ wid: CGWindowID) {
        mru.removeAll { $0 == wid }
        mru.insert(wid, at: 0)
    }

    private func appActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        appMRU.removeAll { $0 == pid }
        appMRU.insert(pid, at: 0)
        let axApp = AXUIElementCreateApplication(pid)
        if let focused: AXUIElement = axApp.attribute(kAXFocusedWindowAttribute), let wid = Private.windowID(of: focused) {
            markUsed(wid)
        }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let store = Unmanaged<WindowStore>.fromOpaque(refcon).takeUnretainedValue()
            if let wid = Private.windowID(of: element) { store.markUsed(wid) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let axApp = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, axApp, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func seedMRUFromZOrder() {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        mru = info.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    // MARK: - Helpers

    private func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated
        }
    }

    /// All normal-layer window IDs in front-to-back order. Doesn't need Screen Recording.
    private func existingWindowIDs() -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    func refreshBruteForce(pids: [pid_t]? = nil) {
        let targets = pids ?? regularApps().map(\.processIdentifier)
        bruteForceQueue.async { [weak self] in
            var found: [pid_t: [AXUIElement]] = [:]
            for pid in targets { found[pid] = Private.windowsViaRemoteToken(pid: pid) }
            DispatchQueue.main.async {
                for (pid, els) in found { self?.bruteForced[pid] = els }
            }
        }
    }
}
