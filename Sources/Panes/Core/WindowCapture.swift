// Window pictures for roll-up glance and pinning.
// Approach adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// prototype/ScreenCaptureBridge.swift (SCStream per window) and docs/glance.md
// (a quick CGWindowListCreateImage snapshot at fold time, live stream only for
// windows that are still composited — hidden/minimized windows yield no frames).

import AppKit
import ScreenCaptureKit

enum WindowCapture {
    /// Whether macOS lets Panes read other windows' pixels (Screen Recording).
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt once; afterwards the user grants it in Settings.
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    /// One still picture of a window, nil without permission.
    static func snapshot(_ id: CGWindowID) -> CGImage? {
        guard hasPermission else { return nil }
        return CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])
    }
}

/// Streams one window's live pixels into a layer. Frames only arrive while the
/// window server still composites the window (on screen, other Space, or parked
/// off screen) — not for minimized windows or hidden apps.
final class LiveWindowStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "panes.livestream")
    private weak var layer: CALayer?
    private(set) var gotFrame = false
    var onFirstFrame: (() -> Void)?

    init(layer: CALayer) {
        self.layer = layer
    }

    func start(windowID: CGWindowID, size: CGSize, scale: CGFloat) {
        guard WindowCapture.hasPermission else { return }
        Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  let win = content.windows.first(where: { $0.windowID == windowID }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let config = SCStreamConfiguration()
            config.width = max(2, Int(size.width * scale))
            config.height = max(2, Int(size.height * scale))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = false
            config.queueDepth = 3
            guard let self else { return }
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await s.startCapture()
                self.stream = s
            } catch {
                Debug.log("livestream: \(error)")
            }
        }
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sb.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self.layer else { return }
            layer.contents = surface
            if !self.gotFrame {
                self.gotFrame = true
                self.onFirstFrame?()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Debug.log("livestream stopped: \(error)")
    }
}

/// The desktop of a screen exactly as it looks right now — a live or dynamic
/// wallpaper's current colours and the desktop icons — for backdrops that should
/// look like "nothing but the desktop is here".
/// macOS draws the wallpaper in WindowManager's "Wallpaper" window, one level below
/// the classic desktop level, and the icons at the icon level; capturing those windows
/// together (and nothing above them) gives the live desktop. The wallpaper file is only
/// a last resort: for a dynamic wallpaper it's a fixed frame that doesn't match.
enum DesktopBackdrop {
    static func image(for screen: NSScreen) -> CGImage? {
        if let live = liveDesktop(for: screen), !looksBlank(live) { return live }
        if let url = NSWorkspace.shared.desktopImageURL(for: screen), let img = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: img.size)
            return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }

    private static func liveDesktop(for screen: NSScreen) -> CGImage? {
        guard WindowCapture.hasPermission,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        let frame = screen.axFrame
        // Front to back as listed; skip the full-screen backdrop and display backstop,
        // which are plain black covers.
        var ids: [CGWindowID] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer <= icons,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.intersects(frame) else { continue }
            let name = info[kCGWindowName as String] as? String ?? ""
            if name.contains("Backdrop") || name.contains("Backstop") { continue }
            ids.append(id)
        }
        guard !ids.isEmpty else { return nil }
        var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil) else { return nil }
        return CGImage(windowListFromArrayScreenBounds: frame, windowArray: array, imageOption: [.bestResolution])
    }

    /// A capture that came back as one flat colour (e.g. taken on a full-screen
    /// app's Space, where the wallpaper isn't drawn) isn't the desktop.
    static func looksBlank(_ img: CGImage) -> Bool {
        let w = 16, h = 9
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lo = 255, hi = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let v = (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3
            lo = min(lo, v); hi = max(hi, v)
        }
        return hi - lo < 6
    }
}
