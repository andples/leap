import AppKit
import Combine
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let apps = AppTracker()
    private lazy var switcher = Switcher(apps: apps)
    private var tap: KeyTap?
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var secureInputTimer: Timer?
    private var secureInput = false
    private let settingsWindow = SettingsWindow()
    private var settingsChanged: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let mode = args.count > i + 2 ? Mode(rawValue: args[i + 2]) ?? .icons : .icons
            _ = switcher
            // Give background checks (e.g. Finder's windows) a moment to land first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.switcher.snapshot(to: args[i + 1], mode: mode)
                exit(0)
            }
            return
        }
        #endif

        setupStatusItem()
        // objectWillChange fires before the new value lands, so react on the next runloop turn.
        settingsChanged = Settings.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildMenu()
                if self.settingsWindow.isVisible { self.switcher.livePreview() }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { KeyMap.invalidate() } }

        NativeSwitcher.restoreOnExit()
        startWhenTrusted()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NativeSwitcher.setEnabled(true)
    }

    // MARK: Permissions

    private func startWhenTrusted() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) {
            startTap()
            return
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                self?.permissionTimer?.invalidate()
                self?.startTap()
            }
        }
    }

    private func startTap() {
        tap = KeyTap(handlers: switcher.tapHandlers)
        guard let tap else {
            NSLog("Leap: failed to create event tap")
            return
        }
        switcher.onClose = { tap.setClosed() }
        NativeSwitcher.setEnabled(false)
        // Event taps get no keys while Secure Input is on (password fields, Secure Keyboard Entry),
        // so hand ⌘Tab back to macOS for that time.
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let secure = IsSecureEventInputEnabled()
                guard secure != self.secureInput else { return }
                self.secureInput = secure
                NativeSwitcher.setEnabled(secure)
            }
        }
        rebuildMenu()
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuBarIcon("square.grid.3x3.fill", description: "Leap")
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        if tap == nil {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }
        let icons = item("Icons", #selector(setIcons))
        icons.state = switcher.mode == .icons ? .on : .off
        let previews = item("Window Previews", #selector(setPreviews))
        previews.state = switcher.mode == .previews ? .on : .off
        menu.addItem(icons)
        menu.addItem(previews)
        if switcher.mode == .previews && !switcher.thumbs.hasPermission {
            menu.addItem(item("Grant Screen Recording (for previews)…", #selector(requestScreen)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Leap", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openSettings() { settingsWindow.show() }
    @objc private func setIcons() { switcher.mode = .icons }
    @objc private func setPreviews() {
        switcher.mode = .previews
        if !switcher.thumbs.hasPermission { requestScreen() }
    }
    @objc private func requestScreen() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("Leap: login item error \(error)") }
        rebuildMenu()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Menu bar icon drawn the way most apps do (Claude, for one): a ~16pt template glyph centred on a 24pt canvas,
/// shown in a variable-length status item so the system supplies the standard spacing.
func menuBarIcon(_ symbol: String, description: String) -> NSImage? {
    guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else { return nil }
    let canvas = NSSize(width: 24, height: 24), box: CGFloat = 20 // symbol images carry ~20% padding: this gives a ~16pt glyph
    let s = box / max(glyph.size.width, glyph.size.height, 1)
    let size = NSSize(width: glyph.size.width * s, height: glyph.size.height * s)
    let image = NSImage(size: canvas, flipped: false) { _ in
        glyph.draw(in: NSRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                              width: size.width, height: size.height))
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = description
    return image
}
