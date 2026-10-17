import AppKit
import QuartzCore

enum Mode: String {
    case icons, previews
}

struct Entry {
    let name: String
    let icon: CGImage?
    let thumb: CGImage?
    let label: String
    let row: Int
    let col: Int
}

struct Metrics {
    var cellW, cellH, gap, pad, corner: CGFloat
    var icon, smallIcon, thumbH, inset: CGFloat
    var nameFont, nameH, badgeFont, badgeH: CGFloat

    static func base(_ mode: Mode) -> Metrics {
        switch mode {
        case .icons:
            return Metrics(cellW: 112, cellH: 126, gap: 6, pad: 16, corner: 14,
                           icon: 76, smallIcon: 0, thumbH: 0, inset: 8,
                           nameFont: 11, nameH: 15, badgeFont: 14, badgeH: 22)
        case .previews:
            return Metrics(cellW: 280, cellH: 212, gap: 8, pad: 18, corner: 14,
                           icon: 88, smallIcon: 40, thumbH: 168, inset: 10,
                           nameFont: 12, nameH: 16, badgeFont: 16, badgeH: 26)
        }
    }

    /// Base metrics adjusted for the user's appearance settings.
    @MainActor static func styled(_ mode: Mode, _ s: Settings) -> Metrics {
        var m = base(mode).scaled(s.scale)
        m.badgeFont *= s.badgeScale
        m.badgeH *= s.badgeScale
        if !s.showNames { m.cellH -= m.nameH + 4 }
        return m
    }

    func scaled(_ s: CGFloat) -> Metrics {
        Metrics(cellW: cellW * s, cellH: cellH * s, gap: gap * s, pad: pad * s, corner: corner * s,
                icon: icon * s, smallIcon: smallIcon * s, thumbH: thumbH * s, inset: inset * s,
                nameFont: max(nameFont * s, 9), nameH: max(nameH * s, 12),
                badgeFont: max(badgeFont * s, 10), badgeH: max(badgeH * s, 16))
    }
}

/// Colors resolved once per show from settings and the effective appearance.
struct Style {
    let dark: Bool
    let showNames: Bool
    let badgePosition: BadgePosition
    let badgeColor: CGColor
    let badgeBorder: CGColor
    let badgeText: CGColor
    let highlight: CGColor
    let selectedFill: CGColor
    let nameColor: CGColor
}

private final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The on-screen switcher. Cells are plain CALayers, reused across shows; nothing animates.
@MainActor
final class SwitcherWindow {
    private let panel: Panel
    private let effect = NSVisualEffectView()
    private let tint = CALayer()
    private let grid = GridView()
    private var cells: [CellLayer] = []
    private var mode: Mode = .icons
    private var metrics = Metrics.base(.icons)
    private var style: Style?
    private var maskRadius: CGFloat = -1
    private var entries: [Entry] = []
    var onClick: ((Int) -> Void)? {
        get { grid.onClick }
        set { grid.onClick = newValue }
    }

    init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        panel.contentView = effect
        effect.layer?.addSublayer(tint)

        grid.frame = effect.bounds
        grid.autoresizingMask = [.width, .height]
        effect.addSubview(grid)
    }

    var contentView: NSView { panel.contentView! }

    func show(_ entries: [Entry], rows: Int, cols: Int, mode: Mode, selected: Int) {
        self.entries = entries
        self.mode = mode
        let settings = Settings.shared
        // While already showing (live preview, apps quitting), stay on the same screen and keep the same center.
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let screen = (panel.isVisible ? panel.screen : nil) ?? mouseScreen ?? NSScreen.main!
        applyAppearance(settings)

        var m = Metrics.styled(mode, settings)
        func size(_ m: Metrics) -> CGSize {
            CGSize(width: CGFloat(cols) * m.cellW + CGFloat(max(cols - 1, 0)) * m.gap + 2 * m.pad,
                   height: CGFloat(rows) * m.cellH + CGFloat(max(rows - 1, 0)) * m.gap + 2 * m.pad)
        }
        let raw = size(m)
        let fit = screen.visibleFrame
        let shrink = min(fit.width * 0.94 / raw.width, fit.height * 0.94 / raw.height)
        if shrink < 1 { m = m.scaled(shrink) }
        metrics = m
        let s = size(m)
        let scale = screen.backingScaleFactor
        let style = self.style!

        // Resize first and lay out in the same transaction, so the new layout never shows in the old frame.
        let origin = CGPoint(x: (screen.frame.midX - s.width / 2).rounded(), y: (screen.frame.midY - s.height / 2).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(NSRect(origin: origin, size: s), display: false)
        grid.layoutSubtreeIfNeeded()
        tint.frame = CGRect(origin: .zero, size: s)
        while cells.count < entries.count {
            let c = CellLayer()
            grid.layer!.addSublayer(c)
            cells.append(c)
        }
        for (i, c) in cells.enumerated() { c.isHidden = i >= entries.count }
        grid.cellFrames = entries.indices.map { i in
            let e = entries[i]
            return CGRect(x: m.pad + CGFloat(e.col) * (m.cellW + m.gap),
                          y: s.height - m.pad - CGFloat(e.row + 1) * m.cellH - CGFloat(e.row) * m.gap,
                          width: m.cellW, height: m.cellH)
        }
        for (i, e) in entries.enumerated() {
            cells[i].frame = grid.cellFrames[i]
            cells[i].apply(e, mode: mode, m: m, style: style, scale: scale)
            cells[i].setSelected(i == selected, style)
            cells[i].opacity = 1
        }
        CATransaction.commit()
        panel.displayIfNeeded()
        panel.orderFrontRegardless()
    }

    private func applyAppearance(_ s: Settings) {
        switch s.theme {
        case .system: panel.appearance = nil
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        case .light: panel.appearance = NSAppearance(named: .aqua)
        }
        let dark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effect.material = dark ? .hudWindow : .popover
        tint.backgroundColor = (dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.95, alpha: 1)).cgColor
        tint.opacity = Float(s.opacity)

        let radius = CGFloat(s.cornerRadius)
        if radius != maskRadius {
            maskRadius = radius
            effect.maskImage = radius > 0 ? Self.roundedMask(radius: radius) : nil
        }

        let badge = s.badgeColor
        style = Style(
            dark: dark,
            showNames: s.showNames,
            badgePosition: s.badgePosition,
            badgeColor: badge.cgColor,
            badgeBorder: (badge.blended(withFraction: 0.3, of: .black) ?? badge).cgColor,
            badgeText: badge.contrastingText.cgColor,
            highlight: s.effectiveHighlight.cgColor,
            selectedFill: (dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.10)).cgColor,
            nameColor: (dark ? NSColor(white: 1, alpha: 0.88) : NSColor(white: 0, alpha: 0.82)).cgColor
        )
    }

    func select(_ index: Int) {
        guard let style else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, c) in cells.enumerated() where !c.isHidden { c.setSelected(i == index, style) }
        CATransaction.commit()
    }

    func dim(_ visible: (Int) -> Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in entries.indices { cells[i].opacity = visible(i) ? 1 : 0.25 }
        CATransaction.commit()
    }

    func updateThumb(_ index: Int, _ image: CGImage) {
        guard index < entries.count, mode == .previews, let style else { return }
        let e = entries[index]
        entries[index] = Entry(name: e.name, icon: e.icon, thumb: image, label: e.label, row: e.row, col: e.col)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cells[index].apply(entries[index], mode: mode, m: metrics, style: style, scale: panel.screen?.backingScaleFactor ?? 2)
        CATransaction.commit()
    }

    func hide() { panel.orderOut(nil) }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}

private final class GridView: NSView {
    var cellFrames: [CGRect] = []
    var onClick: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = cellFrames.firstIndex(where: { $0.contains(p) }) { onClick?(i) }
    }
}

private final class CellLayer: CALayer {
    private let thumb = CALayer()
    private let icon = CALayer()
    private let badge = CALayer()
    private let badgeText = CATextLayer()
    private let nameText = CATextLayer()

    override init() {
        super.init()
        cornerRadius = 12
        thumb.cornerRadius = 6
        thumb.masksToBounds = true
        thumb.contentsGravity = .resize
        thumb.borderWidth = 0.5
        thumb.borderColor = NSColor(white: 0.5, alpha: 0.3).cgColor
        icon.contentsGravity = .resizeAspect
        icon.minificationFilter = .trilinear
        badge.borderWidth = 1
        badge.cornerRadius = 5
        badge.shadowOpacity = 0.35
        badge.shadowRadius = 2
        badge.shadowOffset = CGSize(width: 0, height: -1)
        badgeText.alignmentMode = .center
        nameText.alignmentMode = .center
        nameText.truncationMode = .end
        for l in [thumb, icon, nameText, badge] { addSublayer(l) }
        badge.addSublayer(badgeText)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ on: Bool, _ style: Style) {
        backgroundColor = on ? style.selectedFill : nil
        borderColor = style.highlight
        borderWidth = on ? 2 : 0
    }

    func apply(_ e: Entry, mode: Mode, m: Metrics, style: Style, scale: CGFloat) {
        for l in [self, thumb, icon, badge, badgeText, nameText] as [CALayer] { l.contentsScale = scale }
        cornerRadius = m.corner
        let w = bounds.width, h = bounds.height

        nameText.isHidden = !style.showNames
        nameText.string = e.name
        nameText.font = NSFont.systemFont(ofSize: m.nameFont, weight: .medium)
        nameText.fontSize = m.nameFont
        nameText.foregroundColor = style.nameColor
        nameText.frame = CGRect(x: 6, y: m.inset, width: w - 12, height: m.nameH)
        let contentBottom = style.showNames ? m.inset + m.nameH + 4 : m.inset

        // The rect the badge anchors to in "On Icon" mode.
        var focus: CGRect
        icon.contents = e.icon
        switch mode {
        case .icons:
            thumb.isHidden = true
            icon.frame = CGRect(x: (w - m.icon) / 2, y: contentBottom + (h - contentBottom - m.inset - m.icon) / 2,
                                width: m.icon, height: m.icon)
            focus = icon.frame
        case .previews:
            let area = CGRect(x: m.inset, y: contentBottom, width: w - 2 * m.inset, height: h - contentBottom - m.inset)
            if let t = e.thumb {
                thumb.isHidden = false
                thumb.contents = t
                let iw = CGFloat(t.width), ih = CGFloat(t.height)
                let s = min(area.width / iw, area.height / ih)
                let tw = iw * s, th = ih * s
                let tr = CGRect(x: area.midX - tw / 2, y: area.midY - th / 2, width: tw, height: th)
                thumb.frame = tr
                icon.frame = CGRect(x: max(tr.minX - 6, 2), y: max(tr.minY - 6, 2), width: m.smallIcon, height: m.smallIcon)
                focus = tr
            } else {
                thumb.isHidden = true
                icon.frame = CGRect(x: area.midX - m.icon / 2, y: area.midY - m.icon / 2, width: m.icon, height: m.icon)
                focus = icon.frame
            }
        }

        badge.backgroundColor = style.badgeColor
        badge.borderColor = style.badgeBorder
        badge.cornerRadius = m.badgeH * 0.23
        badgeText.foregroundColor = style.badgeText
        badgeText.string = e.label
        badgeText.font = NSFont.monospacedSystemFont(ofSize: m.badgeFont, weight: .bold)
        badgeText.fontSize = m.badgeFont
        let bw = max(m.badgeH, CGFloat(e.label.count) * m.badgeFont * 0.62 + m.badgeH * 0.45)
        let bh = m.badgeH
        switch style.badgePosition {
        case .topLeft:
            badge.frame = CGRect(x: 6, y: h - 6 - bh, width: bw, height: bh)
        case .topRight:
            badge.frame = CGRect(x: w - 6 - bw, y: h - 6 - bh, width: bw, height: bh)
        case .onIcon:
            badge.frame = CGRect(x: focus.midX - bw / 2, y: max(focus.minY - bh * 0.35, 2), width: bw, height: bh)
        }
        let lineH = (m.badgeFont * 1.22).rounded()
        badgeText.frame = CGRect(x: 0, y: (bh - lineH) / 2, width: bw, height: lineH)
    }
}
