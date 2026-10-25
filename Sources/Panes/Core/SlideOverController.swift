// Slide Over (iPad style, "侧拉"): one window leans on the left or right edge, floats
// in front of the other apps inside a glass ring; drag the ring to move it, the bottom
// corners to resize; fling it at the edge to tuck it away behind a small handle, click
// or pull the handle to bring it back.
// Adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// prototype/App/SlideOver.swift + SlideOverGlass/Chrome — the real window itself moves
// (AX can push it past the side edge leaving a few points on screen, no bounce, so no
// stand-in picture and nothing gets hidden or minimized); one window at a time, sliding
// over another releases the first in place; lean on the side nearest the window unless
// that side touches another display. macOS won't put a background app's window above
// the active app's, so — as WindowShade does with its pin mirror — while another app is
// in front a live picture of the window (ScreenCaptureKit) floats in its place; when the
// pointer enters it the real window is brought forward and the picture steps aside.

import AppKit
import ApplicationServices

final class SlideOverController {
    static let shared = SlideOverController()

    enum Side { case left, right }

    private final class Docked {
        let id: CGWindowID
        let window: AXWindow
        let pid: pid_t
        var side: Side
        let original: CGRect
        var frame: CGRect          // docked frame, AX space
        var stashed = false
        init(id: CGWindowID, window: AXWindow, side: Side, original: CGRect, frame: CGRect) {
            self.id = id; self.window = window; self.pid = window.pid
            self.side = side; self.original = original; self.frame = frame
        }
    }

    private var docked: Docked?
    private var ring: GlassRing?
    private var mirror: SlideMirror?
    private var handle: SlideHandle?
    private var watch: AXWatch?
    private var activationObserver: Any?

    private var settings: SettingsData { Settings.shared.data }
    static let inset: CGFloat = 12

    func applySettings() {
        if !settings.slideOverEnabled { release(restore: false) }
    }

    /// Quitting: a tucked-away window must come back on screen, synchronously.
    func restoreForQuit() {
        guard let d = docked else { return }
        docked = nil
        if d.stashed { d.window.setFrame(d.frame) }
        ParkedJournal.clear("slideover")
    }

    func isDocked(_ w: AXWindow) -> Bool { w.cgWindowID != nil && w.cgWindowID == docked?.id }

    // MARK: Geometry

    /// Where a window leans on a screen side.
    static func dockFrame(for size: CGSize, side: Side, screen: NSScreen) -> CGRect {
        let vf = screen.axVisibleFrame
        let w = min(max(size.width, 320), vf.width * 0.4)
        let h = vf.height - 2 * inset
        let x = side == .left ? vf.minX + inset : vf.maxX - inset - w
        return CGRect(x: x, y: vf.minY + inset, width: w, height: h)
    }

    /// Nearest side, unless that side borders another display.
    static func side(for frame: CGRect, on screen: NSScreen) -> Side {
        let f = screen.frame
        let near: Side = frame.midX < Geometry.axRect(fromCocoa: f).midX ? .left : .right
        let neighbour = NSScreen.screens.contains { o in
            o != screen && o.frame.maxY > f.minY && o.frame.minY < f.maxY &&
                (near == .left ? abs(o.frame.maxX - f.minX) < 2 : abs(o.frame.minX - f.maxX) < 2)
        }
        return neighbour ? (near == .left ? .right : .left) : near
    }

    // MARK: Enter / leave

    /// Shortcut: slide the focused window over (or release the one in slide over).
    func toggle(_ target: AXWindow?) {
        guard settings.slideOverEnabled, let w = target ?? AXWindow.focused(), let f = w.frame,
              let screen = NSScreen.screen(forAX: f) else { NSSound.beep(); return }
        if isDocked(w) { release(restore: true); return }
        dock(w, side: Self.side(for: f, on: screen), screen: screen)
    }

    func dock(_ w: AXWindow, side: Side, screen: NSScreen) {
        guard settings.slideOverEnabled, let id = w.cgWindowID, let f = w.frame,
              !Settings.shared.isExcluded(w.bundleID), w.isStandard, !w.isFullScreen else { NSSound.beep(); return }
        release(restore: false)          // only one: the previous one stays where it is
        let target = Self.dockFrame(for: f.size, side: side, screen: screen)
        let d = Docked(id: id, window: w, side: side, original: f, frame: target)
        docked = d
        ParkedJournal.record("slideover", [(w, f)])
        WindowGlide.glide(w, to: target) { [weak self] in
            guard let self, self.docked === d else { return }
            d.frame = w.frame ?? target
            self.showRing()
        }
        w.raise()
        watch = AXWatch(pid: w.pid, notifications: [kAXWindowMovedNotification, kAXWindowResizedNotification,
                                                     kAXUIElementDestroyedNotification]) { [weak self] note in
            self?.windowChanged(note)
        }
        observeActivation()
        Debug.log("slideover: dock \(w.bundleID ?? "?") \(side)")
    }

    /// Leave slide over. `restore` puts the window back where it was before.
    func release(restore: Bool) {
        guard let d = docked else { return }
        docked = nil
        ring?.orderOut(nil); ring = nil
        handle?.orderOut(nil); handle = nil
        mirror?.close(); mirror = nil
        watch = nil
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
        if restore || d.stashed { WindowGlide.glide(d.window, to: d.original) }
        ParkedJournal.clear("slideover")
    }

    // MARK: Stash behind a handle

    /// Called by the drag arbiter when the docked window is flung at (or dropped on)
    /// its own edge.
    func stash() {
        guard let d = docked, !d.stashed, let f = d.window.frame, let screen = NSScreen.screen(forAX: f) else { return }
        d.stashed = true
        d.frame = f
        ring?.orderOut(nil)
        mirror?.close(); mirror = nil
        let sf = screen.axFrame
        let x = d.side == .left ? sf.minX - f.width + 6 : sf.maxX - 6
        WindowGlide.glide(d.window, to: CGRect(x: x, y: f.minY, width: f.width, height: f.height))
        let h = SlideHandle(side: d.side, screen: screen, centerY: f.midY)
        h.onBringBack = { [weak self] in self?.bringBack() }
        handle = h
        h.orderFrontRegardless()
    }

    func bringBack() {
        guard let d = docked, d.stashed else { return }
        d.stashed = false
        handle?.orderOut(nil); handle = nil
        WindowGlide.glide(d.window, to: d.frame) { [weak self] in self?.showRing() }
        d.window.raise()
    }

    /// Whether a drop of the docked window should tuck it away: the pointer reached
    /// its edge, or it was thrown toward that edge.
    func shouldStash(_ w: AXWindow, pointer: CGPoint, velocity: CGVector?) -> Bool {
        guard let d = docked, isDocked(w), !d.stashed, let screen = NSScreen.screen(containingAX: pointer) else { return false }
        let sf = screen.axFrame
        let atEdge = d.side == .left ? pointer.x - sf.minX < 12 : sf.maxX - pointer.x < 12
        let thrown = velocity.map { d.side == .left ? $0.dx < -1200 : $0.dx > 1200 } ?? false
        return atEdge || thrown
    }

    // MARK: Following the window

    private func windowChanged(_ note: String) {
        guard let d = docked else { return }
        if note == kAXUIElementDestroyedNotification {
            if AXWindow.serverFrame(of: d.id) == nil { release(restore: false) }
            return
        }
        guard !d.stashed, let f = d.window.frame else { return }
        d.frame = f
        ring?.track(f)
        mirror?.track(f)
    }

    /// Another app came forward and may cover the window: float its live picture in
    /// its place. Its own app came forward: the real window is on top, drop the picture.
    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let d = self.docked, !d.stashed,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier == d.pid {
                self.mirror?.close(); self.mirror = nil
            } else {
                self.showMirror()
            }
            self.ring?.orderFrontRegardless()
        }
    }

    private func showMirror() {
        guard mirror == nil, let d = docked, WindowCapture.hasPermission, let f = d.window.frame else { return }
        let m = SlideMirror(windowID: d.id, frame: f)
        m.onEnter = { [weak self] in self?.handOff() }
        mirror = m
        m.show()
    }

    /// Pointer entered the picture: bring the real window forward under it.
    private func handOff() {
        guard let d = docked else { return }
        Debug.log("slideover: hand-off to \(d.window.bundleID ?? "?")")
        AXUIElementSetAttributeValue(d.window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        d.window.raise()
        // Activation removes the picture (observer above) once the app is in front.
    }

    private func showRing() {
        guard let d = docked, !d.stashed, let f = d.window.frame else { return }
        let r = ring ?? GlassRing()
        ring = r
        r.onMove = { [weak self] dx, dy in self?.moveBy(dx, dy) }
        r.onResize = { [weak self] dx, dy, left in self?.resizeBy(dx, dy, fromLeft: left) }
        r.track(f)
        r.orderFrontRegardless()
    }

    private func moveBy(_ dx: CGFloat, _ dy: CGFloat) {
        guard let d = docked, let f = d.window.frame else { return }
        let n = f.offsetBy(dx: dx, dy: dy)
        d.window.setPosition(n.origin)
        d.frame = n
        ring?.track(n)
    }

    private func resizeBy(_ dx: CGFloat, _ dy: CGFloat, fromLeft: Bool) {
        guard let d = docked, let f = d.window.frame else { return }
        var n = f
        if fromLeft { n.origin.x += dx; n.size.width -= dx } else { n.size.width += dx }
        n.size.height += dy
        n.size.width = max(n.width, 280); n.size.height = max(n.height, 200)
        d.window.setFrame(n)
        d.frame = d.window.frame ?? n
        ring?.track(d.frame)
    }
}

/// The glass ring around the slide-over window. Its middle is fully transparent,
/// so clicks there go straight through to the window underneath.
final class GlassRing: NSPanel {
    static let width: CGFloat = 7
    var onMove: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onResize: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }
    private let ringView = RingView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        ringView.onDrag = { [weak self] dx, dy, mode in
            switch mode {
            case .move: self?.onMove(dx, dy)
            case .resizeLeft: self?.onResize(dx, dy, true)
            case .resizeRight: self?.onResize(dx, dy, false)
            }
        }
        contentView = ringView
    }

    /// Wrap a window frame (AX space).
    func track(_ ax: CGRect) {
        let r = Geometry.cocoaRect(fromAX: ax).insetBy(dx: -Self.width, dy: -Self.width)
        setFrame(r, display: true)
    }
}

private final class RingView: NSView {
    enum Mode { case move, resizeLeft, resizeRight }
    var onDrag: (CGFloat, CGFloat, Mode) -> Void = { _, _, _ in }
    private var last: CGPoint?
    private var mode: Mode = .move
    private let glass = NSVisualEffectView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.maskImage = Self.ringMask(size: bounds.size)
    }

    /// A rounded ring, transparent in the middle.
    static func ringMask(size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            let outer = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
            let inner = NSBezierPath(roundedRect: r.insetBy(dx: GlassRing.width, dy: GlassRing.width), xRadius: 10, yRadius: 10)
            outer.append(inner)
            outer.windingRule = .evenOdd
            NSColor.black.setFill()
            outer.fill()
            return true
        }
    }

    // Only the ring takes the mouse; the middle passes clicks through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.insetBy(dx: GlassRing.width, dy: GlassRing.width).contains(p) ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        last = NSEvent.mouseLocation
        let corner: CGFloat = 28
        if p.y < corner && p.x < corner { mode = .resizeLeft }
        else if p.y < corner && p.x > bounds.width - corner { mode = .resizeRight }
        else { mode = .move }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let l = last else { return }
        let m = NSEvent.mouseLocation
        last = m
        // Cocoa y grows up; AX y grows down.
        onDrag(m.x - l.x, -(m.y - l.y), mode)
    }

    override func mouseUp(with event: NSEvent) { last = nil }

    override func resetCursorRects() {
        let c: CGFloat = 28
        addCursorRect(CGRect(x: 0, y: 0, width: c, height: c), cursor: .crosshair)
        addCursorRect(CGRect(x: bounds.width - c, y: 0, width: c, height: c), cursor: .crosshair)
    }
}

/// The tab left at the screen edge while the slide-over window is tucked away.
final class SlideHandle: NSPanel {
    var onBringBack: () -> Void = {}

    init(side: SlideOverController.Side, screen: NSScreen, centerY axY: CGFloat) {
        let size = CGSize(width: 16, height: 90)
        let sf = screen.frame
        let cy = Geometry.primaryHeight - axY
        let x = side == .left ? sf.minX : sf.maxX - size.width
        super.init(contentRect: CGRect(x: x, y: cy - size.height / 2, width: size.width, height: size.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        let v = HandleView(frame: CGRect(origin: .zero, size: size), side: side)
        v.onActivate = { [weak self] in self?.onBringBack() }
        contentView = v
    }
}

private final class HandleView: NSView {
    var onActivate: () -> Void = {}
    private let side: SlideOverController.Side
    private var down: CGPoint?

    init(frame: NSRect, side: SlideOverController.Side) {
        self.side = side
        super.init(frame: frame)
        let bg = NSVisualEffectView(frame: bounds)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 7
        bg.autoresizingMask = [.width, .height]
        addSubview(bg)
        let arrow = NSImageView(image: NSImage(systemSymbolName: side == .left ? "chevron.right" : "chevron.left",
                                               accessibilityDescription: "拉回侧拉窗口")!)
        arrow.frame = CGRect(x: 2, y: frame.height / 2 - 8, width: 12, height: 16)
        arrow.contentTintColor = .secondaryLabelColor
        addSubview(arrow)
        toolTip = "点一下或往里拉，拉回侧拉窗口"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { down = NSEvent.mouseLocation }
    override func mouseDragged(with event: NSEvent) {
        guard let d = down else { return }
        let dx = NSEvent.mouseLocation.x - d.x
        // Pull inward (toward the middle of the screen).
        if side == .left ? dx > 10 : dx < -10 { down = nil; onActivate() }
    }
    override func mouseUp(with event: NSEvent) {
        if down != nil { onActivate() }
        down = nil
    }
}

/// A live picture of the slide-over window floating where it is, while another app
/// is in front. Entering it hands the pointer back to the real window.
final class SlideMirror {
    private let panel: NSPanel
    private let view = MirrorView()
    private let stream: LiveWindowStream
    var onEnter: () -> Void = {}

    init(windowID: CGWindowID, frame ax: CGRect) {
        panel = NSPanel(contentRect: Geometry.cocoaRect(fromAX: ax), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the glass ring panel, whose transparent middle would otherwise sit on top.
        panel.level = NSWindow.Level(NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        view.frame = CGRect(origin: .zero, size: ax.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        stream = LiveWindowStream(layer: view.layer!)
        stream.start(windowID: windowID, size: ax.size, scale: NSScreen.main?.backingScaleFactor ?? 2)
        view.onEnter = { [weak self] in self?.onEnter() }
    }

    func show() { panel.orderFrontRegardless() }

    func track(_ ax: CGRect) { panel.setFrame(Geometry.cocoaRect(fromAX: ax), display: true) }

    func close() {
        stream.stop()
        panel.orderOut(nil)
    }

    final class MirrorView: NSView {
        var onEnter: () -> Void = {}
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.masksToBounds = true
            layer?.contentsGravity = .resize
        }
        required init?(coder: NSCoder) { fatalError() }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { Debug.log("slideover: mirror entered"); onEnter() }
        override func mouseMoved(with event: NSEvent) { onEnter() }
        override func mouseDown(with event: NSEvent) { onEnter() }
    }
}
