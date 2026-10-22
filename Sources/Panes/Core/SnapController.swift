import AppKit

/// Watches mouse drags; when a window is dragged to a screen edge or corner,
/// shows a preview and snaps the window there on release.
final class SnapController {
    static let shared = SnapController()

    private enum State { case idle, pending, moving, ignoring }

    private var monitors: [Any] = []
    private var state: State = .idle
    private var window: AXWindow?
    private var startFrame: CGRect?
    private var startMouse: CGPoint = .zero
    private var current: (area: SnapArea, screen: NSScreen)?
    private var pendingChecks = 0

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

    private func mouseDown() {
        reset()
        guard settings.snapEnabled || settings.restoreSizeOnDragAway else { return }
        startMouse = Geometry.mouseAX
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
        case .pending:
            guard hypot(p.x - startMouse.x, p.y - startMouse.y) > 3 else { return }
            pendingChecks += 1
            guard let w = window, let f0 = startFrame, let f = w.frame else { state = .ignoring; return }
            if f.size != f0.size { state = .ignoring; return }       // a resize, not a move
            if f.origin != f0.origin {
                state = .moving
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
            current = nil
            PreviewOverlay.shared.hide()
            return
        }
        current = (area, screen)
        PreviewOverlay.shared.show(axFrame: WindowManager.shared.targetFrame(unit: area.target, screen: screen))
    }

    /// Finds the snap area under an AX-space point. Corners win over edges.
    static func area(at p: CGPoint, on screen: NSScreen, settings: SettingsData) -> SnapArea? {
        let f = screen.axFrame
        let t = CGFloat(settings.snapThreshold)
        let c = CGFloat(settings.cornerSize)
        let dl = p.x - f.minX, dr = f.maxX - 1 - p.x, dt = p.y - f.minY, db = f.maxY - 1 - p.y

        func hits(_ a: SnapArea) -> Bool {
            switch a.edge {
            case .topLeft: return (dl <= t && dt <= c) || (dt <= t && dl <= c)
            case .topRight: return (dr <= t && dt <= c) || (dt <= t && dr <= c)
            case .bottomLeft: return (dl <= t && db <= c) || (db <= t && dl <= c)
            case .bottomRight: return (dr <= t && db <= c) || (db <= t && dr <= c)
            case .left: return dl <= t && inSeg(dt / f.height, a)
            case .right: return dr <= t && inSeg(dt / f.height, a)
            case .top: return dt <= t && inSeg(dl / f.width, a)
            case .bottom: return db <= t && inSeg(dl / f.width, a)
            }
        }
        func inSeg(_ v: CGFloat, _ a: SnapArea) -> Bool { v >= a.from && v <= a.to }

        let enabled = settings.snapAreas.filter(\.enabled)
        return enabled.first { $0.edge.isCorner && hits($0) } ?? enabled.first { !$0.edge.isCorner && hits($0) }
    }
}
