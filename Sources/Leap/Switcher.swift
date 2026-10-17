import AppKit
import Carbon.HIToolbox
import LeapCore

/// The ⌘Tab state machine. `handle` runs inside the event tap, so it must stay cheap.
@MainActor
final class Switcher {
    private let apps: AppTracker
    private let icons = IconCache()
    let thumbs = ThumbnailCache()
    private let window = SwitcherWindow()

    private var items: [NSRunningApplication] = []
    private var plan = GridPlan.empty
    private var selected = 0
    /// Item indices in Tab order.
    private var cycle: [Int] = []
    private var typed: [KeyPos] = []
    private var swallowed = Set<Int64>()
    private(set) var isVisible = false
    private var pendingPresent: DispatchWorkItem?
    private var previewing = false
    private var previewHide: DispatchWorkItem?

    var mode: Mode {
        get { Settings.shared.mode }
        set { Settings.shared.mode = newValue }
    }

    init(apps: AppTracker) {
        self.apps = apps
        icons.warm(apps.mru)
        window.onClick = { [weak self] i in
            guard let self else { return }
            if self.previewing { self.endPreview(); return }
            self.selected = i
            self.commit()
        }
        apps.onLaunch = { [weak self] app in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = self?.icons.image(for: app) }
        }
        apps.onDeactivate = { [weak self] app in
            // Keep previews warm: grab the window of the app we're leaving while it is still on screen.
            guard let self, self.mode == .previews, !self.isVisible else { return }
            self.thumbs.refresh([app.processIdentifier]) { _ in }
        }
    }

    // MARK: Event handling

    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .flagsChanged:
            if isVisible && !event.flags.contains(.maskCommand) { commit() }
            return false
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if !isVisible {
                guard code == kVK_Tab, flags.contains(.maskCommand),
                      !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return false }
                swallowed.insert(code)
                endPreview()
                show(reverse: flags.contains(.maskShift))
                return true
            }
            swallowed.insert(code)
            key(CGKeyCode(code), shift: flags.contains(.maskShift))
            return true
        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            return swallowed.remove(code) != nil
        default:
            return false
        }
    }

    private func key(_ code: CGKeyCode, shift: Bool) {
        switch Int(code) {
        case kVK_Tab: move(shift ? -1 : 1)
        case kVK_Escape: hide()
        case kVK_Return, kVK_ANSI_KeypadEnter: commit()
        case kVK_Space:
            mode = mode == .icons ? .previews : .icons
            pendingPresent?.cancel()
            pendingPresent = nil
            present()
        case kVK_LeftArrow: moveSpatial(dx: -1, dy: 0)
        case kVK_RightArrow: moveSpatial(dx: 1, dy: 0)
        case kVK_UpArrow: moveSpatial(dx: 0, dy: -1)
        case kVK_DownArrow: moveSpatial(dx: 0, dy: 1)
        case kVK_Delete:
            if !typed.isEmpty { typed.removeLast(); refreshDim() }
        default:
            if let pos = KeyMap.positions[code] {
                hint(pos)
            } else if KeyMap.character(code)?.lowercased() == "q" {
                quitSelected()
            }
        }
    }

    private func hint(_ pos: KeyPos) {
        typed.append(pos)
        var result = HintGrid.match(typed, in: plan)
        if result == .none, typed.count > 1 {
            typed = [pos]
            result = HintGrid.match(typed, in: plan)
        }
        switch result {
        case .exact(let i):
            selected = i
            commit()
        case .prefix:
            refreshDim()
        case .none:
            typed = []
            refreshDim()
        }
    }

    // MARK: Showing

    /// Lays out the running apps: picks the grid, who gets the home row, and the Tab order.
    @discardableResult
    private func prepare() -> Bool {
        let mru = Array(apps.current().prefix(HintGrid.maxItems))
        guard !mru.isEmpty else { return false }
        plan = HintGrid.plan(count: mru.count)
        let s = Settings.shared
        let info = mru.map { AppInfo(id: AppTracker.id($0), name: $0.localizedName ?? "", uses: apps.uses($0)) }
        let arrangement = Arranger.arrange(info, ordering: s.ordering, primary: plan.homeCount, stableRest: s.stableRest)
        items = arrangement.slots.map { mru[$0] }
        cycle = arrangement.cycle
        selected = cycle[0]
        return true
    }

    private func show(reverse: Bool) {
        guard prepare() else { return }
        if reverse { selected = cycle[max(cycle.count - 2, 0)] }
        typed = []
        isVisible = true
        let delay = Settings.shared.showDelay
        if delay > 0 {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isVisible else { return }
                self.pendingPresent = nil
                self.present()
            }
            pendingPresent = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000, execute: work)
        } else {
            present()
        }
    }

    private func present() {
        let previews = mode == .previews
        let entries = items.indices.map { i -> Entry in
            let app = items[i]
            let slot = plan.slots[i]
            return Entry(name: app.localizedName ?? "", icon: icons.image(for: app),
                         thumb: previews ? thumbs.images[app.processIdentifier] : nil,
                         label: KeyMap.label(slot.keys), row: slot.row, col: slot.col)
        }
        window.show(entries, rows: plan.rows, cols: plan.cols, mode: mode, selected: selected)
        if previews {
            let shown = items
            thumbs.refresh(shown.map(\.processIdentifier)) { [weak self] pid in
                guard let self, self.isVisible, self.items == shown, self.mode == .previews,
                      let i = shown.firstIndex(where: { $0.processIdentifier == pid }),
                      let img = self.thumbs.images[pid] else { return }
                self.window.updateThumb(i, img)
            }
        }
    }

    private func refreshDim() {
        let t = typed
        window.dim { i in t.isEmpty || self.plan.slots[i].keys.starts(with: t) }
    }

    private func move(_ delta: Int) {
        guard !cycle.isEmpty else { return }
        let pos = cycle.firstIndex(of: selected) ?? 0
        selected = cycle[(pos + delta + cycle.count) % cycle.count]
        if pendingPresent == nil { window.select(selected) }
    }

    private func moveSpatial(dx: Int, dy: Int) {
        guard selected < plan.slots.count else { return }
        let s = plan.slots[selected]
        var r = s.row + dy, c = s.col + dx
        while r >= 0, r < plan.rows, c >= 0, c < plan.cols {
            if let i = plan.index(row: r, col: c) {
                selected = i
                window.select(i)
                return
            }
            r += dy; c += dx
        }
    }

    private func quitSelected() {
        guard selected < items.count else { return }
        items[selected].terminate()
        hide()
    }

    // MARK: Finishing

    private func commit() {
        guard isVisible else { return }
        let target = selected < items.count ? items[selected] : nil
        hide()
        if let target { Activator.activate(target) }
    }

    private func hide() {
        isVisible = false
        pendingPresent?.cancel()
        pendingPresent = nil
        typed = []
        window.hide()
        icons.prune(keeping: apps.mru)
        thumbs.prune(keeping: apps.mru)
    }

    // MARK: Live preview

    /// Shows the switcher without taking over the keyboard, so appearance changes can be seen as they're made.
    func livePreview() {
        guard !isVisible else { return }
        guard prepare() else { return }
        previewing = true
        present()
        previewHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endPreview() }
        previewHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func endPreview() {
        guard previewing else { return }
        previewing = false
        previewHide?.cancel()
        previewHide = nil
        window.hide()
    }

    // MARK: Debug

    /// Renders the switcher for the current apps into a PNG (no permissions needed).
    func snapshot(to path: String, mode m: Mode) {
        Settings.shared.mode = m
        prepare()
        isVisible = true
        present()
        let view = window.contentView
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = NSImage(size: view.bounds.size)
        out.lockFocus()
        NSColor(white: 0.16, alpha: 1).setFill()
        view.bounds.fill()
        rep.draw(in: view.bounds)
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        hide()
    }
}
