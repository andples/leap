import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os

/// Private WindowServer call used by every third-party ⌘Tab replacement to turn off the native switcher.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
private func CGSSetSymbolicHotKeyEnabled(_ hotKey: UInt32, _ isEnabled: Bool) -> CGError

enum NativeSwitcher {
    private static let commandTab: UInt32 = 1
    private static let commandShiftTab: UInt32 = 2
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    static func setEnabled(_ enabled: Bool) {
        _ = CGSSetSymbolicHotKeyEnabled(commandTab, enabled)
        _ = CGSSetSymbolicHotKeyEnabled(commandShiftTab, enabled)
    }

    /// Restore the native switcher if Leap is quit, killed or crashes. (SIGKILL / Force Quit can't be caught:
    /// relaunch and quit Leap, or log out, to get ⌘Tab back.)
    static func restoreOnExit() {
        atexit { NativeSwitcher.setEnabled(true) }
        // Normal termination signals are handled on the main queue, outside signal context.
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NativeSwitcher.setEnabled(true)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        // Crashes: best effort, then let the default handler run.
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT] {
            signal(sig) { s in
                NativeSwitcher.setEnabled(true)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}

/// Global keyboard event tap on its own thread, so nothing happening on the main thread can delay a keystroke.
/// The callback decides swallow/pass from a tiny lock-protected state and hands the real work to the main thread.
final class KeyTap: @unchecked Sendable {
    struct Handlers {
        var open: @MainActor (_ reverse: Bool) -> Void
        var key: @MainActor (_ code: CGKeyCode, _ shift: Bool, _ isRepeat: Bool) -> Void
        var keyUp: @MainActor (_ code: CGKeyCode) -> Void
        var commandReleased: @MainActor () -> Void
        var cancel: @MainActor () -> Void
    }

    private struct State {
        var open = false
        /// Key codes whose key-up must be swallowed too.
        var swallowed = Set<Int64>()
    }

    private let handlers: Handlers
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var port: CFMachPort?

    init?(handlers: Handlers) {
        self.handlers = handlers
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: tapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.port = port
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Leap event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The switcher closed itself (Esc, a hint, a click): stop swallowing keys.
    func setClosed() {
        state.withLock { $0.open = false }
    }

    private enum Action {
        case pass
        case open(reverse: Bool)
        case key(CGKeyCode, shift: Bool, isRepeat: Bool)
        case closeAndPass
    }

    fileprivate func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            // We may have missed the ⌘ release: never stay stuck swallowing input.
            let wasOpen = state.withLock { s -> Bool in
                let o = s.open
                s = State()
                return o
            }
            if wasOpen { main { $0.cancel() } }
            return false

        case .flagsChanged:
            let released = state.withLock { s -> Bool in
                guard s.open, !event.flags.contains(.maskCommand) else { return false }
                s.open = false
                return true
            }
            if released { main { $0.commandReleased() } }
            return false

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let action = state.withLock { s -> Action in
                if !s.open {
                    guard code == Int64(kVK_Tab), flags.contains(.maskCommand),
                          !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return .pass }
                    s.open = true
                    s.swallowed.insert(code)
                    return .open(reverse: flags.contains(.maskShift))
                }
                // Open but ⌘ isn't held: the release was missed somehow. Close and let the key through.
                guard flags.contains(.maskCommand) else {
                    s.open = false
                    return .closeAndPass
                }
                s.swallowed.insert(code)
                return .key(CGKeyCode(code), shift: flags.contains(.maskShift),
                            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            }
            switch action {
            case .pass: return false
            case .open(let reverse):
                main { $0.open(reverse) }
                return true
            case .key(let c, let shift, let isRepeat):
                main { $0.key(c, shift, isRepeat) }
                return true
            case .closeAndPass:
                main { $0.cancel() }
                return false
            }

        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let swallow = state.withLock { $0.swallowed.remove(code) != nil }
            if swallow { main { $0.keyUp(CGKeyCode(code)) } }
            return swallow

        default:
            return false
        }
    }

    private func main(_ work: @escaping @MainActor (Handlers) -> Void) {
        let handlers = handlers
        DispatchQueue.main.async { MainActor.assumeIsolated { work(handlers) } }
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.process(type, event) ? nil : Unmanaged.passUnretained(event)
}
