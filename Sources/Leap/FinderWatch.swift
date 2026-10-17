import AppKit
import ApplicationServices

/// Tracks whether Finder has any real windows (Finder is always running, so it only earns a key when it's in use).
/// Checked in the background via Accessibility so ⌘Tab never waits on Finder.
@MainActor
final class FinderWatch {
    private(set) var hasWindows = true
    var onChange: (() -> Void)?
    private let queue = DispatchQueue(label: "leap.finder", qos: .userInitiated)
    private var checking = false

    static func isFinder(_ app: NSRunningApplication) -> Bool { app.bundleIdentifier == "com.apple.finder" }

    func refresh() {
        guard !checking,
              let finder = NSWorkspace.shared.runningApplications.first(where: Self.isFinder) else { return }
        checking = true
        let pid = finder.processIdentifier
        queue.async {
            let result = Self.countWindows(pid) > 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.checking = false
                    guard result != self.hasWindows else { return }
                    self.hasWindows = result
                    self.onChange?()
                }
            }
        }
    }

    /// Real windows only (role AXWindow, minimized included); the desktop shows up as a scroll area.
    private nonisolated static func countWindows(_ pid: pid_t) -> Int {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return 1 } // unknown: keep Finder visible
        return windows.filter { w in
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &role)
            return (role as? String) == kAXWindowRole
        }.count
    }
}
