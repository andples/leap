import AppKit
import LeapCore
import SwiftUI

enum Theme: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum BadgePosition: String, CaseIterable, Identifiable {
    case topLeft, topRight, onIcon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .onIcon: "On Icon"
        }
    }
}

/// User preferences, persisted to UserDefaults. Values are kept in memory so reading them while showing the switcher is free.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    static let defaultBadge = NSColor(red: 1.0, green: 0.85, blue: 0.30, alpha: 1)

    private let d = UserDefaults.standard

    @Published var mode: Mode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var theme: Theme { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var scale: Double { didSet { d.set(scale, forKey: "scale") } }
    @Published var opacity: Double { didSet { d.set(opacity, forKey: "opacity") } }
    @Published var cornerRadius: Double { didSet { d.set(cornerRadius, forKey: "cornerRadius") } }
    @Published var showNames: Bool { didSet { d.set(showNames, forKey: "showNames") } }
    @Published var badgePosition: BadgePosition { didSet { d.set(badgePosition.rawValue, forKey: "badgePosition") } }
    @Published var badgeScale: Double { didSet { d.set(badgeScale, forKey: "badgeScale") } }
    @Published var badgeColor: NSColor { didSet { d.set(badgeColor.hex, forKey: "badgeColor") } }
    @Published var useAccentHighlight: Bool { didSet { d.set(useAccentHighlight, forKey: "useAccentHighlight") } }
    @Published var highlightColor: NSColor { didSet { d.set(highlightColor.hex, forKey: "highlightColor") } }
    @Published var showDelay: Double { didSet { d.set(showDelay, forKey: "showDelay") } }
    @Published var ordering: Ordering { didSet { d.set(ordering.rawValue, forKey: "ordering") } }
    @Published var stableRest: Bool { didSet { d.set(stableRest, forKey: "stableRest") } }
    @Published var hideIdleFinder: Bool { didSet { d.set(hideIdleFinder, forKey: "hideIdleFinder") } }
    @Published var holdToPeek: Bool { didSet { d.set(holdToPeek, forKey: "holdToPeek") } }

    private init() {
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .icons
        theme = Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .dark
        scale = d.object(forKey: "scale") as? Double ?? 1
        opacity = d.object(forKey: "opacity") as? Double ?? 0
        cornerRadius = d.object(forKey: "cornerRadius") as? Double ?? 20
        showNames = d.object(forKey: "showNames") as? Bool ?? true
        badgePosition = BadgePosition(rawValue: d.string(forKey: "badgePosition") ?? "") ?? .topLeft
        badgeScale = d.object(forKey: "badgeScale") as? Double ?? 1
        badgeColor = NSColor(hex: d.string(forKey: "badgeColor")) ?? Self.defaultBadge
        useAccentHighlight = d.object(forKey: "useAccentHighlight") as? Bool ?? true
        highlightColor = NSColor(hex: d.string(forKey: "highlightColor")) ?? .controlAccentColor
        showDelay = d.object(forKey: "showDelay") as? Double ?? 0
        ordering = Ordering(rawValue: d.string(forKey: "ordering") ?? "") ?? .recent
        stableRest = d.object(forKey: "stableRest") as? Bool ?? true
        hideIdleFinder = d.object(forKey: "hideIdleFinder") as? Bool ?? true
        holdToPeek = d.object(forKey: "holdToPeek") as? Bool ?? true
    }

    var effectiveHighlight: NSColor { useAccentHighlight ? .controlAccentColor : highlightColor }

    func resetAppearance() {
        theme = .dark
        scale = 1
        opacity = 0
        cornerRadius = 20
        showNames = true
        badgePosition = .topLeft
        badgeScale = 1
        badgeColor = Self.defaultBadge
        useAccentHighlight = true
        highlightColor = .controlAccentColor
    }
}

extension NSColor {
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    convenience init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Dark or light text, whichever reads better on this color.
    var contrastingText: NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.55 ? NSColor(white: 0.08, alpha: 1) : .white
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var s = Settings.shared

    var body: some View {
        Form {
            Section("Switcher") {
                Picker("Style", selection: $s.mode) {
                    Text("Icons").tag(Mode.icons)
                    Text("Window Previews").tag(Mode.previews)
                }
                .pickerStyle(.segmented)
                Picker("Theme", selection: $s.theme) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Size", $s.scale, 0.6...1.6, format: percent)
                Toggle("Show app names", isOn: $s.showNames)
            }
            Section {
                Picker("Home row", selection: $s.ordering) {
                    Text("Most Recent").tag(Ordering.recent)
                    Text("Most Used").tag(Ordering.usage)
                }
                .pickerStyle(.segmented)
                Toggle("Keep other apps in alphabetical order", isOn: $s.stableRest)
                Toggle("Hide Finder when no windows are open", isOn: $s.hideIdleFinder)
            } header: {
                Text("Order")
            } footer: {
                Text("Apps off the home row keep the same keys every time. Tab goes left to right: home row, then top, then bottom.")
                    .foregroundStyle(.secondary)
            }
            Section("Background") {
                slider("Opacity", $s.opacity, 0...1, format: { $0 == 0 ? "Blur" : percent($0) })
                slider("Corner radius", $s.cornerRadius, 0...36, format: { "\(Int($0)) pt" })
            }
            Section("Hint keys") {
                Picker("Position", selection: $s.badgePosition) {
                    ForEach(BadgePosition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Size", $s.badgeScale, 0.7...2, format: percent)
                ColorPicker("Color", selection: color($s.badgeColor), supportsOpacity: false)
            }
            Section("Selection") {
                Toggle("Use system accent color", isOn: $s.useAccentHighlight)
                if !s.useAccentHighlight {
                    ColorPicker("Color", selection: color($s.highlightColor), supportsOpacity: false)
                }
            }
            Section {
                slider("Show delay", $s.showDelay, 0...300, step: 10, format: { $0 == 0 ? "Instant" : "\(Int($0)) ms" })
                Toggle("Hold a hint key to preview", isOn: $s.holdToPeek)
            } header: {
                Text("Behavior")
            } footer: {
                Text("A short delay hides the panel on a quick ⌘Tab flick. With hold to preview, tapping a hint key switches when you release it; holding it shows a preview, and Q while holding quits that app. Turn it off to switch the instant a key goes down.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Reset Appearance") { s.resetAppearance() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        step: Double? = nil, format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                if let step {
                    Slider(value: value, in: range, step: step)
                } else {
                    Slider(value: value, in: range)
                }
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    private func color(_ binding: Binding<NSColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: binding.wrappedValue) },
                set: { binding.wrappedValue = NSColor($0) })
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Leap Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Sit to the left so the live preview in the middle of the screen stays visible.
            if let screen = NSScreen.main?.visibleFrame {
                w.setFrameTopLeftPoint(NSPoint(x: screen.minX + 40, y: screen.maxY - 40))
            }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
