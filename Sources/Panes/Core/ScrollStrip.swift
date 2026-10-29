// Scroll strip ("卷轴", niri-style scrolling layout): the windows on a screen become
// one horizontal strip of full-height columns. The part longer than the screen waits
// off screen with a sliver showing at the edge. Two-finger swipes on a column's title
// bar move the whole strip with the fingers and coast to the nearest column on release;
// resting on a sliver shows that window; pinching out opens an overview.
// Adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// prototype/Core/ScrollStrip.swift + App/ScrollStripRun/Overview/Peek — column widths
// from ⅓ / ½ / ⅔ / full, a 10pt sliver for parked columns, release projection with the
// 0.998/ms deceleration rate then snap to a column edge, overview scaled to at most ½,
// peek card next to the sliver. Horizontal only (macOS keeps title bars on screen
// vertically).

import AppKit

final class ScrollStrip {
    static let shared = ScrollStrip()

    private struct Column {
        let id: CGWindowID
        let window: AXWindow
        var width: CGFloat
        /// The window's own height when it won't stretch to the full column; nil = full height.
        var height: CGFloat?
    }

    private static let sliver: CGFloat = 10
    private static let presets: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3, 1]

    private var columns: [Column] = []
    private var originals: [CGWindowID: CGRect] = [:]
    /// Every window that has been in the strip, kept for restoring even after it left the list.
    private var originalWindows: [CGWindowID: AXWindow] = [:]
    private var screen: NSScreen?
    private var area: CGRect = .zero
    private(set) var offset: CGFloat = 0
    private var pendingApply = false
    private var animation: Timer?
    private var watchers: [pid_t: AXWatch] = [:]
    /// A column that left (minimized, put away): the column it sat after (0 = first).
    private var returnAfter: [CGWindowID: CGWindowID] = [:]
    /// The strip column you were last in (new windows open next to it).
    private var lastFocusedColumn: CGWindowID?
    /// You scrolled: once the strip stops, the column in front takes focus.
    private var focusOnRest = false
    /// The column the strip just focused itself (switching to it mustn't slide it).
    private var autoFocused: (id: CGWindowID, at: Date)?
    /// Keeps macOS from napping or coalescing Panes' timers while a strip is on.
    private var activity: NSObjectProtocol?
    /// Closing a window often only orders it out, with no notice: look twice a second.
    private var goneCheck: Timer?
    private var padFollow: Timer?
    private var activationObserver: Any?
    private var launchObserver: Any?
    private var dockClickMonitor: Any?
    private var peek: PeekCard?
    private var peekWork: DispatchWorkItem?
    private var overview: StripOverview? { didSet { overviewUp.value = overview != nil } }
    /// Whether the overview is up, readable from the ⌃↑ tap's thread.
    private let overviewUp = LockedFlag()
    /// The Space (and display) the strip lives on.
    private var homeSpace: Int?
    private var homeDisplay: String?
    private var spaceObserver: Any?

    /// The strip's own Space is showing (Mission Control can claim it is: don't let
    /// that alone change the strip).
    private var onHomeSpace: Bool { homeSpace == nil || Spaces.current(on: homeDisplay) == homeSpace }

    /// Left the strip's Space mid-overview or mid-slide: nothing may stay stepped
    /// aside or half-done there. Close the overview / finish the slide now.
    private func spaceChanged() {
        guard isActive, !onHomeSpace else { return }
        if let o = overview {
            Debug.log("strip: left the strip's Space with the overview open: closing it")
            overview = nil
            o.close()
            placeWindows()
        }
        if proxy != nil || coverPending != nil || animation?.isValid == true {
            animation?.invalidate()
            stopSlide()
            wheelIdle?.cancel()
            wheelTarget = nil
            offset = clamp(offset)
            endMotion()
        }
    }
    /// ⌃↑ opens the strip overview instead of Mission Control, only while a strip is on.
    private var missionControlKey: KeyIntercept?

    var isActive: Bool { !columns.isEmpty }
    /// The screen the strip is on, while it's on.
    var activeScreen: NSScreen? { isActive ? screen : nil }
    private var gap: CGFloat { CGFloat(Settings.shared.data.gap) }

    func contains(_ w: AXWindow) -> Bool {
        guard let id = w.cgWindowID else { return false }
        return columns.contains { $0.id == id }
    }

    func applySettings() {
        if !Settings.shared.data.scrollStripEnabled { exit() }
        installDebugHook()
    }

    private var debugHook: Any?

    /// Debug mode only: open the overview (the pinch that opens it can't be faked).
    private func installDebugHook() {
        guard Debug.enabled, debugHook == nil else { return }
        debugHook = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.thomas.panes.debug.stripOverview"), object: nil, queue: .main
        ) { [weak self] _ in self?.showOverview() }
        // Debug: where the Dock is and where the scroll pad would go.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.thomas.panes.debug.padPlacement"), object: nil, queue: .main
        ) { _ in
            for screen in NSScreen.screens {
                Debug.log("pad: dock icons \(String(describing: ScrollPad.dockIconsFrame())) → pad \(ScrollPad.placement(on: screen)) on \(screen.localizedName)")
            }
        }
        // Debug: a burst of 8 wheel ticks of `delta` points, 30ms apart, like a wheel spin.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.thomas.panes.debug.stripWheel"), object: nil, queue: .main
        ) { [weak self] note in
            guard let d = (note.object as? String).flatMap(Double.init) else { return }
            for i in 0..<8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i)) { self?.wheel(by: CGFloat(d)) }
            }
        }
    }

    // MARK: Enter / exit

    /// Shortcut: arrange the current screen as a strip, or put everything back.
    func toggle() {
        guard Settings.shared.data.scrollStripEnabled else { NSSound.beep(); return }
        if isActive { exit() } else { enter() }
    }

    private func enter() {
        let focused = AXWindow.focused()
        guard let s = focused?.frame.flatMap({ NSScreen.screen(forAX: $0) }) ?? NSScreen.screen(containingAX: Geometry.mouseAX) ?? NSScreen.main else { return }
        let found = Self.windows(on: s)
        guard found.count >= 1 else { NSSound.beep(); return }
        screen = s
        area = s.axVisibleFrame
        originals = Dictionary(uniqueKeysWithValues: found.map { ($0.0, $0.2) })
        originalWindows = Dictionary(uniqueKeysWithValues: found.map { ($0.0, $0.1) })
        // Written before anything moves, so a crash can't strand a window off screen.
        ParkedJournal.record("strip", found.map { ($0.1, $0.2) })
        // Pictures now, while every window is still where it can be seen: parked ones
        // can't be captured later.
        if WindowCapture.hasPermission {
            for (id, _, _) in found { if let img = WindowCapture.snapshot(id) { snapshots[id] = img } }
        }
        // Columns in the order the windows were last used (the window server lists them
        // front to back): the one in use on the left, then the one before it, and so
        // on. Widths snap to the presets.
        columns = found.map { id, w, f in
            let share = Self.presets.min { abs($0 - f.width / area.width) < abs($1 - f.width / area.width) }!
            return Column(id: id, window: w, width: (area.width * share).rounded())
        }
        let focusIndex = columns.firstIndex { $0.id == focused?.cgWindowID } ?? 0
        lastFocusedColumn = columns[focusIndex].id
        offset = clamp(start(of: focusIndex))
        applyFrames()
        fitColumnsToWindows()
        for c in columns { watch(c) }
        installMonitors()
        // The pictures from before were at the windows' old sizes: retake them once
        // the apps have laid out at their column sizes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshSnapshots()
            self?.warmIcons()
        }
        let p = ScrollPad(screen: s)
        p.layout = { [weak self] in self?.padModel() ?? ([], 0, 1) }
        p.onDrag = { [weak self] dx in self?.padDragged(dx) }
        p.onRelease = { [weak self] v in self?.padReleased(v) }
        p.onDoubleClick = { [weak self] in self?.toggleOverview() }
        p.onWheel = { [weak self] d in
            let s = Settings.shared.data
            self?.wheel(by: d * CGFloat(s.stripScrollSpeed) * (s.stripReverseScroll ? -1 : 1))
        }
        pad = p
        p.update(offset: offset)
        p.orderFrontRegardless()
        // Only on the strip's own Space: on another desktop or a full-screen app ⌃↑
        // stays Mission Control. Asked at the press, by Space ID. An open overview is
        // always closed by ⌃↑, wherever you are.
        homeDisplay = Spaces.displayID(of: s)
        homeSpace = Spaces.current(on: homeDisplay)
        let display = homeDisplay, home = homeSpace, overviewUp = overviewUp
        missionControlKey = KeyIntercept(keyCode: 126, flags: .maskControl,
                                         when: { overviewUp.value || home == nil || Spaces.current(on: display) == home }) { [weak self] in
            self?.toggleOverview()
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.spaceChanged() }
        HotKeyManager.shared.reload()
        // The strip's screen has no split dividers: its columns aren't a split.
        SplitDividers.shared.soon()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Scroll strip follows input")
        Debug.log("strip: \(columns.count) columns, total \(Int(totalWidth))pt")
        GestureHUD.shared.flash("卷轴：\(columns.count) 列", symbol: "rectangle.split.3x1", anchor: CGPoint(x: area.midX, y: area.minY + 40))
    }

    func exit() {
        guard isActive else { return }
        animation?.invalidate()
        wheelIdle?.cancel()
        wheelTarget = nil
        cancelCover()
        slideCount += 1
        slideEnds = nil
        focusOnRest = false
        proxy?.close(); proxy = nil
        fading?.close(); fading = nil
        pad?.orderOut(nil); pad = nil
        missionControlKey = nil
        if let o = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        spaceObserver = nil
        snapshots = [:]
        closePeek()
        overview?.close(); overview = nil
        // A stow still under way must land before the windows go back.
        _ = moving?.wait(timeout: .now() + 0.5)
        moving = nil
        // Everything that was ever in the strip goes back, not only what's still listed.
        for (id, f) in originals {
            guard let w = originalWindows[id], AXWindow.serverFrame(of: id) != nil else { continue }
            w.setFrame(f)
        }
        columns = []
        originals = [:]
        originalWindows = [:]
        watchers = [:]
        returnAfter = [:]
        adoptWork?.cancel()
        resizeWork?.cancel()
        iconCache = [:]
        removeMonitors()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        SplitDividers.shared.soon()
        ParkedJournal.clear("strip")
        HotKeyManager.shared.reload()
    }

    /// Visible standard windows on a screen (id, window, frame).
    private static func windows(on screen: NSScreen) -> [(CGWindowID, AXWindow, CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var byPid: [pid_t: [AXWindow]] = [:]
        var out: [(CGWindowID, AXWindow, CGRect)] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width >= 160, r.height >= 100,
                  NSScreen.screen(forAX: r) == screen else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            guard app?.activationPolicy == .regular, !Settings.shared.isExcluded(app?.bundleIdentifier) else { continue }
            if byPid[pid] == nil { byPid[pid] = AXWindow.windows(of: pid) }
            guard let w = byPid[pid]?.first(where: { $0.cgWindowID == id }), w.isStandard, !w.isMinimized,
                  !w.isFullScreen, let f = w.frame else { continue }
            out.append((id, w, f))
        }
        return out
    }

    // MARK: Geometry

    private var totalWidth: CGFloat { columns.reduce(0) { $0 + $1.width } }
    private func start(of i: Int) -> CGFloat { columns.prefix(i).reduce(0) { $0 + $1.width } }
    private var maxOffset: CGFloat { max(0, totalWidth - area.width) }
    private func clamp(_ o: CGFloat) -> CGFloat { min(max(o, 0), maxOffset) }

    /// Where column i sits at an offset; columns fully off screen park at that edge
    /// with a sliver showing.
    private func frame(of i: Int, at o: CGFloat) -> CGRect {
        let c = columns[i]
        var x = area.minX + start(of: i) - o
        if x + c.width <= area.minX + Self.sliver { x = area.minX - c.width + Self.sliver }
        else if x >= area.maxX - Self.sliver { x = area.maxX - Self.sliver }
        return slot(x: x, column: c)
    }

    /// A column's window rect at left edge x: full height unless the window keeps its own.
    private func slot(x: CGFloat, column c: Column) -> CGRect {
        let full = CGRect(x: x, y: area.minY, width: c.width, height: area.height).insetBy(dx: gap / 2, dy: gap > 0 ? gap : 0)
        guard let h = c.height else { return full }
        return CGRect(x: full.minX, y: full.minY, width: full.width, height: min(h, full.height))
    }

    /// Windows don't always take the size asked for: fixed-size panels stay small,
    /// minimum sizes keep others wider than their slot. Read back what each one
    /// actually took and size its column to that, so neighbours never overlap and no
    /// picture is stretched or squeezed.
    /// The same goes for a window you resize yourself: its column takes the new size
    /// and the others move over, each keeping its own width.
    private func fitColumnsToWindows() {
        var changed = false
        var widened: [(Int, CGFloat)] = []      // column, how far its left edge moved
        let full = area.height - (gap > 0 ? 2 * gap : 0)      // a full-height slot (see slot(x:column:))
        for i in columns.indices {
            let want = frame(of: i, at: offset)
            guard let got = columns[i].window.frame else { continue }
            if abs(got.width - want.width) > 3 {
                columns[i].width = got.width + gap
                changed = true
                if !isParked(i, at: offset) { widened.append((i, want.minX - got.minX)) }
            }
            if got.height < want.height - 4 {
                columns[i].height = got.height
                changed = true
            } else if let h = columns[i].height, got.height > h + 4 {
                // Made taller again: back to full height once it reaches it.
                columns[i].height = got.height >= full - 4 ? nil : got.height
                changed = true
            }
        }
        if changed {
            // One window resized from its left edge: it stays where it was put, and the
            // strip shifts around it instead of pushing it back.
            if widened.count == 1, abs(widened[0].1) > 3 { offset += widened[0].1 }
            offset = clamp(offset)
            applyFrames()
            pad?.update(offset: offset)
        }
    }

    private var resizeWork: DispatchWorkItem?

    /// A strip window was resized (by you, or an app): follow it once the drag is over.
    private func windowResized() {
        resizeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            // Still dragging, or the strip is moving: look again shortly.
            if NSEvent.pressedMouseButtons & 1 != 0 || self.proxy != nil || self.coverPending != nil || self.overview != nil || self.moving != nil {
                self.windowResized()
                return
            }
            self.fitColumnsToWindows()
        }
        resizeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    private func isParked(_ i: Int, at o: CGFloat) -> Bool {
        let x = area.minX + start(of: i) - o
        return x + columns[i].width <= area.minX + Self.sliver || x >= area.maxX - Self.sliver
    }

    /// Full frames (size too), on this thread: for when columns change size.
    private func applyFrames() {
        _ = moving?.wait(timeout: .now() + 0.3)
        for i in columns.indices { columns[i].window.setFrameUnclamped(frame(of: i, at: offset)) }
        updateEdgeSensors()
    }

    /// Positions only (cheap), coalesced to once per runloop pass, while scrolling.
    private func applyPositions() {
        guard !pendingApply else { return }
        pendingApply = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingApply = false
            for i in self.columns.indices { self.columns[i].window.setPosition(self.frame(of: i, at: self.offset).origin) }
        }
    }

    // MARK: Scrolling
    //
    // Moving every window through AX each frame is capped by how fast each app
    // answers (~30–40 moves a second). So while the strip moves, a picture of every
    // column (snapshots, refreshed after each stop) slides on top at the display's
    // frame rate; the real windows move once, when it settles. Without Screen
    // Recording it falls back to moving the real windows directly.

    private var proxy: StripProxy?
    /// The last cover, fading off the real windows after a stop.
    private var fading: StripProxy?
    private var snapshots: [CGWindowID: CGImage] = [:]
    private var wheelTarget: CGFloat?
    private var wheelIdle: DispatchWorkItem?
    private var pad: ScrollPad?

    /// Finger or pad movement (content direction): the strip follows 1:1.
    func scroll(by dx: CGFloat) {
        // The overview has the windows stepped aside: nothing moves under it.
        guard overview == nil else { return }
        animation?.invalidate()
        wheelTarget = nil
        closePeek()
        focusOnRest = true
        // Following the fingers (or catching up to them): keep heading for where they
        // are; anything else under way stops where it shows.
        if catchUpEnds.map({ $0 > Date() }) != true { stopSlide() }
        // Past the ends it moves at a third of the speed (rubber band).
        let next = offset - dx
        offset = (next < 0 || next > maxOffset) ? offset - dx / 3 : next
        beginMotion(ready: { [weak self] in self?.catchUp() })
        render()
    }

    /// The cover went up where the windows were; the fingers have moved on since the
    /// pictures were asked for. Glide there quickly instead of jumping.
    private func catchUp() {
        let d = 0.12
        catchUpEnds = Date() + d
        slide(to: offset, duration: d, curve: .out)
    }

    /// Fingers lifted with a velocity (pt/s, content direction): coast, then stop on a column edge.
    func release(velocity v: CGFloat) {
        // iOS-style projection with deceleration rate 0.998 per ms.
        let projected = offset - v / 1000 * 0.998 / (1 - 0.998)
        animate(to: settledTarget(projected))
    }

    /// Smooth, stepless wheel: each tick moves a target, the strip eases after it,
    /// and once the wheel rests it settles on the nearest column.
    func wheel(by delta: CGFloat) {
        guard overview == nil else { return }
        closePeek()
        focusOnRest = true
        if wheelTarget == nil { stopSlide() }
        let base = wheelTarget ?? offset
        wheelTarget = min(max(base + delta, -60), maxOffset + 60)
        switch beginMotion(ready: { [weak self] in self?.chaseWheel() }) {
        case .ready: chaseWheel()
        case .pending: pad?.update(offset: wheelTarget ?? offset)
        case .none: break
        }
        if proxy == nil, coverPending == nil, animation == nil || !(animation?.isValid ?? false) {
            // No pictures: the real windows follow, frame by frame.
            animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
                guard let self, let target = self.wheelTarget else { t.invalidate(); return }
                self.offset += (target - self.offset) * 0.22
                self.render()
            }
        }
        wheelIdle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let target = self.wheelTarget else { return }
            self.wheelTarget = nil
            self.animate(to: self.settledTarget(target))
        }
        wheelIdle = w
        // Hand-turned wheels pause between notches: keep moving through the pause.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// Each notch moves the target; the pictures chase it in a short glide that the
    /// window server runs, so it stays smooth however busy Panes is.
    private func chaseWheel() {
        guard proxy != nil, let t = wheelTarget else { return }
        slide(to: t, duration: 0.22, curve: .chase)
    }

    /// One column left or right.
    func step(_ direction: Int) {
        focusOnRest = true
        let candidates = snapCandidates()
        let next = direction > 0 ? candidates.first { $0 > offset + 1 } : candidates.last { $0 < offset - 1 }
        animate(to: next ?? offset)
    }

    /// Where the strip comes to rest: wherever it is (stepless), or the nearest column
    /// edge when "停下时对齐到列" is on; never past either end.
    private func settledTarget(_ projected: CGFloat) -> CGFloat {
        Settings.shared.data.stripSnapToColumns ? snapped(projected) : clamp(projected)
    }

    /// Direct scrolling (trackpad, momentum) stopped: settle where it is.
    func settle() {
        guard isActive else { return }
        animate(to: settledTarget(offset))
    }

    /// Scrolling over a column's title bar, with the user's direction and speed.
    /// `delta` is the event's dominant-axis delta in content direction.
    func titlebarScroll(_ delta: CGFloat, precise: Bool) {
        let s = Settings.shared.data
        let sign: CGFloat = s.stripReverseScroll ? -1 : 1
        let speed = CGFloat(s.stripScrollSpeed)
        if precise {
            scroll(by: delta * speed * sign)          // fingers: 1:1 (times speed)
        } else {
            wheel(by: -delta * 40 * speed * sign)     // wheel lines: smooth easing
        }
    }

    private func snapCandidates() -> [CGFloat] {
        var c = columns.indices.map { clamp(start(of: $0)) }
        c.append(maxOffset)
        return Array(Set(c.map { $0.rounded() })).sorted()
    }

    private func snapped(_ projected: CGFloat) -> CGFloat {
        snapCandidates().min { abs($0 - projected) < abs($1 - projected) } ?? clamp(projected)
    }

    func scroll(toColumnOf id: CGWindowID, curve: Curve = .out) {
        guard let i = columns.firstIndex(where: { $0.id == id }) else { return }
        // Bring it fully on screen with the least movement.
        let s = start(of: i), w = columns[i].width
        var target = offset
        if s < offset { target = s } else if s + w > offset + area.width { target = s + w - area.width }
        animate(to: clamp(target), curve: curve)
    }

    /// Ease the offset to a target, then settle the real windows. With pictures up
    /// the glide runs in the window server (smooth under load); without, the real
    /// windows step there at 120 fps.
    private func animate(to target: CGFloat, curve: Curve = .out, caller: String = #function) {
        guard overview == nil else { return }
        Debug.log("strip: glide to \(Int(target)) from \(Int(offset)) (\(caller))")
        animation?.invalidate()
        wheelIdle?.cancel()
        wheelTarget = nil
        stopSlide()
        let duration = Self.slideDuration
        guard abs(target - offset) > 0.5 else { offset = clamp(target); endMotion(); return }
        let glide = { [weak self] in
            guard let self else { return }
            self.slide(to: target, duration: duration, curve: curve) { [weak self] in self?.endMotion() }
        }
        switch beginMotion(ready: glide) {
        case .ready: return glide()
        case .pending: pad?.update(offset: target); return
        case .none: break
        }
        let from = offset, began = Date()
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let k = min(1, Date().timeIntervalSince(began) / duration)
            let e = curve.f(k)
            self.offset = from + (target - from) * e
            self.render()
            if k >= 1 {
                t.invalidate()
                self.offset = target
                self.endMotion()
            }
        }
    }

    /// Slides (to a column, a window joining or leaving): length from Settings
    /// (卷轴 → 滑动动画时长).
    static var slideDuration: TimeInterval { max(0.05, Settings.shared.data.stripSlideDuration) }

    /// Gentle start, quick middle, gentle landing: for travelling to a window you
    /// switched to, so the trip reads as one smooth move.
    static func easeInOut(_ k: Double) -> CGFloat {
        let k = min(max(k, 0), 1)
        return CGFloat(k < 0.5 ? 4 * k * k * k : 1 - Foundation.pow(-2 * k + 2, 3) / 2)
    }

    /// Fast off the mark, then a long soft landing.
    static func ease(_ k: Double) -> CGFloat {
        k >= 1 ? 1 : CGFloat((1 - Foundation.pow(2.0, -10 * k)) / (1 - Foundation.pow(2.0, -10.0)))
    }

    /// An easing, both as a function (for the real windows stepping frame by frame)
    /// and as the window server's curve (for the pictures).
    struct Curve {
        let f: (Double) -> CGFloat
        let timing: CAMediaTimingFunction
        /// Fast off the mark, long soft landing.
        static let out = Curve(f: ScrollStrip.ease, timing: CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
        /// Gentle start, quick middle, gentle landing.
        static let inOut = Curve(f: ScrollStrip.easeInOut, timing: CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1))
        /// Chasing a wheel's target: most of the way at once, like following it frame by frame.
        static let chase = Curve(f: ScrollStrip.ease, timing: CAMediaTimingFunction(controlPoints: 0.12, 0.78, 0.3, 1))
    }

    /// Columns changed — a window joined or left. Everything slides from where it was
    /// to the new layout (a joining window from where it opened), then the real
    /// windows settle there; a joining window takes its column size while out of sight.
    private func animateLayout(from old: [CGWindowID: CGRect], to target: CGFloat, resizing: Set<CGWindowID> = []) {
        guard overview == nil else { return }
        animation?.invalidate()
        wheelIdle?.cancel()
        wheelTarget = nil
        focusOnRest = false
        stopSlide()
        cancelCover()
        proxy?.close(); proxy = nil
        offset = clamp(target)
        let end = trueFrames()
        let endByID = Dictionary(uniqueKeysWithValues: end)
        let start = columns.map { ($0.id, old[$0.id] ?? endByID[$0.id]!) }
        // The pictures in hand: a window that just closed shouldn't wait for new ones.
        guard beginMotion(at: start, fresh: false) == .ready else {
            // No pictures to slide: put the windows there directly.
            applyFrames()
            fitColumnsToWindows()
            return
        }
        slide(end, duration: Self.slideDuration, curve: .out, offset: offset) { [weak self] in self?.endMotion(resizing: resizing) }
    }

    /// Where each column truly is at the current offset (not parked), for the picture.
    private func trueFrames(at o: CGFloat? = nil) -> [(CGWindowID, CGRect)] {
        let o = o ?? offset
        return columns.indices.map { i in (columns[i].id, slot(x: area.minX + start(of: i) - o, column: columns[i])) }
    }

    // MARK: The cover (pictures standing in while the strip moves)

    private enum Cover { case ready, pending, none }

    /// Pictures being retaken for a motion that's starting (its number), and what to
    /// do once the cover is up.
    private var coverPending: Int?
    private var coverReady: (() -> Void)?
    private var coverCount = 0
    /// The glide under way in the window server (its number, when it lands).
    private var slideCount = 0
    private var slideEnds: Date?
    private var catchUpEnds: Date?

    /// How long a motion may wait for fresh pictures of the windows on screen before
    /// going ahead with the ones in hand.
    private static let freshWait: TimeInterval = 0.15
    /// How far the pictures trail the fingers, smoothing out uneven events.
    private static let followLag: TimeInterval = 0.04

    /// Motion starts: cover the strip with its picture, if every column has one.
    /// `fresh`: first retake the windows on screen (their contents may have changed
    /// since the last stop); the real windows stay put meanwhile and `ready` runs
    /// once the cover is up. Returns whether the cover is up now, coming, or not
    /// possible (no pictures: the real windows move themselves).
    @discardableResult
    private func beginMotion(at start: [(CGWindowID, CGRect)]? = nil, fresh: Bool = true, ready: (() -> Void)? = nil) -> Cover {
        if proxy != nil { return .ready }
        if coverPending != nil { coverReady = ready; return .pending }
        guard WindowCapture.hasPermission, columns.allSatisfy({ snapshots[$0.id] != nil }) else {
            Debug.log("strip: begin motion without pictures (permission=\(WindowCapture.hasPermission) snapshots=\(snapshots.count)/\(columns.count))")
            return .none
        }
        let layout = start ?? trueFrames()
        guard fresh else { raiseCover(layout); return .ready }
        coverCount += 1
        let n = coverCount, asked = Date()
        coverPending = n
        coverReady = ready
        let go: (Bool) -> Void = { [weak self] fresh in
            guard let self, self.coverPending == n else { return }
            self.coverPending = nil
            Debug.log("strip: cover up after \(Int(Date().timeIntervalSince(asked) * 1000))ms, \(fresh ? "fresh" : "pictures in hand")")
            self.raiseCover(layout)
            let r = self.coverReady
            self.coverReady = nil
            r?()
        }
        // Windows wholly on screen are quick to picture where they are; one cut by the
        // screen edge only comes whole through ScreenCaptureKit, which is slow: its
        // picture swaps in whenever it arrives.
        let shown = layout.filter { $0.1.intersects(area) }
        let whole = shown.filter { area.insetBy(dx: -1, dy: -1).contains($0.1) }.map(\.0)
        let cut = shown.map(\.0).filter { !whole.contains($0) }
        WindowCapture.captureOnScreen(whole) { [weak self] shots in
            self?.snapshots.merge(shots) { $1 }
            go(true)
        }
        WindowCapture.capture(cut) { [weak self] shots in
            guard let self, self.isActive else { return }
            self.snapshots.merge(shots) { $1 }
            self.proxy?.update(images: shots)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.freshWait) { go(false) }
        return .pending
    }

    private func cancelCover() {
        coverPending = nil
        coverReady = nil
    }

    private func raiseCover(_ layout: [(CGWindowID, CGRect)]) {
        fading?.close()
        fading = nil
        let p = StripProxy(area: area, images: snapshots)
        p.layout(layout)
        p.show()
        proxy = p
        // Once the pictures are on screen (one frame), the real windows step out from under them.
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self, weak p] in
            guard let self, let p, self.proxy === p else { return }
            self.stowWindows(done: {})
        }
    }

    /// The pictures glide to the strip at `target`, run by the window server.
    private func slide(to target: CGFloat, duration: TimeInterval, curve: Curve, then done: (() -> Void)? = nil) {
        offset = target
        slide(trueFrames(), duration: duration, curve: curve, offset: target, then: done)
    }

    private func slide(_ frames: [(CGWindowID, CGRect)], duration: TimeInterval, curve: Curve, offset target: CGFloat,
                       then done: (() -> Void)? = nil) {
        guard let proxy else { return }
        slideCount += 1
        let n = slideCount
        slideEnds = Date() + duration
        proxy.slide(frames, duration: duration, timing: curve.timing) { [weak self] in
            guard let self, self.slideCount == n else { return }
            self.slideEnds = nil
            done?()
        }
        pad?.update(offset: target, duration: duration, timing: curve.timing)
    }

    /// Where the strip shows right now: mid-glide the pictures are on their way to `offset`.
    private func shownOffset() -> CGFloat {
        guard let proxy, slideEnds.map({ $0 > Date() }) == true, let first = columns.first,
              let x = proxy.shownMinX(of: first.id) else { return offset }
        return offset - (x - trueFrames()[0].1.minX)
    }

    /// Stop a glide where it is now (something else takes over from there).
    private func stopSlide() {
        catchUpEnds = nil
        guard slideEnds != nil else { return }
        offset = shownOffset()
        slideEnds = nil
        slideCount += 1
    }

    /// Window moves under way right now (stowing or placing), each on its own thread.
    private var moving: DispatchGroup?

    /// Runs `f` once no move is under way, so moves never land out of order.
    private func afterMoves(_ f: @escaping () -> Void) {
        guard let g = moving else { return f() }
        g.notify(queue: .main, execute: f)
    }

    /// Moves windows all at once, each on its own thread so one busy app doesn't hold
    /// up the rest, after any moves already under way. Positions only — one AX call
    /// per window; a column's size never changes while it scrolls. `done` runs on the
    /// main thread once all have landed (or after 0.3s at the latest).
    private func move(_ moves: [(AXWindow, CGPoint)], sizes: [CGWindowID: CGSize] = [:], done: @escaping () -> Void) {
        afterMoves { [weak self] in
            guard let self else { return }
            let group = DispatchGroup()
            for (w, p) in moves {
                let size = w.cgWindowID.flatMap { sizes[$0] }
                group.enter()
                DispatchQueue.global(qos: .userInteractive).async {
                    // A window that just joined also takes its column's size.
                    if let size { w.setFrameUnclamped(CGRect(origin: p, size: size)) } else { w.setPosition(p) }
                    group.leave()
                }
            }
            self.moving = group
            var fired = false
            let fire = {
                guard !fired else { return }
                fired = true
                done()
            }
            group.notify(queue: .main) { [weak self] in
                if self?.moving === group { self?.moving = nil }
                fire()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: fire)
        }
    }

    /// While pictures stand in for the strip, the real windows wait just past the
    /// screen edge, so the live desktop (a moving wallpaper, widgets) shows between
    /// the pictures. 1pt stays on screen so macOS doesn't hand them to another
    /// display; they go out on the side that has no display next to it.
    private func stowWindows(done: @escaping () -> Void) {
        guard let screen else { return done() }
        let frame = screen.axFrame
        let neighbourRight = NSScreen.screens.contains { s in
            let f = s.axFrame
            return s != screen && f.minX >= frame.maxX - 1 && f.minY < frame.maxY && f.maxY > frame.minY
        }
        move(columns.map { c in
            let slot = slot(x: 0, column: c)
            return (c.window, CGPoint(x: neighbourRight ? frame.minX - slot.width + 1 : frame.maxX - 1, y: slot.minY))
        }, done: done)
    }

    /// Every column's window to its place at the current offset, all at once.
    private func placeWindows(resizing: Set<CGWindowID> = [], done: @escaping () -> Void = {}) {
        var sizes: [CGWindowID: CGSize] = [:]
        for i in columns.indices where resizing.contains(columns[i].id) { sizes[columns[i].id] = frame(of: i, at: offset).size }
        // The ones you'll see first; `done` doesn't wait for the parked ones at the edges.
        let parked = Set(columns.indices.filter { isParked($0, at: offset) })
        let shown = columns.indices.filter { !parked.contains($0) }
        move(shown.map { (columns[$0].window, frame(of: $0, at: offset).origin) }, sizes: sizes) { [weak self] in
            self?.updateEdgeSensors()
            done()
        }
        if !parked.isEmpty {
            move(parked.map { (columns[$0].window, frame(of: $0, at: offset).origin) }, sizes: sizes) { [weak self] in
                self?.updateEdgeSensors()
            }
        }
    }

    /// Show the strip at `offset` now (fingers, pad drags; and the real windows' own
    /// frame-by-frame steps when there are no pictures).
    private func render() {
        if proxy != nil {
            // Each movement is a glide of a few frames toward where the fingers are now
            // (or what's left of catching up): when events come in unevenly, as they do
            // under load, the pictures still move continuously.
            let left = catchUpEnds?.timeIntervalSinceNow ?? 0
            let d = max(left, Self.followLag)
            catchUpEnds = Date() + d
            slide(to: offset, duration: d, curve: left > Self.followLag ? .out : .chase)
        } else {
            pad?.update(offset: offset)
            // Waiting for fresh pictures: the windows stay where they are until the cover is up.
            if coverPending == nil { applyPositions() }
        }
    }

    /// Motion ended: the real windows go back all at once, and the pictures lift off
    /// the moment they've landed. Checking that every app took its column's width
    /// (a read per window) waits until after, off the critical path.
    private func endMotion(resizing: Set<CGWindowID> = []) {
        // Under the overview the windows stay aside; it puts them back when it closes.
        guard overview == nil else { return }
        cancelCover()
        slideEnds = nil
        catchUpEnds = nil
        slideCount += 1
        pad?.update(offset: offset)
        let p = proxy
        proxy = nil
        let began = Date()
        // Focus first: the window's switch to its active look happens while the
        // pictures still cover it, not as a second change after they've gone.
        if focusOnRest { focusFrontColumn() }
        focusOnRest = false
        placeWindows(resizing: resizing) { [weak self] in
            Debug.log("strip: windows back in \(Int(Date().timeIntervalSince(began) * 1000))ms")
            // Two frames for the window server to show them, then the pictures fade off
            // them — unless the strip is already moving again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 / 60) {
                guard let p else { return }
                guard let self, self.proxy == nil, self.overview == nil else { return p.close() }
                self.fading?.close()
                self.fading = p
                p.fadeOut(duration: 0.14)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    if self?.fading === p { self?.fading = nil }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self, self.isActive, self.proxy == nil, self.overview == nil else { return }
                self.fitColumnsToWindows()
                self.refreshSnapshots(visibleOnly: true)
            }
        }
    }

    /// Columns as they look now at their column size: every one (parked ones too),
    /// or after a stop only those you can see — the parked ones haven't been looked at.
    private func refreshSnapshots(visibleOnly: Bool = false, done: (([CGWindowID: CGImage]) -> Void)? = nil) {
        guard isActive, WindowCapture.hasPermission else { return }
        let ids = visibleOnly ? trueFrames().filter { $0.1.intersects(area) }.map(\.0) : columns.map(\.id)
        // Wholly on screen: the quick way, sparing the machine ScreenCaptureKit's work.
        let whole = Set(trueFrames().filter { area.insetBy(dx: -1, dy: -1).contains($0.1) && ids.contains($0.0) }.map(\.0))
        if visibleOnly, !whole.isEmpty {
            WindowCapture.captureOnScreen(Array(whole)) { [weak self] shots in
                guard let self, self.isActive else { return }
                self.snapshots.merge(shots) { $1 }
            }
        }
        WindowCapture.capture(visibleOnly ? ids.filter { !whole.contains($0) } : ids) { [weak self] shots in
            guard let self, self.isActive else { return }
            self.snapshots.merge(shots) { $1 }
            done?(shots)
        }
    }

    /// App icons, rendered once per app (the overview shows them every time).
    private var iconCache: [pid_t: CGImage] = [:]

    /// Rendering an icon the first time is slow (a third of a second for a few apps):
    /// do it ahead, not when ⌃↑ is pressed.
    private func warmIcons() {
        for c in columns where iconCache[c.window.pid] == nil { _ = icon(for: c.window.pid) }
    }

    private func icon(for pid: pid_t) -> CGImage? {
        if let i = iconCache[pid] { return i }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        // Big enough for a 48pt badge's artwork at 2x (the artwork is 824/1024 of it).
        var rect = CGRect(x: 0, y: 0, width: 120, height: 120)
        let img = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        iconCache[pid] = img
        return img
    }

    // MARK: Following the windows

    private var adoptWork: DispatchWorkItem?

    /// Hears the column's window close or minimize (sent to the window itself) and its
    /// app open new windows.
    /// Every regular app's new windows, focus moves and un-minimizes — not only the
    /// apps already in the strip: an app that's in front with no window here yet can
    /// open one without ever being "activated".
    private func watchApp(_ pid: pid_t) {
        guard watchers[pid] == nil else { return }
        watchers[pid] = AXWatch(pid: pid, notifications: [kAXWindowCreatedNotification, kAXWindowDeminiaturizedNotification,
                                                          kAXFocusedWindowChangedNotification]) { [weak self] note in
            self?.windowEvent(note)
        }
    }

    private func watch(_ c: Column) {
        let pid = c.window.pid
        watchApp(pid)
        watchers[pid]?.add(c.window.element, kAXUIElementDestroyedNotification)
        watchers[pid]?.add(c.window.element, kAXWindowMiniaturizedNotification)
        watchers[pid]?.add(c.window.element, kAXWindowDeminiaturizedNotification)
        watchers[pid]?.add(c.window.element, kAXWindowResizedNotification)
    }

    private func windowEvent(_ note: String) {
        switch note {
        case kAXWindowCreatedNotification, kAXWindowDeminiaturizedNotification:
            // An un-minimized window comes back into the strip, where it was.
            adoptSoon()
        case kAXWindowResizedNotification:
            windowResized()
        case kAXFocusedWindowChangedNotification:
            // Another window of the same app (⌘`, a click): bring it into view; also a
            // window only ordered out on close lets focus go, so look for leavers.
            checkGoneSoon()
            guard proxy == nil, overview == nil, moving == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.revealFocused() }
        default:
            // Destroyed, minimized, or focus moved on (a window that was only ordered
            // out on close lets focus go).
            checkGoneSoon()
        }
    }

    /// A window may just have left. The notice often comes while it's still fading
    /// out on screen, or while the strip is busy: look now and a few more times over
    /// the next half second, so the neighbours close the gap as soon as it's gone.
    private func checkGoneSoon() {
        // The app in front is asked for its window list off the main thread: it may
        // be slow to answer while it closes the window.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, columns.contains(where: { $0.window.pid == pid }) {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let ids = AXWindow.windowIDs(of: pid)
                DispatchQueue.main.async {
                    // Mid-glide too: the others close the gap from where they show.
                    guard let self, self.isActive, self.coverPending == nil, self.overview == nil else { return }
                    self.dropGoneColumns(known: (pid, ids))
                }
            }
        }
        for d in [0.0, 0.1, 0.25, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self, self.isActive else { return }
                guard self.coverPending == nil, self.overview == nil else { return }
                self.dropGoneColumns()
            }
        }
    }

    /// Columns whose window left: closed, minimized, or put away — many apps only
    /// order a window out when it's closed, with no destroyed notice. Off screen alone
    /// isn't enough: App Exposé and Mission Control take other apps' windows off screen
    /// too, and when none of the strip is on screen it's another Space. So a window
    /// that's off screen leaves only if it's destroyed, minimized, or gone from its
    /// app's window list (where an ordered-out window no longer appears). Window-server
    /// lookups first: the apps are only asked about windows already off screen.
    /// `known`: the window list of an app that just said its focus moved — a window
    /// it closed leaves that list at once, while the window itself takes a while to
    /// fade off screen.
    private func goneColumns(known: (pid: pid_t, ids: Set<CGWindowID>?)? = nil) -> [CGWindowID] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreen = Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        var listed: [pid_t: Set<CGWindowID>?] = [:]
        var closing: [CGWindowID] = []
        if let (pid, ids) = known {
            listed[pid] = ids
            if let ids {
                closing = columns.filter { $0.window.pid == pid && onScreen.contains($0.id) && !ids.contains($0.id) }.map(\.id)
            }
        }
        let off = columns.filter { !onScreen.contains($0.id) }
        guard !off.isEmpty || !closing.isEmpty, off.count < columns.count else { return [] }
        return closing + off.filter { c in
            if AXWindow.serverFrame(of: c.id) == nil { return true }
            let pid = c.window.pid
            if listed[pid] == nil { listed[pid] = AXWindow.windowIDs(of: pid) }
            // No answer from the app: keep the window rather than guess.
            guard let ids = listed[pid] ?? nil else { return false }
            // Full screen is its own Space: it leaves, and rejoins when it comes back.
            return !ids.contains(c.id) || c.window.isMinimized || c.window.isFullScreen
        }.map(\.id)
    }

    private func dropGoneColumns(known: (pid: pid_t, ids: Set<CGWindowID>?)? = nil) {
        // Only on the strip's own Space: elsewhere (another desktop, a full-screen app,
        // Mission Control) the strip's windows are out of sight, not gone.
        guard onHomeSpace else { return }
        let gone = goneColumns(known: known)
        guard !gone.isEmpty else { return }
        Debug.log("strip: dropping \(gone) (closed or minimized)")
        // A minimized window gets its own frame back now, so it unminimizes where it was.
        // Not a full-screen one: resizing it could knock it out of full screen.
        for id in gone {
            if let w = originalWindows[id], let f = originals[id], AXWindow.serverFrame(of: id) != nil, !w.isFullScreen { w.setFrame(f) }
        }
        // Remember each one's left neighbour: un-minimized, it goes back there.
        for id in gone {
            guard let i = columns.firstIndex(where: { $0.id == id }) else { continue }
            returnAfter[id] = columns[..<i].last { !gone.contains($0.id) }?.id ?? 0
        }
        let before = Dictionary(uniqueKeysWithValues: trueFrames(at: shownOffset()))
        columns.removeAll { gone.contains($0.id) }
        if columns.isEmpty { exit(); return }
        // The others slide together over the gap, each keeping its width.
        animateLayout(from: before, to: clamp(offset))
    }

    /// New windows join the strip right after the focused column (niri: opening a
    /// window never squeezes the others). Debounced: apps place new windows a beat later.
    private func adoptSoon() {
        adoptWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.adoptNewWindows() }
        adoptWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    private func adoptNewWindows() {
        guard isActive, let screen, onHomeSpace else { return }
        dropGoneColumns()
        let known = Set(columns.map(\.id))
        let fresh = Self.windows(on: screen).filter { !known.contains($0.0) }
        guard !fresh.isEmpty else { return }
        // Right after the column you were in: a new window already has focus itself,
        // so fall back to the strip column that had it last.
        let focusedID = AXWindow.focused()?.cgWindowID
        let anchor = columns.contains { $0.id == focusedID } ? focusedID : lastFocusedColumn
        var insertAt = (columns.firstIndex { $0.id == anchor }).map { $0 + 1 } ?? columns.count
        var lastID: CGWindowID?
        // Where everything is now: the slide starts here, a new window from where it opened.
        var before = Dictionary(uniqueKeysWithValues: trueFrames())
        for (id, w, f) in fresh {
            before[id] = f
            // A window coming back keeps the frame it had before it first joined.
            if originals[id] == nil { originals[id] = f }
            originalWindows[id] = w
            if WindowCapture.hasPermission, let img = WindowCapture.snapshot(id) { snapshots[id] = img }
            let share = Self.presets.min { abs($0 - f.width / area.width) < abs($1 - f.width / area.width) }!
            let c = Column(id: id, window: w, width: (area.width * share).rounded())
            if let after = returnAfter.removeValue(forKey: id) {
                // Back from the Dock: its old place, next to the column it sat after.
                let at = after == 0 ? 0 : (columns.firstIndex { $0.id == after }.map { $0 + 1 } ?? min(insertAt, columns.count))
                columns.insert(c, at: at)
                if at < insertAt { insertAt += 1 }
            } else {
                insertAt = min(insertAt, columns.count)
                columns.insert(c, at: insertAt)
                insertAt += 1
            }
            watch(c)
            lastID = id
        }
        ParkedJournal.record("strip", columns.compactMap { c in originals[c.id].map { (c.window, $0) } })
        // Room opens up and the strip slides to the new window.
        animateLayout(from: before, to: lastID.map { visibleOffset(for: $0) } ?? offset, resizing: Set(fresh.map(\.0)))
        warmIcons()
        Debug.log("strip: adopted \(fresh.count) new window(s), now \(columns.count) columns")
    }

    /// The pointer is in the top band (title bar) of a strip column that's on top
    /// there. Pure geometry from the window server: no app is asked anything.
    func pointerOnColumnTitlebar(_ p: CGPoint) -> Bool {
        guard isActive else { return false }
        // Mid-move the real windows are stepped aside and the pictures are what's
        // under the pointer: test against where the pictures are.
        if proxy != nil || moving != nil {
            return trueFrames(at: shownOffset()).contains { _, f in f.contains(p) && p.y - f.minY <= Titlebar.webTitlebarBand }
        }
        guard area.contains(p) || p.y >= area.minY - 2,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p) else { continue }
            guard let id = info[kCGWindowNumber as String] as? CGWindowID, columns.contains(where: { $0.id == id }) else { return false }
            return p.y - r.minY <= Titlebar.webTitlebarBand
        }
        return false
    }

    /// While the strip is on: switching to a parked window scrolls it into view;
    /// resting on a sliver peeks; clicking a sliver scrolls to it.
    private func installMonitors() {
        guard goneCheck == nil else { return }
        // A closed window leaves the strip and its neighbours close the gap, each
        // keeping its own width. Not mid-move: the windows are stepped aside then.
        // Mostly the windows' own notices (destroyed, minimized, focus moving on) say
        // when one may have left; this slow look catches anything they miss.
        goneCheck = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.proxy == nil, self.overview == nil, self.moving == nil else { return }
            self.dropGoneColumns()
        }
        // The Dock changes width as apps come and go: the pad keeps to the room left of it.
        padFollow = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, let s = self.screen else { return }
            self.pad?.follow(s)
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            watchApp(app.processIdentifier)
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            self?.watchApp(app.processIdentifier)
            // Its Dock icon slides in: follow once the Dock has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if let s = self?.screen { self?.pad?.follow(s) } }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.adoptSoon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self?.revealFocused() }
        }
        // Clicking the Dock icon of the app that's already in front activates nothing, so
        // the observer above never hears it and a parked window stayed at the edge.
        // The Dock's frame is asked of the Dock at most every few seconds, not on every click.
        var dockFrame: (CGRect?, Date) = (nil, .distantPast)
        dockClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            // A click may have been on a close button (some apps only order the window out).
            self?.checkGoneSoon()
            if Date().timeIntervalSince(dockFrame.1) > 5 { dockFrame = (ScrollPad.dockIconsFrame(), Date()) }
            guard let dock = dockFrame.0, dock.contains(NSEvent.mouseLocation) else { return }
            // The app handles the click (reopen, un-minimize) before its window is raised.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.revealFocused() }
        }
    }

    /// Switching to a window (Dock, ⌘Tab, ⌘`) that isn't fully in view slides the
    /// strip to it.
    private func revealFocused() {
        guard proxy == nil, overview == nil, moving == nil,
              let id = AXWindow.focused()?.cgWindowID, columns.contains(where: { $0.id == id }) else { return }
        lastFocusedColumn = id
        if let a = autoFocused, a.id == id, Date().timeIntervalSince(a.at) < 1.5 { return }
        guard abs(visibleOffset(for: id) - offset) > 1 else { return }
        Debug.log("strip: revealing column \(id)")
        scroll(toColumnOf: id, curve: .inOut)
    }

    /// After you scroll, the column now in front takes focus — unless the one you
    /// were in is still (nearly) all in view. In front: the most of it on screen,
    /// the one nearer the middle when that's a tie.
    private func focusFrontColumn() {
        guard isActive, proxy == nil, overview == nil, onHomeSpace else { return }
        func onScreen(_ f: CGRect) -> CGFloat { max(0, min(f.maxX, area.maxX) - max(f.minX, area.minX)) }
        let frames = trueFrames()
        let shown = Dictionary(uniqueKeysWithValues: frames.map { ($0.0, onScreen($0.1) / max(1, $0.1.width)) })
        guard let front = frames.max(by: { a, b in
            let sa = onScreen(a.1), sb = onScreen(b.1)
            if abs(sa - sb) > 4 { return sa < sb }
            return abs(a.1.midX - area.midX) > abs(b.1.midX - area.midX)
        }), onScreen(front.1) > 0, let w = columns.first(where: { $0.id == front.0 })?.window else { return }
        // Asking an app is slow under load: off the main thread.
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            if let id = AXWindow.focused()?.cgWindowID, id == front.0 || (shown[id] ?? 0) >= 0.9 { return }
            DispatchQueue.main.async {
                self?.autoFocused = (front.0, Date())
                self?.lastFocusedColumn = front.0
            }
            Debug.log("strip: focusing column \(front.0) after the scroll")
            w.raise()
        }
    }

    private func removeMonitors() {
        goneCheck?.invalidate()
        goneCheck = nil
        padFollow?.invalidate()
        padFollow = nil
        edgeSensors.forEach { $0.orderOut(nil) }
        edgeSensors = []
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
        if let o = launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        launchObserver = nil
        if let m = dockClickMonitor { NSEvent.removeMonitor(m) }
        dockClickMonitor = nil
    }

    // MARK: Edges

    /// One sensor per screen edge, up only while a column is parked on that side.
    private var edgeSensors: [EdgeSensor] = []

    /// The pointer resting on a parked column's sliver peeks at it, a click there
    /// scrolls to it. Sensors over just those slivers wake the strip only at the
    /// edges, instead of it watching every mouse move system-wide.
    private func updateEdgeSensors() {
        guard isActive else { return }
        if edgeSensors.isEmpty {
            for left in [true, false] {
                let x = left ? area.minX : area.maxX - Self.sliver
                let s = EdgeSensor(frame: Geometry.cocoaRect(fromAX: CGRect(x: x, y: area.minY, width: Self.sliver, height: area.height)))
                s.onEnter = { [weak self] in self?.edgeEntered(left: left) }
                s.onExit = { [weak self] in self?.closePeek() }
                s.onClick = { [weak self] in self?.edgeClicked(left: left) }
                edgeSensors.append(s)
            }
        }
        for (k, left) in [true, false].enumerated() {
            if parkedColumn(left: left) != nil { edgeSensors[k].orderFrontRegardless() } else { edgeSensors[k].orderOut(nil) }
        }
    }

    /// The parked column nearest the screen on that side.
    private func parkedColumn(left: Bool) -> Int? {
        let parked = columns.indices.filter { isParked($0, at: offset) }
        if left { return parked.filter { area.minX + start(of: $0) - offset < area.minX }.last }
        return parked.filter { area.minX + start(of: $0) - offset >= area.maxX - Self.sliver }.first
    }

    private func edgeEntered(left: Bool) {
        peekWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let i = self.parkedColumn(left: left) else { return }
            self.showPeek(i, pointer: Geometry.mouseAX)
        }
        peekWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func edgeClicked(left: Bool) {
        guard let i = parkedColumn(left: left) else { return }
        closePeek()
        scroll(toColumnOf: columns[i].id)
    }

    private func showPeek(_ i: Int, pointer: CGPoint) {
        Debug.log("strip: peek column \(i)")
        closePeek()
        let c = columns[i]
        let onLeft = pointer.x < area.midX
        let card = PeekCard(windowID: c.id, size: CGSize(width: c.width, height: area.height), area: area, leftEdge: onLeft)
        peek = card
        card.present()
    }

    private func closePeek() {
        peekWork?.cancel()
        peekWork = nil
        peek?.close()
        peek = nil
    }

    // MARK: Reordering

    /// Where a dragged column would go if dropped at this pointer x: the index and
    /// the slot it would take (for the preview).
    func reorderSlot(for w: AXWindow, pointer: CGPoint) -> (index: Int, frame: CGRect)? {
        guard let id = w.cgWindowID, columns.contains(where: { $0.id == id }) else { return nil }
        for (i, (_, f)) in trueFrames().enumerated() where pointer.x >= f.minX - gap && pointer.x < f.maxX + gap {
            return (i, f.intersection(area))
        }
        return pointer.x < area.midX ? (0, trueFrames().first!.1.intersection(area)) : (columns.count - 1, trueFrames().last!.1.intersection(area))
    }

    /// Drop a dragged column at a new place in the strip.
    func reorder(_ w: AXWindow, pointer: CGPoint) {
        guard let id = w.cgWindowID, let from = columns.firstIndex(where: { $0.id == id }),
              let to = reorderSlot(for: w, pointer: pointer)?.index else { return }
        let c = columns.remove(at: from)
        columns.insert(c, at: to)
        offset = clamp(offset)
        endMotion()
        scroll(toColumnOf: id)
    }

    /// Shortcut: move the focused window's column one place left or right.
    func moveFocusedColumn(_ direction: Int) {
        guard isActive, let id = AXWindow.focused()?.cgWindowID, let i = columns.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return }
        let j = i + direction
        guard columns.indices.contains(j) else { NSSound.beep(); return }
        columns.swapAt(i, j)
        endMotion()
        scroll(toColumnOf: id)
    }

    // MARK: Scroll pad

    /// Columns as fractions of the whole strip, the visible window, total width.
    private func padModel() -> ([CGFloat], CGFloat, CGFloat) {
        let total = max(1, totalWidth)
        return (columns.map { $0.width / total }, offset / total, area.width / total)
    }

    /// The pad works like a scroll bar: dragging it right shows what's further right.
    private func padDragged(_ dx: CGFloat) {
        guard let pad else { return }
        scroll(by: -dx * totalWidth / max(1, pad.mapWidth))
    }

    private func padReleased(_ v: CGFloat) {
        guard let pad else { return }
        release(velocity: -v * totalWidth / max(1, pad.mapWidth) * 0.4)
    }

    // MARK: Overview

    /// ⌃↑: open the overview, or close it if it's open.
    func toggleOverview() {
        if let o = overview { o.dismiss() } else { showOverview() }
    }

    /// The whole strip at a glance (double-click the pad, or pinch out on a title
    /// bar): the screen zooms out from where things are now; pick a window and it
    /// zooms back in onto that window's column.
    func showOverview() {
        guard isActive, overview == nil, onHomeSpace else { return }
        let asked = Date()
        animation?.invalidate()
        wheelIdle?.cancel()
        wheelTarget = nil
        stopSlide()
        cancelCover()
        focusOnRest = false
        proxy?.close(); proxy = nil
        fading?.close(); fading = nil
        closePeek()
        dropGoneColumns()
        guard isActive else { return }
        // The pictures in hand (retaken after every stop) open it at once; fresh ones
        // are taken in the background and swapped in.
        let images = snapshots
        Debug.log("strip: overview with pictures for \(columns.filter { images[$0.id] != nil }.count)/\(columns.count); missing \(columns.filter { images[$0.id] == nil }.map { $0.window.bundleID ?? "?" })")
        var icons: [CGWindowID: CGImage] = [:]
        for c in columns { icons[c.id] = icon(for: c.window.pid) }
        let o = StripOverview(area: area, images: images, icons: icons,
                              now: trueFrames(), overview: overviewFrames())
        o.onPick = { [weak self, weak o] id in
            guard let self, let o else { return }
            let target = self.visibleOffset(for: id)
            o.zoomIn(to: self.trueFrames(at: target)) {
                self.offset = target
                self.pad?.update(offset: target)
                self.placeWindows {
                    self.columns.first { $0.id == id }?.window.raise()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                        o.close()
                        self.overview = nil
                    }
                }
            }
        }
        o.onDismiss = { [weak self, weak o] in
            // Held until it's closed: AppKit keeps a panel on screen after its owner lets go.
            guard let o else { return }
            self?.placeWindows {
                self?.overview = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { o.close() }
            }
        }
        overview = o
        // The tiles go up exactly over the windows; the windows step out from under
        // them, and only then does the view pull back, so no real window shows behind.
        o.show()
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self, weak o] in
            guard let self, let o, self.overview === o else { return }
            self.stowWindows {
                Debug.log("strip: overview moving \(Int(Date().timeIntervalSince(asked) * 1000))ms after ⌃↑")
                o.present()
            }
        }
        refreshSnapshots { [weak o] shots in o?.update(images: shots) }
    }

    /// Offset that brings a column fully into view with the least movement.
    private func visibleOffset(for id: CGWindowID) -> CGFloat {
        guard let i = columns.firstIndex(where: { $0.id == id }) else { return offset }
        let s = start(of: i), w = columns[i].width
        var target = offset
        if s < offset { target = s } else if s + w > offset + area.width { target = s + w - area.width }
        return clamp(target)
    }

    /// Every column scaled down to fit across the screen, centred, in strip order.
    private func overviewFrames() -> [(CGWindowID, CGRect)] {
        let spacing: CGFloat = 24, margin: CGFloat = 60
        let total = totalWidth + spacing * CGFloat(max(0, columns.count - 1))
        let k = min(0.6, (area.width - 2 * margin) / max(1, total), (area.height - 2 * margin) / max(1, area.height))
        var x = area.minX + (area.width - total * k) / 2
        return trueFrames(at: 0).enumerated().map { i, item in
            let (id, f) = item
            let r = CGRect(x: x + (f.minX - (area.minX + start(of: i))) * k, y: area.midY - area.height * k / 2 + (f.minY - area.minY) * k,
                           width: f.width * k, height: f.height * k)
            x += columns[i].width * k + spacing * k
            return (id, r)
        }
    }
}

/// The zoomed-out strip, GTA-map style, over the live desktop: every tile starts
/// exactly where its window is, then shrinks out to the overview; picking one zooms
/// back in onto that column. Animations are explicit (from → to) so they play even
/// on the panel's very first frame.
final class StripOverview: NSObject {
    var onPick: (CGWindowID) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    private let panel: NSPanel
    private let root = CALayer()
    private var tiles: [CGWindowID: CALayer] = [:]
    /// Each tile's app icon, under its bottom edge; shown once the view has pulled back.
    private var badges: [CALayer] = []
    private var dismissed = false
    private let area: CGRect
    private let now: [(CGWindowID, CGRect)]
    private let target: [(CGWindowID, CGRect)]
    private var keyMonitor: Any?
    private var busy = false
    /// Share of an app icon's canvas the artwork takes (824 of 1024).
    private static let iconArtwork: CGFloat = 824.0 / 1024
    /// The zoom's length, from Settings (卷轴 → 预览动画时长).
    static var duration: CFTimeInterval { max(0.1, Settings.shared.data.stripOverviewDuration) }

    init(area: CGRect, images: [CGWindowID: CGImage], icons: [CGWindowID: CGImage],
         now: [(CGWindowID, CGRect)], overview: [(CGWindowID, CGRect)]) {
        self.area = area
        self.now = now
        self.target = overview
        panel = NSPanel(contentRect: Geometry.cocoaRect(fromAX: area), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Over always-on-top windows too, just under the Dock.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.dock.rawValue - 1)
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        let view = OverviewView(frame: CGRect(origin: .zero, size: area.size))
        // Layer-hosting: give the view our layer first, then turn layers on, or
        // AppKit takes the tree over and drops our animations.
        view.layer = root
        view.wantsLayer = true
        // The real desktop shows through; a trace of colour keeps clicks on the
        // empty space from falling through to it.
        root.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        for (id, f) in now {
            let l = CALayer()
            l.contents = images[id]
            l.contentsGravity = .resize
            l.cornerRadius = 10
            l.masksToBounds = true
            l.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            l.borderWidth = 1
            l.frame = local(f)
            root.addSublayer(l)
            tiles[id] = l
        }
        // One row of icons, all the same size, a little below the lowest tile, so a
        // short window's icon lines up with the rest instead of hugging its edge.
        let side = min(48, max(24, (overview.map(\.1.width).min() ?? 48) - 8))
        let row = (overview.map(\.1.maxY).max() ?? area.midY) + 6
        for (id, f) in overview {
            guard let icon = icons[id] else { continue }
            // The icon artwork is the 824-pt rounded square in a 1024 canvas; macOS bakes
            // a soft shadow into the margin around it. Show the artwork only, clipped to
            // its own corner radius, so no dark rim shows on the wallpaper.
            let b = CALayer()
            b.contents = icon
            let m = (1 - Self.iconArtwork) / 2
            b.contentsRect = CGRect(x: m, y: m, width: Self.iconArtwork, height: Self.iconArtwork)
            b.cornerRadius = side * 185.0 / 824
            b.cornerCurve = .continuous
            b.masksToBounds = true
            b.frame = StripProxy.local(CGRect(x: f.midX - side / 2, y: row, width: side, height: side), in: area)
            b.opacity = 0
            root.addSublayer(b)
            badges.append(b)
        }
        view.onClick = { [weak self] p in self?.clicked(p) }
        panel.contentView = view
    }

    private func local(_ ax: CGRect) -> CGRect { StripProxy.local(ax, in: area) }

    /// Fresher pictures arrived: swap them in without disturbing any animation.
    func update(images: [CGWindowID: CGImage]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, img) in images { tiles[id]?.contents = img }
        CATransaction.commit()
    }

    /// Up over the windows, tiles exactly where the windows are: nothing changes yet.
    func show() { panel.orderFrontRegardless() }

    func present() {
        guard !dismissed else { return }
        panel.orderFrontRegardless()
        // Out: a hard first push, then a long soft landing.
        animate(to: target, timing: CAMediaTimingFunction(controlPoints: 0.05, 0.9, 0.1, 1)) { [weak self] in
            self?.fadeBadges(to: 1, duration: 0.2)
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.dismiss() }        // Esc
        }
    }

    private func fadeBadges(to opacity: Float, duration: CFTimeInterval) {
        for b in badges {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = b.presentation()?.opacity ?? b.opacity
            a.toValue = opacity
            a.duration = duration
            b.opacity = opacity
            b.add(a, forKey: "opacity")
        }
    }

    /// Glide every tile to a state, explicitly.
    /// Default timing: a gentle start, then a long glide in, like a camera move.
    private func animate(to frames: [(CGWindowID, CGRect)],
                         timing: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.15, 1),
                         done: @escaping () -> Void = {}) {
        busy = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            self?.busy = false
            done()
        }
        func animate(_ l: CALayer, _ key: String, from: Any?, to: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = Self.duration
            a.timingFunction = timing
            l.add(a, forKey: key)
        }
        for (id, f) in frames {
            guard let l = tiles[id] else { continue }
            let start = l.presentation()?.frame ?? l.frame
            let end = local(f)
            l.frame = end
            animate(l, "position", from: NSValue(point: CGPoint(x: start.midX, y: start.midY)), to: NSValue(point: CGPoint(x: end.midX, y: end.midY)))
            animate(l, "bounds.size", from: NSValue(size: start.size), to: NSValue(size: end.size))
        }
        CATransaction.commit()
    }

    private func clicked(_ p: CGPoint) {
        guard !busy else { return }
        if let (id, _) = target.reversed().first(where: { local($0.1).contains(p) }) {
            onPick(id)
        } else {
            dismiss()
        }
    }

    /// Zoom back in so the strip lands at `frames`, then call `done`.
    func zoomIn(to frames: [(CGWindowID, CGRect)], done: @escaping () -> Void) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        dismissed = true
        fadeBadges(to: 0, duration: 0.12)
        animate(to: frames, done: done)
    }

    /// Esc or a click on empty space: zoom back to how things were.
    func dismiss() {
        guard !busy else { return }
        // The owner puts the windows back, then lifts the tiles off.
        zoomIn(to: now) { [weak self] in self?.onDismiss() }
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        panel.orderOut(nil)
    }

    // Whatever path lets go of it, the panel must not stay behind on screen.
    deinit { close() }

    private final class OverviewView: NSView {
        var onClick: (CGPoint) -> Void = { _ in }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseUp(with event: NSEvent) { onClick(convert(event.locationInWindow, from: nil)) }
    }
}

/// A look at a parked column, next to its sliver. Only for looking: clicks pass through.
final class PeekCard {
    let windowID: CGWindowID
    private let panel: NSPanel
    private let layer = CALayer()
    private var stream: LiveWindowStream?

    init(windowID: CGWindowID, size: CGSize, area: CGRect, leftEdge: Bool) {
        self.windowID = windowID
        let scale = min(1, area.width * 0.5 / max(1, size.width))
        let w = size.width * scale, h = size.height * scale
        let ax = CGRect(x: leftEdge ? area.minX + 18 : area.maxX - 18 - w, y: area.midY - h / 2, width: w, height: h)
        panel = NSPanel(contentRect: Geometry.cocoaRect(fromAX: ax), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        let v = NSView(frame: CGRect(origin: .zero, size: ax.size))
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer.frame = v.bounds
        layer.contentsGravity = .resizeAspect
        layer.contents = WindowCapture.snapshot(windowID)
        v.layer?.addSublayer(layer)
        panel.contentView = v
        if WindowCapture.hasPermission {
            let s = LiveWindowStream(layer: layer)
            s.start(windowID: windowID, size: ax.size, scale: NSScreen.main?.backingScaleFactor ?? 2)
            stream = s
        }
    }

    func present() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    func close() {
        stream?.stop()
        panel.orderOut(nil)
    }
}

/// Pictures of every column sliding over the live desktop while the strip moves
/// (the real windows step aside meanwhile, see ScrollStrip.stowWindows).
final class StripProxy {
    private let panel: NSPanel
    private let root = CALayer()
    private var layers: [CGWindowID: CALayer] = [:]
    /// A soft shadow under each picture, like the real window's, so nothing pops in
    /// when the real windows take over. Its own layer (the picture is clipped to its
    /// rounded corners, which would clip a shadow too), drawn from a path: cheap.
    private var shadows: [CGWindowID: CALayer] = [:]
    private let area: CGRect
    private static let corner: CGFloat = 16

    init(area: CGRect, images: [CGWindowID: CGImage]) {
        self.area = area
        panel = NSPanel(contentRect: Geometry.cocoaRect(fromAX: area), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        // No zoom-out when it goes away: the real windows are already in place.
        panel.animationBehavior = .none
        let v = NSView(frame: CGRect(origin: .zero, size: area.size))
        v.layer = root
        v.wantsLayer = true
        // All shadows under all pictures: a neighbour's shadow never lies across a picture.
        for id in images.keys {
            let sh = CALayer()
            sh.shadowColor = NSColor.black.cgColor
            sh.shadowOpacity = 0.28
            sh.shadowRadius = 14
            sh.shadowOffset = CGSize(width: 0, height: -8)
            root.addSublayer(sh)
            shadows[id] = sh
        }
        for (id, img) in images {
            let l = CALayer()
            l.contents = img
            l.contentsGravity = .resize
            l.cornerRadius = Self.corner
            l.cornerCurve = .continuous
            l.masksToBounds = true
            root.addSublayer(l)
            layers[id] = l
        }
        panel.contentView = v
    }

    /// AX (top-down) rect to this panel's layer space (bottom-up). Done by hand:
    /// a layer-hosting view doesn't honour geometryFlipped reliably.
    static func local(_ ax: CGRect, in area: CGRect) -> CGRect {
        CGRect(x: ax.minX - area.minX, y: area.maxY - ax.maxY, width: ax.width, height: ax.height)
    }

    private static func shadowPath(_ size: CGSize) -> CGPath {
        CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    func layout(_ frames: [(CGWindowID, CGRect)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, f) in frames {
            let r = Self.local(f, in: area)
            for l in [layers[id], shadows[id]].compactMap({ $0 }) {
                l.removeAllAnimations()
                l.frame = r
            }
            if let sh = shadows[id], sh.shadowPath == nil || sh.shadowPath?.boundingBox.size != r.size {
                sh.shadowPath = Self.shadowPath(r.size)
            }
        }
        CATransaction.commit()
    }

    /// Every picture glides from where it shows now to `frames`. The window server
    /// runs it, so it stays smooth whatever Panes or the apps are busy with. `done`
    /// runs when it lands (also when it's cut short by the next layout or glide).
    func slide(_ frames: [(CGWindowID, CGRect)], duration: CFTimeInterval, timing: CAMediaTimingFunction, done: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(done)
        func animate(_ l: CALayer, _ key: String, from: Any, to: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.timingFunction = timing
            l.add(a, forKey: key)
        }
        for (id, f) in frames {
            let r = Self.local(f, in: area)
            for l in [layers[id], shadows[id]].compactMap({ $0 }) {
                let now = l.presentation() ?? l
                let from = (now.position, now.bounds)
                l.removeAllAnimations()
                l.frame = r
                if from.0 != l.position { animate(l, "position", from: NSValue(point: from.0), to: NSValue(point: l.position)) }
                if from.1.size != l.bounds.size {
                    animate(l, "bounds", from: NSValue(rect: from.1), to: NSValue(rect: l.bounds))
                    if l === shadows[id] {
                        let path = Self.shadowPath(r.size)
                        animate(l, "shadowPath", from: Self.shadowPath(from.1.size), to: path)
                        l.shadowPath = path
                    }
                }
            }
        }
        CATransaction.commit()
    }

    /// The real windows are in place under the pictures: let them show through
    /// over a moment, so whatever differs (focus styling, a window that redrew)
    /// blends instead of popping. The window server runs the fade.
    func fadeOut(duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [self] in panel.orderOut(nil) }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.opacity = 0
        root.add(a, forKey: "fade")
        CATransaction.commit()
    }

    /// Fresher pictures arrived mid-motion.
    func update(images: [CGWindowID: CGImage]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, img) in images { layers[id]?.contents = img }
        CATransaction.commit()
    }

    /// Where a picture's left edge shows right now (AX x), mid-glide too.
    func shownMinX(of id: CGWindowID) -> CGFloat? {
        guard let l = layers[id] else { return nil }
        return (l.presentation() ?? l).frame.minX + area.minX
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }
    deinit { panel.orderOut(nil) }
}

/// A Bool shared with another thread (the ⌃↑ tap).
final class LockedFlag {
    private var v = false
    private let lock = NSLock()
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// An invisible strip over one screen edge's sliver (see ScrollStrip.updateEdgeSensors):
/// the pointer arriving or leaving, and clicks, without a system-wide mouse monitor.
final class EdgeSensor: NSPanel {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onClick: () -> Void = {}

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        // A trace of colour: fully clear pixels let the pointer through.
        backgroundColor = NSColor.black.withAlphaComponent(0.01)
        hasShadow = false
        level = .floating
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        let v = SensorView(frame: CGRect(origin: .zero, size: frame.size))
        v.owner = self
        contentView = v
    }

    private final class SensorView: NSView {
        weak var owner: EdgeSensor?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { owner?.onEnter() }
        override func mouseExited(with event: NSEvent) { owner?.onExit() }
        override func mouseDown(with event: NSEvent) { owner?.onClick() }
    }
}

/// The scroll pad: a strip-shaped map at the bottom left, as tall as the Dock.
/// Drag it like a scroll bar, or scroll the wheel over it — no Shift needed.
final class ScrollPad: NSPanel {
    var layout: () -> ([CGFloat], CGFloat, CGFloat) = { ([], 0, 1) }
    var onDrag: (CGFloat) -> Void = { _ in }
    var onRelease: (CGFloat) -> Void = { _ in }
    var onWheel: (CGFloat) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    fileprivate let view = PadView()
    var mapWidth: CGFloat { view.mapRect.width }

    init(screen: NSScreen) {
        let frame = Self.placement(on: screen)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The glass draws its own edge, like the Dock's.
        hasShadow = false
        level = NSWindow.Level(NSWindow.Level.dock.rawValue + 1)
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.onDrag = { [weak self] in self?.onDrag($0) }
        view.onRelease = { [weak self] in self?.onRelease($0) }
        view.onWheel = { [weak self] in self?.onWheel($0) }
        view.onDoubleClick = { [weak self] in self?.onDoubleClick() }
        contentView = view
    }

    /// Bottom left, in the free space left of the Dock's icons, the Dock's twin: the
    /// same height, the same distance off the bottom (and as far from the left edge),
    /// 8pt short of it. When there's no room there, just above the Dock. Never on
    /// top of the Dock.
    static func placement(on screen: NSScreen) -> CGRect {
        let f = screen.frame, vf = screen.visibleFrame
        let band = vf.minY - f.minY                              // Cocoa: a bottom Dock sits under the visible frame
        let width: CGFloat = 260
        guard band >= 30 else { return CGRect(x: vf.minX + 8, y: vf.minY + 8, width: width, height: 52) }
        // All the room up to the Dock (it follows the Dock as apps come and go).
        if let dock = dockIconsFrame(), dock.minY >= f.minY, dock.minY < vf.minY {
            let margin = dock.minY - f.minY
            let room = dock.minX - f.minX - margin - 8
            if room >= 140 { return CGRect(x: f.minX + margin, y: dock.minY, width: min(480, room), height: dock.height) }
        } else {
            let room = f.midX - f.minX - 16
            if room >= 140 { return CGRect(x: f.minX + 8, y: f.minY + 4, width: min(480, room), height: band - 8) }
        }
        return CGRect(x: vf.minX + 8, y: vf.minY + 8, width: width, height: 52)
    }

    /// Where the Dock's row of icons is (Cocoa space), asked of the Dock itself so it
    /// works even while the Dock is hidden.
    static func dockIconsFrame() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        let kids: [AXUIElement] = app.attr(kAXChildrenAttribute) ?? []
        guard let list = kids.first(where: { $0.role == "AXList" }), let r = list.frame else { return nil }
        return Geometry.cocoaRect(fromAX: r)
    }

    /// The Dock grew or shrank: take the room that's there now.
    func follow(_ screen: NSScreen) {
        let f = Self.placement(on: screen)
        guard abs(f.minX - frame.minX) > 1 || abs(f.width - frame.width) > 1 || abs(f.minY - frame.minY) > 1 || abs(f.height - frame.height) > 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().setFrame(f, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in self?.update(offset: 0) }
    }

    /// `offset` is where the strip is (or is heading, gliding over `duration`).
    func update(offset: CGFloat, duration: CFTimeInterval = 0, timing: CAMediaTimingFunction? = nil) {
        let (cols, start, visible) = layout()
        view.map.columns = cols
        view.map.setViewport((start, visible), duration: duration, timing: timing)
    }
}

private final class PadView: NSView {
    var onDrag: (CGFloat) -> Void = { _ in }
    var onRelease: (CGFloat) -> Void = { _ in }
    var onWheel: (CGFloat) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    private var last: (x: CGFloat, t: TimeInterval)?
    private var velocity: CGFloat = 0
    private let glass: NSView
    let map = MapView()

    var mapRect: CGRect { map.mapRect }

    /// The Dock's corners at the Dock's height (about a quarter of it).
    static func corner(for height: CGFloat) -> CGFloat { (height * 0.245).rounded() }

    override init(frame: NSRect) {
        if #available(macOS 26, *) {
            // Liquid Glass, as the Dock is made of.
            let g = NSGlassEffectView()
            g.style = .regular
            g.cornerRadius = Self.corner(for: frame.height)
            map.frame = CGRect(origin: .zero, size: frame.size)
            map.autoresizingMask = [.width, .height]
            g.contentView = map
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = Self.corner(for: frame.height)
            glass = v
        }
        super.init(frame: frame)
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
        if map.superview == nil {
            // Drawn above the glass (a parent's own drawing would sit underneath it).
            map.frame = bounds
            map.autoresizingMask = [.width, .height]
            addSubview(map)
        }
        toolTip = "拖动或在上面滚动滚轮来滚动卷轴"
    }

    override func layout() {
        super.layout()
        let r = Self.corner(for: bounds.height)
        if #available(macOS 26, *), let g = glass as? NSGlassEffectView { g.cornerRadius = r } else { glass.layer?.cornerRadius = r }
    }

    required init?(coder: NSCoder) { fatalError() }

    // The whole pad takes the mouse, not its subviews.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { last = nil; onDoubleClick(); return }
        last = (NSEvent.mouseLocation.x, event.timestamp)
        velocity = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let l = last else { return }
        let x = NSEvent.mouseLocation.x
        let dt = max(0.001, event.timestamp - l.t)
        velocity = 0.7 * velocity + 0.3 * (x - l.x) / CGFloat(dt)
        last = (x, event.timestamp)
        onDrag(x - l.x)
    }

    override func mouseUp(with event: NSEvent) {
        guard last != nil else { return }
        // A press that ended still: no coasting.
        let still = event.timestamp - (last?.t ?? 0) > 0.06
        last = nil
        onRelease(still ? 0 : velocity)
    }

    override func scrollWheel(with event: NSEvent) {
        // Either axis; line-based wheels move 60pt per line, trackpads 1:1 (×2).
        let raw = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? -event.scrollingDeltaY : -event.scrollingDeltaX
        onWheel(event.hasPreciseScrollingDeltas ? raw * 2 : raw * 60)
    }
}

/// The strip in miniature: columns and the part on screen. The columns are drawn
/// only when they change; the part on screen is a layer that just moves, gliding
/// with the strip in the window server.
private final class MapView: NSView {
    var columns: [CGFloat] = [] { didSet { if columns != oldValue { needsDisplay = true } } }
    private var viewport: (CGFloat, CGFloat) = (0, 1)
    private let viewportLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        viewportLayer.cornerRadius = 8
        viewportLayer.cornerCurve = .continuous
        viewportLayer.borderWidth = 1.5
        layer?.addSublayer(viewportLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Inside the pad's rounded corners, with even room all round.
    var mapRect: CGRect {
        let inset = max(10, PadView.corner(for: bounds.height) * 0.6)
        return bounds.insetBy(dx: inset, dy: inset)
    }

    private func viewportRect(_ v: (CGFloat, CGFloat)) -> CGRect {
        let map = mapRect
        return CGRect(x: map.minX + map.width * v.0, y: map.minY - 3, width: map.width * v.1, height: map.height + 6)
    }

    func setViewport(_ v: (CGFloat, CGFloat), duration: CFTimeInterval, timing: CAMediaTimingFunction?) {
        viewport = v
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let now = viewportLayer.presentation() ?? viewportLayer
        let from = (now.position, now.bounds)
        viewportLayer.removeAllAnimations()
        viewportLayer.frame = viewportRect(v)
        if duration > 0 {
            for (key, a, b) in [("position", NSValue(point: from.0), NSValue(point: viewportLayer.position)),
                                ("bounds", NSValue(rect: from.1), NSValue(rect: viewportLayer.bounds))] where a != b {
                let anim = CABasicAnimation(keyPath: key)
                anim.fromValue = a
                anim.toValue = b
                anim.duration = duration
                anim.timingFunction = timing
                viewportLayer.add(anim, forKey: key)
            }
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewportLayer.frame = viewportRect(viewport)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let map = mapRect
        var x = map.minX
        for (i, c) in columns.enumerated() {
            let w = map.width * c
            let r = CGRect(x: x + 1, y: map.minY, width: max(1, w - 2), height: map.height)
            NSColor.white.withAlphaComponent(i % 2 == 0 ? 0.38 : 0.26).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            x += w
        }
        // The accent can change while the strip is on.
        viewportLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        viewportLayer.borderColor = NSColor.controlAccentColor.cgColor
    }
}
