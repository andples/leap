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

    func scaled(_ s: CGFloat) -> Metrics {
        guard s < 1 else { return self }
        return Metrics(cellW: cellW * s, cellH: cellH * s, gap: gap * s, pad: pad * s, corner: corner * s,
                       icon: icon * s, smallIcon: smallIcon * s, thumbH: thumbH * s, inset: inset * s,
                       nameFont: max(nameFont * s, 9), nameH: max(nameH * s, 12),
                       badgeFont: max(badgeFont * s, 11), badgeH: max(badgeH * s, 17))
    }
}

private final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The on-screen switcher. Cells are plain CALayers, reused across shows; nothing animates.
@MainActor
final class SwitcherWindow {
    private let panel: Panel
    private let grid = GridView()
    private var cells: [CellLayer] = []
    private var mode: Mode = .icons
    private var metrics = Metrics.base(.icons)
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
        panel.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 20)
        panel.contentView = effect

        grid.frame = effect.bounds
        grid.autoresizingMask = [.width, .height]
        effect.addSubview(grid)
    }

    var contentView: NSView { panel.contentView! }

    func show(_ entries: [Entry], rows: Int, cols: Int, mode: Mode, selected: Int) {
        self.entries = entries
        self.mode = mode
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        var m = Metrics.base(mode)
        func size(_ m: Metrics) -> CGSize {
            CGSize(width: CGFloat(cols) * m.cellW + CGFloat(max(cols - 1, 0)) * m.gap + 2 * m.pad,
                   height: CGFloat(rows) * m.cellH + CGFloat(max(rows - 1, 0)) * m.gap + 2 * m.pad)
        }
        let raw = size(m)
        let fit = screen.visibleFrame
        m = m.scaled(min(fit.width * 0.94 / raw.width, fit.height * 0.94 / raw.height))
        metrics = m
        let s = size(m)
        let scale = screen.backingScaleFactor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
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
            cells[i].apply(e, mode: mode, m: m, scale: scale)
            cells[i].setSelected(i == selected)
            cells[i].opacity = 1
        }
        CATransaction.commit()

        let origin = CGPoint(x: (screen.frame.midX - s.width / 2).rounded(), y: (screen.frame.midY - s.height / 2).rounded())
        panel.setFrame(NSRect(origin: origin, size: s), display: true)
        panel.orderFrontRegardless()
    }

    func select(_ index: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, c) in cells.enumerated() where !c.isHidden { c.setSelected(i == index) }
        CATransaction.commit()
    }

    func dim(_ visible: (Int) -> Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in entries.indices { cells[i].opacity = visible(i) ? 1 : 0.25 }
        CATransaction.commit()
    }

    func updateThumb(_ index: Int, _ image: CGImage) {
        guard index < entries.count, mode == .previews else { return }
        let e = entries[index]
        entries[index] = Entry(name: e.name, icon: e.icon, thumb: image, label: e.label, row: e.row, col: e.col)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cells[index].apply(entries[index], mode: mode, m: metrics, scale: panel.screen?.backingScaleFactor ?? 2)
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
        borderColor = NSColor.controlAccentColor.cgColor
        thumb.cornerRadius = 6
        thumb.masksToBounds = true
        thumb.contentsGravity = .resize
        thumb.borderWidth = 0.5
        thumb.borderColor = NSColor(white: 1, alpha: 0.15).cgColor
        icon.contentsGravity = .resizeAspect
        icon.minificationFilter = .trilinear
        badge.backgroundColor = NSColor(red: 1.0, green: 0.85, blue: 0.30, alpha: 1).cgColor
        badge.borderColor = NSColor(red: 0.78, green: 0.62, blue: 0.0, alpha: 1).cgColor
        badge.borderWidth = 1
        badge.cornerRadius = 5
        badge.shadowOpacity = 0.35
        badge.shadowRadius = 2
        badge.shadowOffset = CGSize(width: 0, height: -1)
        badgeText.alignmentMode = .center
        badgeText.foregroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        nameText.alignmentMode = .center
        nameText.truncationMode = .end
        nameText.foregroundColor = NSColor(white: 1, alpha: 0.88).cgColor
        for l in [thumb, icon, nameText, badge] { addSublayer(l) }
        badge.addSublayer(badgeText)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ on: Bool) {
        backgroundColor = on ? NSColor(white: 1, alpha: 0.16).cgColor : nil
        borderWidth = on ? 2 : 0
    }

    func apply(_ e: Entry, mode: Mode, m: Metrics, scale: CGFloat) {
        for l in [self, thumb, icon, badge, badgeText, nameText] as [CALayer] { l.contentsScale = scale }
        cornerRadius = m.corner
        let w = bounds.width, h = bounds.height

        nameText.string = e.name
        nameText.font = NSFont.systemFont(ofSize: m.nameFont, weight: .medium)
        nameText.fontSize = m.nameFont
        nameText.frame = CGRect(x: 6, y: m.inset, width: w - 12, height: m.nameH)
        let contentBottom = m.inset + m.nameH + 4

        icon.contents = e.icon
        switch mode {
        case .icons:
            thumb.isHidden = true
            icon.frame = CGRect(x: (w - m.icon) / 2, y: contentBottom + (h - contentBottom - m.inset - m.icon) / 2,
                                width: m.icon, height: m.icon)
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
            } else {
                thumb.isHidden = true
                icon.frame = CGRect(x: area.midX - m.icon / 2, y: area.midY - m.icon / 2, width: m.icon, height: m.icon)
            }
        }

        badgeText.string = e.label
        badgeText.font = NSFont.monospacedSystemFont(ofSize: m.badgeFont, weight: .bold)
        badgeText.fontSize = m.badgeFont
        let bw = max(m.badgeH, CGFloat(e.label.count) * m.badgeFont * 0.62 + 10)
        badge.frame = CGRect(x: 6, y: h - 6 - m.badgeH, width: bw, height: m.badgeH)
        let lineH = (m.badgeFont * 1.22).rounded()
        badgeText.frame = CGRect(x: 0, y: (m.badgeH - lineH) / 2, width: bw, height: lineH)
    }
}
