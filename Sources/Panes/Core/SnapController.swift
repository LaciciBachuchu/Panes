import AppKit

/// Watches title-bar drags and is the one place that decides what letting go does.
/// While dragging it shows a preview of the outcome; on release exactly one of
/// these happens, in this order:
///   1. a dwell target was reached (rest at the middle of the left/right edge →
///      slide over),
///   2. the slide-over window was dropped on / thrown at its own edge → tuck it away,
///   3. the pointer is in a snap area → snap,
///   4. the window was thrown fast enough → fling,
///   5. nothing.
final class SnapController {
    static let shared = SnapController()

    private enum State { case idle, armed, pending, moving, ignoring }

    private var monitors: [Any] = []
    private var state: State = .idle
    private var window: AXWindow?
    private var startFrame: CGRect?
    private var startMouse: CGPoint = .zero
    private var current: (area: SnapArea, screen: NSScreen)?

    /// Places you reach by resting the pointer there for a moment while dragging.
    enum DwellZone: Equatable { case edgeMiddle(SlideOverController.Side) }
    private var dwellZone: DwellZone?
    private var dwellReached = false
    private var dwellWork: DispatchWorkItem?
    private var lastPoint: CGPoint = .zero
    private var lastFlags: NSEvent.ModifierFlags = []
    private var windowID: CGWindowID?
    private var pendingSince = Date.distantPast
    /// Set when a drag starts inside a trigger band (e.g. a window right under the
    /// menu bar): snapping stays off until the cursor has left the band once.
    private var suppressUntilLeave = false
    /// Recent pointer positions while moving, for the fling's release velocity.
    private var samples: [(t: TimeInterval, p: CGPoint)] = []

    private var settings: SettingsData { Settings.shared.data }

    func start() {
        stop()
        Self.installDebugHook()
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
            let w = AXWindow.at(startMouse)
            Debug.log("snap: no window at \(startMouse) hit=\(w?.bundleID ?? "nil") pid=\(w?.pid ?? 0) frame=\(String(describing: w?.frame)) role=\(AXWindow.element(at: startMouse)?.role ?? "nil")")
            state = .ignoring
            return
        }
        windowID = w.cgWindowID
        let f0 = windowID.flatMap(AXWindow.serverFrame(of:)) ?? f
        Debug.log("snap: armed \(w.bundleID ?? "?") frame=\(f0) mouse=\(startMouse)")
        // Only drags that start near the top of the window can be title-bar drags.
        // Toolbar-style apps put draggable areas lower, so be generous.
        if startMouse.y - f.minY > 120 { state = .ignoring; return }
        window = w
        startFrame = f0
        state = .pending
        pendingSince = Date()
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
            guard let w = window, let f0 = startFrame,
                  let f = windowID.flatMap(AXWindow.serverFrame(of:)) ?? w.frame else { state = .ignoring; return }
            if f.size != f0.size { Debug.log("snap: resize, ignoring"); state = .ignoring; return }
            if f.origin != f0.origin {
                Debug.log("snap: moving after \(Int(Date().timeIntervalSince(pendingSince) * 1000))ms")
                state = .moving
                if let screen = NSScreen.screen(containingAX: startMouse) {
                    suppressUntilLeave = Self.area(at: startMouse, on: screen, settings: settings) != nil
                }
                beganMoving(w, frame: f, mouse: p)
            } else if Date().timeIntervalSince(pendingSince) > 0.6 {
                Debug.log("snap: window never moved, ignoring")
                state = .ignoring                                     // dragging content, not the window
            }
        case .moving:
            let now = ProcessInfo.processInfo.systemUptime
            samples.append((now, p))
            samples.removeAll { now - $0.t > 0.08 }
            lastPoint = p
            lastFlags = e.modifierFlags
            updateDwell(at: p)
            updatePreview(at: p, flags: e.modifierFlags)
        }
    }

    private enum Drop {
        case slideOver(SlideOverController.Side, NSScreen)
        case stash
        case snap(SnapArea, NSScreen)
        case fling(CGVector)
        case none
    }

    /// The single decision for a released title-bar drag.
    private func resolveDrop(_ w: AXWindow) -> Drop {
        let p = Geometry.mouseAX
        let bypass = settings.disableSnapModifier.matches(NSEvent.modifierFlags)
        if !bypass, dwellReached, case .edgeMiddle(let side)? = dwellZone, let screen = NSScreen.screen(containingAX: p) {
            return .slideOver(side, screen)
        }
        let v = releaseVelocity(minimum: 0)
        if SlideOverController.shared.shouldStash(w, pointer: p, velocity: v) { return .stash }
        if let hit = current { return .snap(hit.area, hit.screen) }
        if settings.flingEnabled, !bypass, let v = releaseVelocity() { return .fling(v) }
        return .none
    }

    private func mouseUp() {
        defer { reset() }
        guard state == .moving, let w = window else { return }
        let drop = resolveDrop(w)
        Debug.log("snap: mouseUp → \(drop)")
        let slide = SlideOverController.shared
        // Let the app finish its own drag before we reposition.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            switch drop {
            case .slideOver(let side, let screen):
                slide.dock(w, side: side, screen: screen)
            case .stash:
                slide.stash()
            case .snap(let area, let screen):
                if slide.isDocked(w) { slide.release(restore: false) }
                WindowManager.shared.place(w, unit: area.target, on: screen)
            case .fling(let v):
                if slide.isDocked(w) { slide.release(restore: false) }
                Self.fling(w, velocity: v)
            case .none:
                // Dragged away from its edge: it's an ordinary window again.
                if slide.isDocked(w) { slide.release(restore: false) }
            }
        }
    }

    // MARK: Dwell

    /// The dwell zone under the pointer: the middle third of the left or right edge.
    private func dwellZone(at p: CGPoint) -> DwellZone? {
        guard settings.slideOverEnabled, let screen = NSScreen.screen(containingAX: p) else { return nil }
        let f = screen.axFrame, vf = screen.axVisibleFrame
        let t = CGFloat(settings.snapThreshold)
        let tl = max(t, vf.minX - f.minX + t), tr = max(t, f.maxX - vf.maxX + t)
        let rel = (p.y - f.minY) / f.height
        guard rel > 0.3, rel < 0.7 else { return nil }
        if p.x - f.minX <= tl { return .edgeMiddle(.left) }
        if f.maxX - 1 - p.x <= tr { return .edgeMiddle(.right) }
        return nil
    }

    /// Starts the dwell timer when the pointer enters a zone; the pointer often
    /// rests without any drag events, so the timer re-evaluates the preview itself.
    private func updateDwell(at p: CGPoint) {
        let zone = dwellZone(at: p)
        guard zone != dwellZone else { return }
        dwellZone = zone
        dwellReached = false
        dwellWork?.cancel()
        guard zone != nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state == .moving, self.dwellZone == zone else { return }
            self.dwellReached = true
            self.updatePreview(at: self.lastPoint, flags: self.lastFlags)
        }
        dwellWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.slideOverDwell, execute: w)
    }

    private func reset() {
        state = .idle
        dwellWork?.cancel()
        dwellZone = nil
        dwellReached = false
        samples.removeAll()
        suppressUntilLeave = false
        window = nil
        windowID = nil
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
        // A reached dwell target shows its own, differently labelled preview.
        if dwellReached, case .edgeMiddle(let side)? = dwellZone, !settings.disableSnapModifier.matches(flags),
           let screen = NSScreen.screen(containingAX: p), let size = window?.frame?.size {
            current = nil
            PreviewOverlay.shared.show(axFrame: SlideOverController.dockFrame(for: size, side: side, screen: screen),
                                       label: "侧拉", style: .slideOver)
            return
        }
        guard settings.snapEnabled, !settings.disableSnapModifier.matches(flags),
              let screen = NSScreen.screen(containingAX: p), let area = Self.area(at: p, on: screen, settings: settings) else {
            suppressUntilLeave = false
            current = nil
            PreviewOverlay.shared.hide()
            return
        }
        if suppressUntilLeave { return }
        current = (area, screen)
        PreviewOverlay.shared.show(axFrame: WindowManager.shared.targetFrame(unit: area.target, screen: screen), label: nil, style: .snap)
    }

    // MARK: Fling

    /// Pointer velocity (pt/s, AX space) over the last 50ms, if it was a throw.
    private func releaseVelocity(minimum: CGFloat = SnapController.flingSpeed) -> CGVector? {
        let now = ProcessInfo.processInfo.systemUptime
        let recent = samples.filter { now - $0.t <= 0.05 }
        guard let first = recent.first, let last = recent.last, last.t - first.t > 0.008 else { return nil }
        let dt = CGFloat(last.t - first.t)
        let v = CGVector(dx: (last.p.x - first.p.x) / dt, dy: (last.p.y - first.p.y) / dt)
        return hypot(v.dx, v.dy) >= minimum ? v : nil
    }

    private static let flingSpeed: CGFloat = 1500

    /// Debug builds of the behaviour only (PanesDebug on): replay a fling on the
    /// focused window from `dx,dy` in a distributed notification, so the direction
    /// mapping and glide can be checked without a real hand on a mouse.
    static func installDebugHook() {
        guard Debug.enabled else { return }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.thomas.panes.debug.fling"),
                                                            object: nil, queue: .main) { note in
            guard let parts = (note.object as? String)?.split(separator: ",").compactMap({ Double($0) }), parts.count == 2,
                  let w = AXWindow.focused() else { return }
            fling(w, velocity: CGVector(dx: parts[0], dy: parts[1]))
        }
    }

    /// Up = undo a gesture fill, down = fill, sideways = half, diagonal = that corner.
    /// The window glides there.
    private static func fling(_ w: AXWindow, velocity v: CGVector) {
        let angle = atan2(-v.dy, v.dx) * 180 / .pi      // 0 = right, 90 = up (AX y grows down)
        let wm = WindowManager.shared
        let p: Placement?
        switch angle {
        case 67.5..<112.5:
            p = GesturePlacements.shared.gestureFilled(w) ? Placement(kind: .unfill, title: "还原") : nil
        case -112.5 ..< -67.5: p = wm.fill(w)
        case -22.5..<22.5: p = wm.half(w, side: .right)
        case 157.5...180, -180 ..< -157.5: p = wm.half(w, side: .left)
        case 22.5..<67.5: p = wm.corner(w, side: .right, top: true)
        case 112.5..<157.5: p = wm.corner(w, side: .left, top: true)
        case -67.5 ..< -22.5: p = wm.corner(w, side: .right, top: false)
        default: p = wm.corner(w, side: .left, top: false)
        }
        guard let p else { return }
        Debug.log("fling: \(Int(angle))° → \(p.title)")
        wm.execute(p, on: w, animated: true)
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
