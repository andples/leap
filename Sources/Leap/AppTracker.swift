import AppKit

/// Keeps regular apps in most-recently-used order.
@MainActor
final class AppTracker {
    private(set) var mru: [NSRunningApplication] = []
    var onLaunch: ((NSRunningApplication) -> Void)?
    var onDeactivate: ((NSRunningApplication) -> Void)?

    init() {
        seed()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.bringToFront(app) }
        }
        nc.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.onDeactivate?(app) }
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self, Self.isSwitchable(app), !self.mru.contains(app) else { return }
                self.mru.insert(app, at: min(1, self.mru.count))
                self.onLaunch?(app)
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.mru.removeAll { $0 == app } }
        }
    }

    static func isSwitchable(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != getpid() && !app.isTerminated
    }

    /// Switch order: previous app first, current app last.
    func switchOrder() -> [NSRunningApplication] {
        mru.removeAll { $0.isTerminated || $0.activationPolicy != .regular }
        for app in NSWorkspace.shared.runningApplications where Self.isSwitchable(app) && !mru.contains(app) {
            mru.append(app)
        }
        if let front = NSWorkspace.shared.frontmostApplication, Self.isSwitchable(front) { bringToFront(front) }
        guard mru.count > 1 else { return mru }
        return Array(mru.dropFirst()) + [mru[0]]
    }

    private func bringToFront(_ app: NSRunningApplication) {
        guard Self.isSwitchable(app) else { return }
        if let i = mru.firstIndex(of: app) {
            if i == 0 { return }
            mru.remove(at: i)
        }
        mru.insert(app, at: 0)
    }

    /// Initial order from window z-order, which approximates recency.
    private func seed() {
        let apps = NSWorkspace.shared.runningApplications.filter(Self.isSwitchable)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var rank: [pid_t: Int] = [:]
        for w in windows where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t, rank[pid] == nil { rank[pid] = rank.count }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        mru = apps.enumerated().sorted { a, b in
            func key(_ e: (offset: Int, element: NSRunningApplication)) -> Int {
                let pid = e.element.processIdentifier
                if pid == front { return -1 }
                return rank[pid] ?? (10_000 + e.offset)
            }
            return key(a) < key(b)
        }.map(\.element)
    }
}
