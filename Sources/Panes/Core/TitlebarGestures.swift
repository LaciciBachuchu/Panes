// Title-bar gestures: two-finger swipes, mouse-wheel notches and pinches over a
// window's title bar arrange that window; nothing happens until you let go.
// Approach adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
//   docs/gestures.md "怎么判定" — direction after 10pt, switching needs 1.25×, armed at
//     56pt, release projects the last 50ms of velocity (× 0.099s), a quick flick of 18pt+
//     counts, corners need the side swipe armed then 44pt mostly-vertical travel;
//     pinch armed at 0.22, ignored under 0.03;
//   "为什么只旁听" — listen only: swipes via a passive global monitor (apps still get
//     them), pinches via a listen-only tap on its own thread (passive monitors never
//     see magnify events);
//   "和 App 自己的手势共存" — scrollable content keeps the whole gesture; tabs, address
//     bars and the like keep horizontal swipes, and a gesture that starts sideways there
//     is left to the app entirely;
//   docs/input-devices.md / prototype/App/ScrollTap.swift — a wheel notch burst counts
//     as one swipe (three notches here).

import AppKit

final class TitlebarGestures {
    static let shared = TitlebarGestures()

    enum Dir { case up, down, left, right
        var horizontal: Bool { self == .left || self == .right }
    }

    private struct Track {
        var window: AXWindow
        var frame: CGRect
        var bar: CGFloat
        var anchor: CGPoint
        var horizontalOwnedByApp: Bool
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var dir: Dir?
        var armedAt: CGPoint?            // (dx, dy) when a side swipe first reached 56pt
        var samples: [(t: TimeInterval, dx: CGFloat, dy: CGFloat)] = []
        var cache: [String: Placement] = [:]
    }

    private static let decide: CGFloat = 10
    private static let armed: CGFloat = 56
    private static let cornerTurn: CGFloat = 44
    private static let flick: CGFloat = 18

    private var scrollMonitor: Any?
    private var pinchTap: ListenOnlyTap?
    private var track: Track?
    /// A gesture whose start didn't qualify: ignore the rest of it.
    private var ignoringGesture = false

    private struct Wheel { var window: AXWindow?; var frame: CGRect; var bar: CGFloat; var anchor: CGPoint
        var dir: Dir; var count: Int; var last: Date; var owned: Bool }
    private var wheel: Wheel?
    /// An unfinished wheel burst (fewer than three notches) times out quietly.
    private var wheelTimeout: DispatchWorkItem?

    private struct Pinch { var window: AXWindow; var anchor: CGPoint; var total: CGFloat = 0 }
    private var pinch: Pinch?
    private var ignoringPinch = false

    private var settings: SettingsData { Settings.shared.data }

    // MARK: Install / remove

    /// Installs exactly the listeners the switches ask for; removes the rest.
    func applySettings() {
        let wantScroll = settings.trackpadGesturesEnabled || settings.scrollWheelGesturesEnabled
        if wantScroll, scrollMonitor == nil {
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.scroll(e) }
        } else if !wantScroll, let m = scrollMonitor {
            NSEvent.removeMonitor(m)
            scrollMonitor = nil
            cancelTrack()
        }
        if settings.trackpadGesturesEnabled {
            if pinchTap == nil {
                pinchTap = ListenOnlyTap(mask: (1 << 29) | (1 << 30)) { [weak self] m, phase in self?.magnify(m, phase) }
            }
        } else {
            pinchTap = nil
            pinch = nil
        }
    }

    // MARK: Scroll events

    private func scroll(_ e: NSEvent) {
        Debug.log("scroll phase=\(e.phase.rawValue) momentum=\(e.momentumPhase.rawValue) precise=\(e.hasPreciseScrollingDeltas) d=(\(e.scrollingDeltaX),\(e.scrollingDeltaY))")
        guard e.momentumPhase.isEmpty else { return }
        if e.phase.isEmpty {
            if settings.scrollWheelGesturesEnabled, !e.hasPreciseScrollingDeltas { wheelNotch(e) }
            return
        }
        guard settings.trackpadGesturesEnabled else { return }
        if e.phase.contains(.began) {
            begin()
        }
        guard !ignoringGesture, track != nil else {
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) { ignoringGesture = false }
            return
        }
        if e.phase.contains(.changed) || e.phase.contains(.began) {
            track!.dx += e.scrollingDeltaX
            track!.dy += e.scrollingDeltaY
            let now = ProcessInfo.processInfo.systemUptime
            track!.samples.append((now, track!.dx, track!.dy))
            track!.samples.removeAll { now - $0.t > 0.08 }
            update()
        }
        if e.phase.contains(.ended) {
            end()
        } else if e.phase.contains(.cancelled) {
            cancelTrack()
        }
    }

    /// A gesture starts: is the pointer on a title bar we may act on?
    private func begin() {
        track = nil
        ignoringGesture = true
        let p = Geometry.mouseAX
        guard Titlebar.mayBeTitlebar(p), let hit = Titlebar.hit(at: p, allowControls: true),
              !Settings.shared.isExcluded(hit.window.bundleID) else { return }
        // Buttons and pop-ups in the title bar keep vertical meaning only through us;
        // horizontal swipes there belong to the app.
        let owned = hit.chain.contains { Titlebar.usesHorizontalSwipes($0.role, subrole: $0.subrole) }
        track = Track(window: hit.window, frame: hit.frame, bar: hit.barHeight, anchor: p, horizontalOwnedByApp: owned)
        ignoringGesture = false
    }

    private func update() {
        guard var t = track else { return }
        let ax = abs(t.dx), ay = abs(t.dy)
        if t.dir == nil {
            guard max(ax, ay) >= Self.decide else { return }
            t.dir = ax > ay ? (t.dx > 0 ? .right : .left) : (t.dy > 0 ? .down : .up)
            if t.dir!.horizontal && t.horizontalOwnedByApp {
                // The app swipes sideways here (tabs, address bar): the whole gesture is theirs.
                track = nil
                ignoringGesture = true
                GestureHUD.shared.cancel()
                return
            }
        } else if t.armedAt == nil {
            // Changing direction takes 1.25× the travel, so ~45° doesn't flicker.
            if t.dir!.horizontal, ay > 1.25 * ax, ay >= Self.decide {
                t.dir = t.dy > 0 ? .down : .up
            } else if !t.dir!.horizontal, ax > 1.25 * ay, ax >= Self.decide, !t.horizontalOwnedByApp {
                t.dir = t.dx > 0 ? .right : .left
            }
        }
        track = t
        guard let (placement, progress, reversed, symbol) = intent() else {
            GestureHUD.shared.cancel()
            return
        }
        GestureHUD.shared.update(title: placement?.title ?? "", symbol: symbol, progress: progress, reversed: reversed,
                                 anchor: CGPoint(x: t.anchor.x, y: t.frame.minY + t.bar))
    }

    /// What letting go now would do, and how far along it is.
    private func intent(projected extra: CGFloat = 0) -> (Placement?, CGFloat, Bool, String)? {
        guard var t = track, let dir = t.dir else { return nil }
        switch dir {
        case .left, .right:
            let travel = (dir == .right ? t.dx : -t.dx) + extra
            if travel >= Self.armed, t.armedAt == nil { t.armedAt = CGPoint(x: t.dx, y: t.dy) }
            if travel < Self.armed * 0.8 { t.armedAt = nil }
            if RollUpController.shared.isRolled(t.window) { return nil }
            let side: Side = dir == .left ? .left : .right
            // Turning after an armed side swipe: corner on that side.
            if let a = t.armedAt {
                let vy = t.dy - a.y, hx = t.dx - a.x
                if abs(vy) >= Self.cornerTurn, abs(vy) >= 1.2 * abs(hx) {
                    let top = vy < 0
                    let key = "corner-\(side)-\(top)"
                    if t.cache[key] == nil { t.cache[key] = WindowManager.shared.corner(t.window, side: side, top: top) }
                    track = t
                    let sym = top ? (side == .left ? "rectangle.inset.topleft.filled" : "rectangle.inset.topright.filled")
                                  : (side == .left ? "rectangle.inset.bottomleft.filled" : "rectangle.inset.bottomright.filled")
                    return (t.cache[key], 1, side == .left, sym)
                }
            }
            track = t
            guard travel >= Self.decide else { return nil }
            let key = "side-\(side)"
            if t.cache[key] == nil { t.cache[key] = WindowManager.shared.ladder(t.window, side: side); track = t }
            return (t.cache[key], travel / Self.armed, side == .left,
                    side == .left ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled")
        case .up, .down:
            let travel = (dir == .down ? t.dy : -t.dy) + extra
            guard travel >= Self.decide else { return nil }
            let key = dir == .down ? "down" : "up"
            if t.cache[key] == nil {
                t.cache[key] = dir == .down ? downPlacement(t.window) : upPlacement(t.window)
                track = t
            }
            guard let p = t.cache[key] else { return nil }
            let sym = p.kind == .rollUp ? "rectangle.topthird.inset.filled"
                    : (p.kind == .unfill ? "arrow.uturn.backward" : "rectangle.inset.filled")
            return (p, travel / Self.armed, false, sym)
        }
    }

    /// Down on a rolled-up window unrolls it; otherwise down fills.
    private func downPlacement(_ w: AXWindow) -> Placement? {
        if RollUpController.shared.isRolled(w) { return Placement(kind: .unroll, title: "展开") }
        return WindowManager.shared.fill(w)
    }

    /// Up: undo a gesture fill first, else roll up (when roll-up is on).
    private func upPlacement(_ w: AXWindow) -> Placement? {
        if RollUpController.shared.isRolled(w) { return nil }
        if GesturePlacements.shared.gestureFilled(w) { return Placement(kind: .unfill, title: "还原") }
        guard settings.rollUpEnabled else { return nil }
        return Placement(kind: .rollUp, title: "卷起")
    }

    private func end() {
        defer { track = nil }
        guard let t = track, let dir = t.dir else { GestureHUD.shared.cancel(); return }
        // Project where the fingers were heading (velocity over the last 50ms).
        var extra: CGFloat = 0
        if let first = t.samples.first, let last = t.samples.last, last.t - first.t > 0.005 {
            let dt = CGFloat(last.t - first.t)
            let v: CGFloat
            switch dir {
            case .left: v = -(last.dx - first.dx) / dt
            case .right: v = (last.dx - first.dx) / dt
            case .up: v = -(last.dy - first.dy) / dt
            case .down: v = (last.dy - first.dy) / dt
            }
            extra = v * 0.099
        }
        let travel: CGFloat = dir.horizontal ? (dir == .right ? t.dx : -t.dx) : (dir == .down ? t.dy : -t.dy)
        guard let (placement, progress, _, _) = intent(projected: extra), let p = placement,
              progress >= 1 || (travel >= Self.flick && travel + extra >= Self.armed) else {
            GestureHUD.shared.cancel()
            return
        }
        WindowManager.shared.execute(p, on: t.window, animated: false)
        GestureHUD.shared.finish()
    }

    private func cancelTrack() {
        track = nil
        GestureHUD.shared.cancel()
    }

    // MARK: Mouse wheel

    /// Three notches in one direction over a title bar make one swipe.
    private func wheelNotch(_ e: NSEvent) {
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        guard abs(dx) >= 0.1 || abs(dy) >= 0.1 else { return }
        let dir: Dir = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
        // Line-based wheel events: one line per notch, more when the wheel spins fast.
        let notches = max(1, Int(max(abs(dx), abs(dy)).rounded()))
        let now = Date()
        if var w = wheel, now.timeIntervalSince(w.last) < 0.6, w.dir == dir {
            w.last = now
            guard let win = w.window, !(dir.horizontal && w.owned) else { wheel = w; return }
            w.count += notches
            wheel = w
            wheelProgress(w, win)
        } else {
            // A new burst: check the title bar once.
            let p = Geometry.mouseAX
            var w = Wheel(window: nil, frame: .zero, bar: 0, anchor: p, dir: dir, count: notches, last: now, owned: false)
            if Titlebar.mayBeTitlebar(p), let hit = Titlebar.hit(at: p, allowControls: true),
               !Settings.shared.isExcluded(hit.window.bundleID) {
                w.window = hit.window; w.frame = hit.frame; w.bar = hit.barHeight
                w.owned = hit.chain.contains { Titlebar.usesHorizontalSwipes($0.role, subrole: $0.subrole) }
            }
            wheel = w
            Debug.log("wheel: burst \(dir) on \(w.window?.bundleID ?? "no title bar")")
            if let win = w.window, !(dir.horizontal && w.owned) { wheelProgress(w, win) }
        }
    }

    private func wheelProgress(_ w: Wheel, _ win: AXWindow) {
        wheelTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.wheel = nil
            GestureHUD.shared.cancel()
        }
        wheelTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: timeout)
        let p: Placement?
        let symbol: String
        switch w.dir {
        case .up: p = upPlacement(win); symbol = "rectangle.topthird.inset.filled"
        case .down: p = downPlacement(win); symbol = "rectangle.inset.filled"
        case .left, .right:
            if RollUpController.shared.isRolled(win) { return }
            let side: Side = w.dir == .left ? .left : .right
            p = WindowManager.shared.ladder(win, side: side)
            symbol = side == .left ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled"
        }
        guard let p else { return }
        GestureHUD.shared.update(title: p.title, symbol: symbol, progress: CGFloat(min(w.count, 3)) / 3, reversed: w.dir == .left,
                                 anchor: CGPoint(x: w.anchor.x, y: w.frame.minY + w.bar))
        if w.count >= 3 {
            wheelTimeout?.cancel()
            WindowManager.shared.execute(p, on: win, animated: false)
            GestureHUD.shared.finish()
            wheel?.count = 0      // keep scrolling the same way to climb the ladder
        }
    }

    // MARK: Pinch

    private func magnify(_ m: CGFloat, _ phase: NSEvent.Phase) {
        guard settings.trackpadGesturesEnabled else { return }
        if phase.contains(.began) {
            pinch = nil
            ignoringPinch = true
            let p = Geometry.mouseAX
            guard Titlebar.mayBeTitlebar(p), let hit = Titlebar.hit(at: p, allowControls: true),
                  !Settings.shared.isExcluded(hit.window.bundleID) else { return }
            pinch = Pinch(window: hit.window, anchor: CGPoint(x: p.x, y: hit.frame.minY + hit.barHeight))
            ignoringPinch = false
        }
        guard !ignoringPinch, var pn = pinch else { return }
        if phase.contains(.changed) || phase.contains(.began) {
            pn.total += m
            pinch = pn
            if pn.total > 0.03 {
                GestureHUD.shared.update(title: "铺满", symbol: "rectangle.inset.filled", progress: pn.total / 0.22,
                                         reversed: false, anchor: pn.anchor)
            } else if pn.total < -0.03 {
                let can = GesturePlacements.shared.canUndo(pn.window)
                GestureHUD.shared.update(title: can ? "撤销上次摆放" : "没有可撤销的摆放", symbol: "arrow.uturn.backward",
                                         progress: can ? -pn.total / 0.22 : 0, reversed: false, anchor: pn.anchor)
            } else {
                GestureHUD.shared.cancel()
            }
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            defer { pinch = nil }
            guard phase.contains(.ended) else { GestureHUD.shared.cancel(); return }
            if pn.total >= 0.22, let p = WindowManager.shared.fill(pn.window) {
                WindowManager.shared.execute(p, on: pn.window, animated: false)
                GestureHUD.shared.finish()
            } else if pn.total <= -0.22, GesturePlacements.shared.canUndo(pn.window) {
                WindowManager.shared.execute(Placement(kind: .undo, title: "撤销"), on: pn.window, animated: false)
                GestureHUD.shared.finish()
            } else {
                GestureHUD.shared.cancel()
            }
        }
    }
}

/// A listen-only event tap on its own thread that forwards magnify gestures to the
/// main thread. It never blocks or alters events; removed on deinit.
final class ListenOnlyTap {
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    fileprivate let handler: (CGFloat, NSEvent.Phase) -> Void

    init?(mask: CGEventMask, handler: @escaping (CGFloat, NSEvent.Phase) -> Void) {
        self.handler = handler
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: listenTapCallback, userInfo: ref) else { return nil }
        self.port = port
        let t = Thread { [weak self] in
            let src = CFMachPortCreateRunLoopSource(nil, port, 0)
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        t.name = "panes.pinch"
        t.start()
    }

    fileprivate func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    deinit {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}

private func listenTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ListenOnlyTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        return Unmanaged.passUnretained(event)
    }
    if let ns = NSEvent(cgEvent: event), ns.type == .magnify {
        let m = ns.magnification, phase = ns.phase
        DispatchQueue.main.async { tap.handler(m, phase) }
    }
    return Unmanaged.passUnretained(event)
}
