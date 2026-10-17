import AppKit
import ApplicationServices

/// Brings an app to the front. Runs off the main thread so a hung app can't stall the switcher.
enum Activator {
    private static let queue = DispatchQueue(label: "leap.activate", qos: .userInteractive)

    static func activate(_ app: NSRunningApplication) {
        queue.async {
            let pid = app.processIdentifier
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.3)
            if app.isHidden { app.unhide() }
            AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            app.activate(options: [.activateAllWindows])

            // Better than native: restore a minimized window, or reopen if there are no windows (like a Dock click).
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return }
            if windows.isEmpty {
                if let url = app.bundleURL {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: config)
                }
                return
            }
            let minimized = windows.map { w -> Bool in
                var m: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m)
                return (m as? Bool) ?? false
            }
            if minimized.allSatisfy({ $0 }), let first = windows.first {
                AXUIElementSetAttributeValue(first, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(first, kAXRaiseAction as CFString)
            }
        }
    }
}
