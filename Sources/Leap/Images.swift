import AppKit
import ScreenCaptureKit

/// Pre-rendered app icons so showing the switcher never rasterizes.
@MainActor
final class IconCache {
    private var images: [pid_t: CGImage] = [:]
    private let pixels = 192

    func image(for app: NSRunningApplication) -> CGImage? {
        let pid = app.processIdentifier
        if let img = images[pid] { return img }
        guard let icon = app.icon else { return nil }
        let img = render(icon)
        images[pid] = img
        return img
    }

    func warm(_ apps: [NSRunningApplication]) { for app in apps { _ = image(for: app) } }

    func prune(keeping apps: [NSRunningApplication]) {
        let live = Set(apps.map(\.processIdentifier))
        images = images.filter { live.contains($0.key) }
    }

    private func render(_ icon: NSImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

/// Window thumbnails via ScreenCaptureKit. Cached images are shown instantly and refreshed in the background.
@MainActor
final class ThumbnailCache {
    private(set) var images: [pid_t: CGImage] = [:]
    private var inFlight = Set<pid_t>()
    private var capturedAt: [pid_t: Date] = [:]
    /// Fires on the main thread whenever a pid gets a new image.
    var onUpdate: ((pid_t) -> Void)?

    /// Fetching shareable content is the slow part of a capture, so reuse it briefly.
    private var content: SCShareableContent?
    private var contentAt = Date.distantPast
    private var granted = false

    var hasPermission: Bool {
        if !granted { granted = CGPreflightScreenCaptureAccess() }
        return granted
    }

    func prune(keeping apps: [NSRunningApplication]) {
        let live = Set(apps.map(\.processIdentifier))
        images = images.filter { live.contains($0.key) }
    }

    func isCapturing(_ pid: pid_t) -> Bool { inFlight.contains(pid) }

    /// Re-captures the frontmost on-screen window of each app. Returns the pids now being captured
    /// (apps with no capturable window aren't included).
    @discardableResult
    func refresh(_ pids: [pid_t]) -> Set<pid_t> {
        guard hasPermission else { return [] }
        let windows = Self.frontWindowIDs(for: Set(pids))
        let now = Date()
        let targets = windows.filter { !inFlight.contains($0.key) && now.timeIntervalSince(capturedAt[$0.key] ?? .distantPast) > 1.5 }
        let capturing = Set(windows.keys)
        guard !targets.isEmpty else { return capturing.intersection(inFlight) }
        inFlight.formUnion(targets.keys)
        Task { [weak self] in
            guard let self else { return }
            let content = await self.shareableContent(containing: Set(targets.values))
            let byID = Dictionary((content?.windows ?? []).map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            await withTaskGroup(of: (pid_t, CGImage?).self) { group in
                for (pid, wid) in targets {
                    let window = byID[wid]
                    group.addTask {
                        guard let window else { return (pid, nil) }
                        return (pid, try? await Self.shoot(window))
                    }
                }
                for await (pid, img) in group {
                    self.inFlight.remove(pid)
                    if let img {
                        self.images[pid] = img
                        self.capturedAt[pid] = Date()
                        self.onUpdate?(pid)
                    }
                }
            }
        }
        return capturing.intersection(inFlight)
    }

    private func shareableContent(containing ids: Set<CGWindowID>) async -> SCShareableContent? {
        if let content, Date().timeIntervalSince(contentAt) < 2,
           ids.isSubset(of: Set(content.windows.map(\.windowID))) { return content }
        content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        contentAt = Date()
        return content
    }

    private nonisolated static func shoot(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let maxW = 1040.0, maxH = 680.0
        let s = min(maxW / max(window.frame.width, 1), maxH / max(window.frame.height, 1), 2)
        config.width = max(Int(window.frame.width * s), 1)
        config.height = max(Int(window.frame.height * s), 1)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Frontmost normal window per pid, from the cheap CGWindowList.
    private static func frontWindowIDs(for pids: Set<pid_t>) -> [pid_t: CGWindowID] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var out: [pid_t: CGWindowID] = [:]
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid), out[pid] == nil,
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) > 80, (b["Height"] ?? 0) > 60 else { continue }
            out[pid] = wid
        }
        return out
    }
}
