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

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func prune(keeping apps: [NSRunningApplication]) {
        let live = Set(apps.map(\.processIdentifier))
        images = images.filter { live.contains($0.key) }
    }

    /// Re-captures the frontmost on-screen window of each app; `updated` fires per new image.
    func refresh(_ pids: [pid_t], updated: @escaping @MainActor (pid_t) -> Void) {
        guard hasPermission else { return }
        let targets = Self.frontWindowIDs(for: Set(pids)).filter { !inFlight.contains($0.key) }
        guard !targets.isEmpty else { return }
        inFlight.formUnion(targets.keys)
        Task { [weak self] in
            let results = await Self.capture(targets)
            guard let self else { return }
            self.inFlight.subtract(targets.keys)
            for (pid, img) in results {
                self.images[pid] = img
                updated(pid)
            }
        }
    }

    private nonisolated static func capture(_ targets: [pid_t: CGWindowID]) async -> [(pid_t, CGImage)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        return await withTaskGroup(of: (pid_t, CGImage)?.self) { group in
            for (pid, wid) in targets {
                guard let window = byID[wid] else { continue }
                group.addTask {
                    guard let img = try? await shoot(window) else { return nil }
                    return (pid, img)
                }
            }
            var out: [(pid_t, CGImage)] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }

    private nonisolated static func shoot(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let maxW = 560.0, maxH = 360.0
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
