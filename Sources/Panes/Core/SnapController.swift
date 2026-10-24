import AppKit

/// Watches mouse drags; when a window is dragged to a screen edge or corner,
/// shows a preview and snaps the window there on release.
final class SnapController {
    static let shared = SnapController()

    private enum State { case idle, armed, pending, moving, ignoring }

    private var monitors: [Any] = []
    private var state: State = .idle
    private var window: AXWindow?
    private var startFrame: CGRect?
    private var startMouse: CGPoint = .zero
    private var current: (area: SnapArea, screen: NSScreen)?
    private var pendingChecks = 0
    /// Set when a drag starts inside a trigger band (e.g. a window right under the
    /// menu bar): snapping stays off until the cursor has left the band once.
    private var suppressUntilLeave = false

    private var settings: SettingsData { Settings.shared.data }

    func start() {
        stop()
        let mask: [NSEvent.EventTypeMask] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        for m in mask {
            if let mon = NSEvent.addGlobalMonitorForEvents(matching: m, handler: { [weak self] e in self?.handle(e) }) {
                monitors.append(mon)
            }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown: mouseDown()
        case .leftMouseDragged: mouseDragged(e)
        case .leftMouseUp: mouseUp()
        default: break
        }
    }

    /// A click only records where it happened; the window lookup waits until the
    /// mouse actually drags, so ordinary clicks cost nothing.
    private func mouseDown() {
        reset()
        guard settings.snapEnabled || settings.restoreSizeOnDragAway else { return }
        startMouse = Geometry.mouseAX
        state = .armed
    }

    /// Finds the window under the original click once a drag begins.
    private func arm() {
        guard let w = AXWindow.at(startMouse), w.pid != ProcessInfo.processInfo.processIdentifier,
              !Settings.shared.isExcluded(w.bundleID), let f = w.frame else {
            state = .ignoring
            return
        }
        // Only drags that start near the top of the window can be title-bar drags.
        // Toolbar-style apps put draggable areas lower, so be generous.
        if startMouse.y - f.minY > 120 { state = .ignoring; return }
        window = w
        startFrame = f
        state = .pending
        pendingChecks = 0
    }

    private func mouseDragged(_ e: NSEvent) {
        let p = Geometry.mouseAX
        switch state {
        case .idle, .ignoring:
            return
        case .armed:
            guard hypot(p.x - startMouse.x, p.y - startMouse.y) > 3 else { return }
            arm()
        case .pending:
            pendingChecks += 1
            guard let w = window, let f0 = startFrame, let f = w.frame else { state = .ignoring; return }
            if f.size != f0.size { state = .ignoring; return }       // a resize, not a move
            if f.origin != f0.origin {
                state = .moving
                if let screen = NSScreen.screen(containingAX: startMouse) {
                    suppressUntilLeave = Self.area(at: startMouse, on: screen, settings: settings) != nil
                }
                beganMoving(w, frame: f, mouse: p)
            } else if pendingChecks > 25 {
                state = .ignoring                                     // dragging content, not the window
            }
        case .moving:
            updatePreview(at: p, flags: e.modifierFlags)
        }
    }

    private func mouseUp() {
        defer { reset() }
        guard state == .moving, let w = window, let hit = current else { return }
        // Let the app finish its own drag before we reposition.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            WindowManager.shared.place(w, unit: hit.area.target, on: hit.screen)
        }
    }

    private func reset() {
        state = .idle
        suppressUntilLeave = false
        window = nil
        startFrame = nil
        current = nil
        PreviewOverlay.shared.hide()
    }

    /// Dragging a snapped window away gives it its old size back (like Windows).
    private func beganMoving(_ w: AXWindow, frame: CGRect, mouse: CGPoint) {
        guard settings.restoreSizeOnDragAway, let orig = WindowManager.shared.preSnapFrame(of: w) else { return }
        WindowManager.shared.forget(w)
        let ratio = (mouse.x - frame.minX) / max(frame.width, 1)
        let x = mouse.x - ratio * orig.width
        let y = frame.minY
        w.setSize(orig.size)
        w.setPosition(CGPoint(x: x, y: y))
    }

    private func updatePreview(at p: CGPoint, flags: NSEvent.ModifierFlags) {
        guard settings.snapEnabled, !settings.disableSnapModifier.matches(flags),
              let screen = NSScreen.screen(containingAX: p), let area = Self.area(at: p, on: screen, settings: settings) else {
            suppressUntilLeave = false
            current = nil
            PreviewOverlay.shared.hide()
            return
        }
        if suppressUntilLeave { return }
        current = (area, screen)
        PreviewOverlay.shared.show(axFrame: WindowManager.shared.targetFrame(unit: area.target, screen: screen))
    }

    /// Finds the snap area under an AX-space point. Corners win over edges.
    static func area(at p: CGPoint, on screen: NSScreen, settings: SettingsData) -> SnapArea? {
        let f = screen.axFrame
        let vf = screen.axVisibleFrame
        let t = CGFloat(settings.snapThreshold)
        let c = CGFloat(settings.cornerSize)
        let dl = p.x - f.minX, dr = f.maxX - 1 - p.x, dt = p.y - f.minY, db = f.maxY - 1 - p.y
        // Each edge's trigger band also covers the menu bar / Dock on that side:
        // people let go when they reach them rather than pushing to the last pixel,
        // and holding at the very top invites Mission Control's Spaces bar.
        let tl = max(t, vf.minX - f.minX + t), tr = max(t, f.maxX - vf.maxX + t)
        let tt = max(t, vf.minY - f.minY + t), tb = max(t, f.maxY - vf.maxY + t)

        func hits(_ a: SnapArea) -> Bool {
            switch a.edge {
            case .topLeft: return (dl <= tl && dt <= c) || (dt <= tt && dl <= c)
            case .topRight: return (dr <= tr && dt <= c) || (dt <= tt && dr <= c)
            case .bottomLeft: return (dl <= tl && db <= c) || (db <= tb && dl <= c)
            case .bottomRight: return (dr <= tr && db <= c) || (db <= tb && dr <= c)
            case .left: return dl <= tl && inSeg(dt / f.height, a)
            case .right: return dr <= tr && inSeg(dt / f.height, a)
            case .top: return dt <= tt && inSeg(dl / f.width, a)
            case .bottom: return db <= tb && inSeg(dl / f.width, a)
            }
        }
        func inSeg(_ v: CGFloat, _ a: SnapArea) -> Bool { v >= a.from && v <= a.to }

        let enabled = settings.snapAreas.filter(\.enabled)
        return enabled.first { $0.edge.isCorner && hits($0) } ?? enabled.first { !$0.edge.isCorner && hits($0) }
    }
}
