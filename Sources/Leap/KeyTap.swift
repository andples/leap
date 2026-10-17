import AppKit
import CoreGraphics

/// Private WindowServer call used by every third-party ⌘Tab replacement to turn off the native switcher.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
private func CGSSetSymbolicHotKeyEnabled(_ hotKey: UInt32, _ isEnabled: Bool) -> CGError

enum NativeSwitcher {
    private static let commandTab: UInt32 = 1
    private static let commandShiftTab: UInt32 = 2

    static func setEnabled(_ enabled: Bool) {
        _ = CGSSetSymbolicHotKeyEnabled(commandTab, enabled)
        _ = CGSSetSymbolicHotKeyEnabled(commandShiftTab, enabled)
    }

    /// Restore the native switcher if Leap is killed or crashes.
    static func restoreOnExit() {
        atexit { NativeSwitcher.setEnabled(true) }
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(sig) { s in
                NativeSwitcher.setEnabled(true)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT] {
            signal(sig) { s in
                NativeSwitcher.setEnabled(true)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}

/// Global keyboard event tap. Everything not consumed by the switcher passes straight through.
@MainActor
final class KeyTap {
    private var port: CFMachPort?
    fileprivate let handler: (CGEventType, CGEvent) -> Bool

    init?(handler: @escaping (CGEventType, CGEvent) -> Bool) {
        self.handler = handler
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: tapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    fileprivate func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tap.reenable()
            return Unmanaged.passUnretained(event)
        }
        return tap.handler(type, event) ? nil : Unmanaged.passUnretained(event)
    }
}
