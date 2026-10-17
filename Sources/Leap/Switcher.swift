import AppKit
import Carbon.HIToolbox
import LeapCore

/// The ⌘Tab state machine. Events arrive on the main thread from `KeyTap`, which has already decided what to swallow.
@MainActor
final class Switcher {
    private let apps: AppTracker
    private let icons = IconCache()
    let thumbs = ThumbnailCache()
    private let finder = FinderWatch()
    private let window = SwitcherWindow()

    private var items: [NSRunningApplication] = []
    private var plan = GridPlan.empty
    private var selected = 0
    /// Apps asked to quit from the switcher; shown dimmed until they're gone.
    private var quitting = Set<pid_t>()
    private var typed: [KeyPos] = []
    private(set) var isVisible = false
    private var pendingPresent: DispatchWorkItem?
    private var previewing = false
    private var previewHide: DispatchWorkItem?
    /// A hint key that's still down: tap switches, hold peeks.
    private var held: (code: CGKeyCode, index: Int)?
    private var holdTimer: DispatchWorkItem?
    private var peeking = false
    /// Whether the peek panel is actually on screen (it may be waiting briefly for a capture).
    private var peekShown = false
    private var peekFallback: DispatchWorkItem?
    private static let holdDelay = 0.22
    /// Hovering a drag over an app this long switches to it, so the drag can continue into its window.
    private static let springDelay = 0.5
    private var springTimer: DispatchWorkItem?

    /// Tells the event tap to stop swallowing keys.
    var onClose: (() -> Void)?

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
            self.jump()
        }
        window.onHover = { [weak self] i in self?.hover(i) }
        window.onDragHover = { [weak self] i in self?.dragHover(i) }
        window.onDrop = { [weak self] i, urls in self?.drop(i, urls) }
        apps.onLaunch = { [weak self] app in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = self?.icons.image(for: app) }
        }
        thumbs.onUpdate = { [weak self] pid in self?.thumbUpdated(pid) }
        apps.onChange = { [weak self] in self?.appsChanged() }
        finder.onChange = { [weak self] in self?.appsChanged() }
        finder.refresh()
        apps.onDeactivate = { [weak self] app in
            // Windows usually get closed while their app is active, so re-check Finder on every switch.
            self?.finder.refresh()
            // Keep previews warm: grab the window of the app we're leaving while it is still on screen.
            guard let self, self.wantsThumbs, !self.isVisible else { return }
            self.thumbs.refresh([app.processIdentifier])
        }
    }

    // MARK: Event handling

    var tapHandlers: KeyTap.Handlers {
        KeyTap.Handlers(
            open: { [weak self] reverse in
                guard let self else { return }
                self.endPreview()
                self.show(reverse: reverse)
            },
            key: { [weak self] code, shift, isRepeat in
                guard let self, self.isVisible else { return }
                // Holding a hint key (or Q) must not re-trigger it.
                if isRepeat && Int(code) != kVK_Tab && !KeyMap.isArrow(code) { return }
                self.key(code, shift: shift)
            },
            keyUp: { [weak self] code in
                guard let self, let h = self.held, h.code == code else { return }
                self.releaseHeld()
            },
            commandReleased: { [weak self] in self?.commit() },
            cancel: { [weak self] in self?.hide() }
        )
    }

    private func key(_ code: CGKeyCode, shift: Bool) {
        if held != nil {
            // Q while holding a hint key quits that app; any other key just drops the hold.
            if KeyMap.isQ(code) {
                cancelHold()
                quitSelected()
                return
            }
            cancelHold()
        }
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
                hint(pos, code: code)
            } else if KeyMap.isQ(code) {
                quitSelected()
            }
        }
    }

    private func hint(_ pos: KeyPos, code: CGKeyCode) {
        typed.append(pos)
        var result = HintGrid.match(typed, in: plan)
        if result == .none, typed.count > 1 {
            typed = [pos]
            result = HintGrid.match(typed, in: plan)
        }
        switch result {
        case .exact(let i):
            selected = i
            if Settings.shared.holdToPeek {
                beginHold(code: code, index: i)
            } else {
                jump()
            }
        case .prefix:
            refreshDim()
        case .none:
            typed = []
            refreshDim()
        }
    }

    // MARK: Mouse and drag

    private func hover(_ i: Int) {
        guard isVisible, held == nil, i != selected, i < items.count else { return }
        selected = i
        window.select(i)
    }

    /// Spring-loading: a drag resting on an app switches to it, like clicking it.
    private func dragHover(_ i: Int?) {
        springTimer?.cancel()
        springTimer = nil
        guard isVisible, let i, i < items.count else { return }
        hover(i)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible, self.selected == i else { return }
            self.commit()
        }
        springTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.springDelay, execute: work)
    }

    /// Dropping files on an app opens them with it (like the Dock); anything else just switches to it.
    private func drop(_ i: Int, _ urls: [URL]) {
        springTimer?.cancel()
        springTimer = nil
        guard isVisible, i < items.count else { return }
        let app = items[i]
        guard !urls.isEmpty, let appURL = app.bundleURL else {
            selected = i
            commit()
            return
        }
        hide()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)
    }

    // MARK: Hold to peek

    private func beginHold(code: CGKeyCode, index: Int) {
        typed = []
        refreshDim()
        if pendingPresent == nil { window.select(index) }
        held = (code, index)
        let work = DispatchWorkItem { [weak self] in self?.startPeek() }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    }

    /// Key released: a quick tap switches, the end of a hold just closes the peek and keeps the selection.
    private func releaseHeld() {
        let wasPeeking = peeking
        cancelHold()
        if !wasPeeking { jump() }
    }

    private func cancelHold() {
        holdTimer?.cancel()
        holdTimer = nil
        peekFallback?.cancel()
        peekFallback = nil
        held = nil
        if peeking {
            peeking = false
            peekShown = false
            window.hidePeek()
        }
    }

    private func startPeek() {
        guard let h = held, isVisible, h.index < items.count else { return }
        if pendingPresent != nil {
            pendingPresent?.cancel()
            pendingPresent = nil
            present()
        }
        peeking = true
        let pid = items[h.index].processIdentifier
        let capturing = thumbs.refresh([pid]).contains(pid) || thumbs.isCapturing(pid)
        if thumbs.images[pid] != nil || !capturing {
            showPeekNow()
        } else {
            // A capture is on its way: wait a moment for it rather than flashing the icon first.
            let work = DispatchWorkItem { [weak self] in self?.showPeekNow() }
            peekFallback = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func showPeekNow() {
        peekFallback?.cancel()
        peekFallback = nil
        guard peeking, let h = held, h.index < items.count else { return }
        let app = items[h.index]
        window.showPeek(index: h.index, image: thumbs.images[app.processIdentifier], icon: icons.image(for: app),
                        name: app.localizedName ?? "")
        peekShown = true
    }

    private var wantsThumbs: Bool { mode == .previews || Settings.shared.holdToPeek }

    private func thumbUpdated(_ pid: pid_t) {
        guard let img = thumbs.images[pid] else { return }
        if peeking, let h = held, h.index < items.count, items[h.index].processIdentifier == pid {
            if peekShown { window.updatePeek(img) } else { showPeekNow() }
        }
        if isVisible, mode == .previews, let i = items.firstIndex(where: { $0.processIdentifier == pid }) {
            window.updateThumb(i, img)
        }
    }

    // MARK: Showing

    /// Lays out the running apps: picks the grid, who gets the home row, and the Tab order.
    @discardableResult
    private func prepare() -> Bool {
        var mru = apps.current()
        if Settings.shared.hideIdleFinder && !finder.hasWindows {
            // Keep Finder only when it is the current app (e.g. you clicked the desktop).
            mru = mru.enumerated().filter { $0.offset == 0 || !FinderWatch.isFinder($0.element) }.map(\.element)
        }
        mru = Array(mru.prefix(HintGrid.maxItems))
        guard !mru.isEmpty else { return false }
        plan = HintGrid.plan(count: mru.count)
        let s = Settings.shared
        let info = mru.map { AppInfo(id: AppTracker.id($0), name: $0.localizedName ?? "", uses: apps.uses($0)) }
        items = Arranger.arrange(info, ordering: s.ordering, primary: plan.homeCount, stableRest: s.stableRest).map { mru[$0] }
        // Start on the previous app wherever it landed, so a quick ⌘Tab always swaps between the last two apps.
        selected = mru.count > 1 ? items.firstIndex(of: mru[1]) ?? 0 : 0
        return true
    }

    private func show(reverse: Bool) {
        finder.refresh()
        guard prepare() else {
            onClose?()
            return
        }
        if reverse { selected = items.count - 1 }
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
        if !quitting.isEmpty { refreshDim() }
        // Capture in the background so previews (and hold-to-peek) are ready by the time they're needed.
        if wantsThumbs { thumbs.refresh(items.map(\.processIdentifier)) }
    }

    private func refreshDim() {
        let t = typed
        window.dim { i in
            !self.quitting.contains(self.items[i].processIdentifier)
                && (t.isEmpty || self.plan.slots[i].keys.starts(with: t))
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
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

    /// Like the native switcher: quit the selected app and stay open; the grid re-renders once it's gone.
    private func quitSelected() {
        guard selected < items.count else { return }
        let app = items[selected]
        quitting.insert(app.processIdentifier)
        app.terminate()
        refreshDim()
    }

    /// Re-lays out the open switcher when an app launches or quits, keeping the selection where it makes sense.
    private func appsChanged() {
        guard isVisible || previewing else { return }
        let previous = selected < items.count ? items[selected] : nil
        let previousIndex = selected
        quitting = quitting.filter { pid in items.contains { $0.processIdentifier == pid && !$0.isTerminated } }
        guard prepare() else { hide(); endPreview(); return }
        if let previous, !previous.isTerminated, let i = items.firstIndex(of: previous) {
            selected = i
        } else {
            selected = min(previousIndex, items.count - 1)
        }
        typed = []
        if pendingPresent == nil { present() }
    }

    // MARK: Finishing

    /// Switch to the selected app but keep the switcher open while ⌘ is held, so you can keep jumping.
    /// The grid doesn't rearrange while open, so every key keeps pointing at the same app.
    private func jump() {
        guard isVisible, selected < items.count else { return }
        window.select(selected)
        Activator.activate(items[selected])
    }

    private func commit() {
        guard isVisible else { return }
        let target = selected < items.count ? items[selected] : nil
        hide()
        if let target { Activator.activate(target) }
    }

    private func hide() {
        cancelHold()
        springTimer?.cancel()
        springTimer = nil
        onClose?()
        isVisible = false
        quitting = []
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

    #if DEBUG

    /// Renders the switcher for the current apps into a PNG (no permissions needed).
    func snapshot(to path: String, mode m: Mode) {
        Settings.shared.mode = m
        prepare()
        isVisible = true
        present()
        render(window.contentView, to: path)
        if selected < items.count {
            let app = items[selected]
            window.showPeek(index: selected, image: thumbs.images[app.processIdentifier], icon: icons.image(for: app),
                            name: app.localizedName ?? "")
            render(window.peekView, to: path.replacingOccurrences(of: ".png", with: "-peek.png"))
        }
        hide()
    }

    private func render(_ view: NSView, to path: String) {
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
    }
    #endif
}
