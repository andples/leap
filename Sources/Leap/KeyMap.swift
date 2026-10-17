import Carbon.HIToolbox
import CoreGraphics
import LeapCore

/// Maps the physical 4x4 hint block to key codes, and key codes to labels in the active layout.
@MainActor
enum KeyMap {
    /// ANSI key codes for 7 8 9 0 / U I O P / J K L ; / M , . /
    static let codes: [[CGKeyCode]] = [
        [CGKeyCode(kVK_ANSI_7), CGKeyCode(kVK_ANSI_8), CGKeyCode(kVK_ANSI_9), CGKeyCode(kVK_ANSI_0)],
        [CGKeyCode(kVK_ANSI_U), CGKeyCode(kVK_ANSI_I), CGKeyCode(kVK_ANSI_O), CGKeyCode(kVK_ANSI_P)],
        [CGKeyCode(kVK_ANSI_J), CGKeyCode(kVK_ANSI_K), CGKeyCode(kVK_ANSI_L), CGKeyCode(kVK_ANSI_Semicolon)],
        [CGKeyCode(kVK_ANSI_M), CGKeyCode(kVK_ANSI_Comma), CGKeyCode(kVK_ANSI_Period), CGKeyCode(kVK_ANSI_Slash)],
    ]

    static let positions: [CGKeyCode: KeyPos] = {
        var map: [CGKeyCode: KeyPos] = [:]
        for (r, row) in codes.enumerated() {
            for (c, code) in row.enumerated() { map[code] = KeyPos(row: r, col: c) }
        }
        return map
    }()

    private static var labels: [CGKeyCode: String] = [:]

    /// Call when the keyboard layout changes.
    static func invalidate() { labels.removeAll() }

    static func label(_ keys: [KeyPos]) -> String {
        keys.map { label(code: codes[$0.row][$0.col]) }.joined()
    }

    static func label(code: CGKeyCode) -> String {
        if let cached = labels[code] { return cached }
        let s = (character(code) ?? "?").uppercased()
        labels[code] = s
        return s
    }

    /// The character the key produces in the current layout, ignoring modifiers.
    static func character(_ code: CGKeyCode) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeys,
                                  chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
