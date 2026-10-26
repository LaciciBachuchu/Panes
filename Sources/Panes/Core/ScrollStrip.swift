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
    private var monitors: [Any] = []
    /// Closing a window often only orders it out, with no notice: look twice a second.
    private var goneCheck: Timer?
    private var activationObserver: Any?
    private var peek: PeekCard?
    private var peekWork: DispatchWorkItem?
    private var overview: StripOverview?
    /// ⌃↑ opens the strip overview instead of Mission Control, only while a strip is on.
    private var missionControlKey: KeyIntercept?

    var isActive: Bool { !columns.isEmpty }
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
        // Columns in their current left-to-right order; widths snap to the presets.
        columns = found.sorted { $0.2.minX < $1.2.minX }.map { id, w, f in
            let share = Self.presets.min { abs($0 - f.width / area.width) < abs($1 - f.width / area.width) }!
            return Column(id: id, window: w, width: (area.width * share).rounded())
        }
        let focusIndex = columns.firstIndex { $0.id == focused?.cgWindowID } ?? 0
        offset = clamp(start(of: focusIndex))
        applyFrames()
        fitColumnsToWindows()
        for c in columns { watch(c) }
        installMonitors()
        // The pictures from before were at the windows' old sizes: retake them once
        // the apps have laid out at their column sizes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshSnapshots() }
        let p = ScrollPad(screen: s)
        p.layout = { [weak self] in self?.padModel() ?? ([], 0, 1) }
        p.onDrag = { [weak self] dx in self?.padDragged(dx) }
        p.onRelease = { [weak self] v in self?.padReleased(v) }
        p.onDoubleClick = { [weak self] in self?.showOverview() }
        p.onWheel = { [weak self] d in
            let s = Settings.shared.data
            self?.wheel(by: d * CGFloat(s.stripScrollSpeed) * (s.stripReverseScroll ? -1 : 1))
        }
        pad = p
        p.update(offset: offset)
        p.orderFrontRegardless()
        missionControlKey = KeyIntercept(keyCode: 126, flags: .maskControl) { [weak self] in self?.toggleOverview() }
        HotKeyManager.shared.reload()
        Debug.log("strip: \(columns.count) columns, total \(Int(totalWidth))pt")
        GestureHUD.shared.flash("卷轴：\(columns.count) 列", symbol: "rectangle.split.3x1", anchor: CGPoint(x: area.midX, y: area.minY + 40))
    }

    func exit() {
        guard isActive else { return }
        animation?.invalidate()
        wheelIdle?.cancel()
        wheelTarget = nil
        proxy?.close(); proxy = nil
        pad?.orderOut(nil); pad = nil
        missionControlKey = nil
        snapshots = [:]
        closePeek()
        overview?.close(); overview = nil
        // A stow still under way must land before the windows go back.
        _ = stowing?.wait(timeout: .now() + 0.5)
        stowing = nil
        // Everything that was ever in the strip goes back, not only what's still listed.
        for (id, f) in originals {
            guard let w = originalWindows[id], AXWindow.serverFrame(of: id) != nil else { continue }
            w.setFrame(f)
        }
        columns = []
        originals = [:]
        originalWindows = [:]
        watchers = [:]
        adoptWork?.cancel()
        removeMonitors()
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
    private func fitColumnsToWindows() {
        var changed = false
        for i in columns.indices {
            let want = frame(of: i, at: offset)
            guard let got = columns[i].window.frame else { continue }
            if abs(got.width - want.width) > 3 { columns[i].width = got.width + gap; changed = true }
            if got.height < want.height - 4 { columns[i].height = got.height; changed = true }
        }
        if changed {
            offset = clamp(offset)
            applyFrames()
        }
    }

    private func isParked(_ i: Int, at o: CGFloat) -> Bool {
        let x = area.minX + start(of: i) - o
        return x + columns[i].width <= area.minX + Self.sliver || x >= area.maxX - Self.sliver
    }

    private func applyFrames() {
        for i in columns.indices { columns[i].window.setFrameUnclamped(frame(of: i, at: offset)) }
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
    private var snapshots: [CGWindowID: CGImage] = [:]
    private var wheelTarget: CGFloat?
    private var wheelIdle: DispatchWorkItem?
    private var pad: ScrollPad?

    /// Finger or pad movement (content direction): the strip follows 1:1.
    func scroll(by dx: CGFloat) {
        animation?.invalidate()
        wheelTarget = nil
        closePeek()
        beginMotion()
        // Past the ends it moves at a third of the speed (rubber band).
        let next = offset - dx
        offset = (next < 0 || next > maxOffset) ? offset - dx / 3 : next
        render()
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
        closePeek()
        beginMotion()
        let base = wheelTarget ?? offset
        wheelTarget = min(max(base + delta, -60), maxOffset + 60)
        if animation == nil || !(animation?.isValid ?? false) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: w)
    }

    /// One column left or right.
    func step(_ direction: Int) {
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

    func scroll(toColumnOf id: CGWindowID) {
        guard let i = columns.firstIndex(where: { $0.id == id }) else { return }
        // Bring it fully on screen with the least movement.
        let s = start(of: i), w = columns[i].width
        var target = offset
        if s < offset { target = s } else if s + w > offset + area.width { target = s + w - area.width }
        animate(to: clamp(target))
    }

    /// Ease the offset to a target (~0.3s) at 120 fps, then settle the real windows.
    private func animate(to target: CGFloat) {
        animation?.invalidate()
        wheelIdle?.cancel()
        wheelTarget = nil
        let from = offset, began = Date(), duration = 0.3
        guard abs(target - from) > 0.5 else { offset = clamp(target); endMotion(); return }
        beginMotion()
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let k = min(1, Date().timeIntervalSince(began) / duration)
            let e = 1 - pow(1 - k, 3)
            self.offset = from + (target - from) * e
            self.render()
            if k >= 1 {
                t.invalidate()
                self.offset = target
                self.endMotion()
            }
        }
    }

    /// Where each column truly is at the current offset (not parked), for the picture.
    private func trueFrames(at o: CGFloat? = nil) -> [(CGWindowID, CGRect)] {
        let o = o ?? offset
        return columns.indices.map { i in (columns[i].id, slot(x: area.minX + start(of: i) - o, column: columns[i])) }
    }

    /// Motion starts: cover the strip with its picture, if every column has one.
    private func beginMotion() {
        pad?.update(offset: offset)
        guard proxy == nil else { return }
        Debug.log("strip: begin motion permission=\(WindowCapture.hasPermission) snapshots=\(snapshots.count)/\(columns.count)")
        guard WindowCapture.hasPermission, columns.allSatisfy({ snapshots[$0.id] != nil }) else { return }
        let p = StripProxy(area: area, images: snapshots)
        p.layout(trueFrames())
        p.show()
        proxy = p
        // Once the pictures are up, the real windows step out from under them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak p] in
            guard let self, let p, self.proxy === p else { return }
            self.stowWindows(done: {})
        }
    }

    /// Windows on their way out right now (see stowWindows).
    private var stowing: DispatchGroup?

    /// Runs `f` once no window is still on its way out, so a window put back is
    /// never moved out again by a late stow.
    private func afterStow(_ f: @escaping () -> Void) {
        guard let g = stowing else { return f() }
        g.notify(queue: .main, execute: f)
    }

    /// While pictures stand in for the strip, the real windows wait just past the
    /// screen edge, so the live desktop (a moving wallpaper, widgets) shows between
    /// the pictures. 1pt stays on screen so macOS doesn't hand them to another
    /// display; they go out on the side that has no display next to it.
    /// All windows move at once, each on its own thread, so one busy app doesn't hold
    /// up the rest; `done` runs on the main thread when they're out (or after 0.3s).
    private func stowWindows(done: @escaping () -> Void) {
        guard let screen else { return done() }
        let frame = screen.axFrame
        let neighbourRight = NSScreen.screens.contains { s in
            let f = s.axFrame
            return s != screen && f.minX >= frame.maxX - 1 && f.minY < frame.maxY && f.maxY > frame.minY
        }
        let moves = columns.map { c -> (AXWindow, CGPoint) in
            let slot = slot(x: 0, column: c)
            return (c.window, CGPoint(x: neighbourRight ? frame.minX - slot.width + 1 : frame.maxX - 1, y: slot.minY))
        }
        let group = DispatchGroup()
        for (w, p) in moves {
            group.enter()
            DispatchQueue.global(qos: .userInteractive).async {
                w.setPosition(p)
                group.leave()
            }
        }
        stowing = group
        var fired = false
        let fire = {
            guard !fired else { return }
            fired = true
            done()
        }
        group.notify(queue: .main) { [weak self] in
            if self?.stowing === group { self?.stowing = nil }
            fire()
            if Debug.enabled {
                let stuck = moves.filter { w, p in abs((w.frame?.minX ?? p.x) - p.x) > 2 }.map { $0.0.bundleID ?? "?" }
                if !stuck.isEmpty { Debug.log("strip: stow refused by \(stuck)") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: fire)
    }

    private func render() {
        pad?.update(offset: offset)
        if let proxy { proxy.layout(trueFrames()) } else { applyPositions() }
    }

    /// Motion ended: move the real windows once, then lift the picture off.
    private func endMotion() {
        pad?.update(offset: offset)
        let p = proxy
        proxy = nil
        afterStow { [weak self] in
            guard let self, self.isActive else { p?.close(); return }
            // A new motion that started meanwhile keeps the windows out.
            if self.proxy == nil && self.overview == nil {
                self.applyFrames()
                self.fitColumnsToWindows()
            }
            if let p { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { p.close() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshSnapshots() }
        }
    }

    /// Columns at least half on screen: a parked window's picture would come out blank.
    private func mostlyVisibleColumns() -> [CGWindowID] {
        trueFrames().filter { _, f in
            let v = f.intersection(area)
            return !v.isNull && v.width >= f.width * 0.5
        }.map(\.0)
    }

    /// Fresh pictures of every column, taken off the main thread.
    /// Every column, parked ones too, as it looks now at its column size.
    private func refreshSnapshots() {
        guard isActive, WindowCapture.hasPermission else { return }
        WindowCapture.capture(columns.map(\.id)) { [weak self] shots in
            guard let self, self.isActive else { return }
            self.snapshots.merge(shots) { $1 }
        }
    }

    // MARK: Following the windows

    private var adoptWork: DispatchWorkItem?

    /// Hears the column's window close or minimize (sent to the window itself) and its
    /// app open new windows.
    private func watch(_ c: Column) {
        let pid = c.window.pid
        if watchers[pid] == nil {
            watchers[pid] = AXWatch(pid: pid, notifications: [kAXWindowCreatedNotification]) { [weak self] note in
                self?.windowEvent(note)
            }
        }
        watchers[pid]?.add(c.window.element, kAXUIElementDestroyedNotification)
        watchers[pid]?.add(c.window.element, kAXWindowMiniaturizedNotification)
    }

    private func windowEvent(_ note: String) {
        switch note {
        case kAXWindowCreatedNotification:
            adoptSoon()
        default:
            dropGoneColumns()
        }
    }

    /// Closed or minimized windows give up their place.
    /// Columns whose window left: closed, minimized, or put away — many apps only
    /// order a window out when it's closed, with no destroyed notice. Off screen alone
    /// isn't enough: App Exposé and Mission Control take other apps' windows off screen
    /// too, and when none of the strip is on screen it's another Space. So a window
    /// that's off screen leaves only if it's destroyed, minimized, or gone from its
    /// app's window list (where an ordered-out window no longer appears). Window-server
    /// lookups first: the apps are only asked about windows already off screen.
    private func goneColumns() -> [CGWindowID] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreen = Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        let off = columns.filter { !onScreen.contains($0.id) }
        guard !off.isEmpty, off.count < columns.count else { return [] }
        var listed: [pid_t: Set<CGWindowID>?] = [:]
        return off.filter { c in
            if AXWindow.serverFrame(of: c.id) == nil { return true }
            let pid = c.window.pid
            if listed[pid] == nil { listed[pid] = AXWindow.windowIDs(of: pid) }
            // No answer from the app: keep the window rather than guess.
            guard let ids = listed[pid] ?? nil else { return false }
            return !ids.contains(c.id) || c.window.isMinimized
        }.map(\.id)
    }

    private func dropGoneColumns() {
        let gone = goneColumns()
        guard !gone.isEmpty else { return }
        Debug.log("strip: dropping \(gone) (closed or minimized)")
        // A minimized window gets its own frame back now, so it unminimizes where it was.
        for id in gone {
            if let w = originalWindows[id], let f = originals[id], AXWindow.serverFrame(of: id) != nil { w.setFrame(f) }
        }
        columns.removeAll { gone.contains($0.id) }
        if columns.isEmpty { exit(); return }
        offset = clamp(offset)
        endMotion()
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
        guard isActive, let screen else { return }
        dropGoneColumns()
        let known = Set(columns.map(\.id))
        let fresh = Self.windows(on: screen).filter { !known.contains($0.0) }
        guard !fresh.isEmpty else { return }
        let focusedID = AXWindow.focused()?.cgWindowID
        var insertAt = (columns.firstIndex { $0.id == focusedID }).map { $0 + 1 } ?? columns.count
        var lastID: CGWindowID?
        for (id, w, f) in fresh {
            originals[id] = f
            originalWindows[id] = w
            if WindowCapture.hasPermission, let img = WindowCapture.snapshot(id) { snapshots[id] = img }
            let share = Self.presets.min { abs($0 - f.width / area.width) < abs($1 - f.width / area.width) }!
            let c = Column(id: id, window: w, width: (area.width * share).rounded())
            insertAt = min(insertAt, columns.count)
            columns.insert(c, at: insertAt)
            insertAt += 1
            watch(c)
            lastID = id
        }
        ParkedJournal.record("strip", columns.compactMap { c in originals[c.id].map { (c.window, $0) } })
        applyFrames()
        fitColumnsToWindows()
        if let lastID { scroll(toColumnOf: lastID) }
        Debug.log("strip: adopted \(fresh.count) new window(s), now \(columns.count) columns")
    }

    /// The pointer is in the top band (title bar) of a strip column that's on top
    /// there. Pure geometry from the window server: no app is asked anything.
    func pointerOnColumnTitlebar(_ p: CGPoint) -> Bool {
        guard isActive, area.contains(p) || p.y >= area.minY - 2,
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
        guard monitors.isEmpty else { return }
        // A closed window leaves the strip and its neighbours close the gap, each
        // keeping its own width. Not mid-move: the windows are stepped aside then.
        goneCheck = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.proxy == nil, self.overview == nil, self.stowing == nil else { return }
            self.dropGoneColumns()
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in self?.pointerMoved() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in self?.pointerClicked() }) {
            monitors.append(m)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.adoptSoon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let self, let id = AXWindow.focused()?.cgWindowID,
                      let i = self.columns.firstIndex(where: { $0.id == id }), self.isParked(i, at: self.offset) else { return }
                self.scroll(toColumnOf: id)
            }
        }
    }

    private func removeMonitors() {
        goneCheck?.invalidate()
        goneCheck = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
    }

    /// The parked column whose sliver is under the pointer, if any.
    private func sliverColumn(at p: CGPoint) -> Int? {
        guard area.contains(CGPoint(x: area.midX, y: p.y)) else { return nil }
        let leftZone = p.x - area.minX <= Self.sliver, rightZone = area.maxX - p.x <= Self.sliver
        guard leftZone || rightZone else { return nil }
        let parked = columns.indices.filter { isParked($0, at: offset) }
        // The nearest parked column on that side.
        if leftZone { return parked.filter { area.minX + start(of: $0) - offset < area.minX }.last }
        return parked.filter { area.minX + start(of: $0) - offset >= area.maxX - Self.sliver }.first
    }

    private func pointerMoved() {
        let p = Geometry.mouseAX
        if p.x - area.minX < 14 || area.maxX - p.x < 14 { Debug.log("strip: pointer at edge \(p) sliver=\(String(describing: sliverColumn(at: p)))") }
        guard let i = sliverColumn(at: p) else {
            peekWork?.cancel()
            closePeek()
            return
        }
        guard peek?.windowID != columns[i].id, peekWork == nil || peekWork!.isCancelled else { return }
        let id = columns[i].id
        let w = DispatchWorkItem { [weak self] in
            guard let self, let j = self.sliverColumn(at: Geometry.mouseAX), self.columns[j].id == id else { return }
            self.showPeek(j, pointer: Geometry.mouseAX)
        }
        peekWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func pointerClicked() {
        guard let i = sliverColumn(at: Geometry.mouseAX) else { return }
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
        guard isActive, overview == nil else { return }
        animation?.invalidate()
        proxy?.close(); proxy = nil
        closePeek()
        dropGoneColumns()
        guard isActive else { return }
        // Retake what's on screen right now, so the tiles you're looking at are current.
        for id in mostlyVisibleColumns() { if let img = WindowCapture.snapshot(id) { snapshots[id] = img } }
        let images = snapshots
        Debug.log("strip: overview with pictures for \(columns.filter { images[$0.id] != nil }.count)/\(columns.count); missing \(columns.filter { images[$0.id] == nil }.map { $0.window.bundleID ?? "?" })")
        var icons: [CGWindowID: NSImage] = [:]
        for c in columns { icons[c.id] = NSRunningApplication(processIdentifier: c.window.pid)?.icon }
        let o = StripOverview(area: area, images: images, icons: icons,
                              now: trueFrames(), overview: overviewFrames())
        o.onPick = { [weak self, weak o] id in
            guard let self, let o else { return }
            let target = self.visibleOffset(for: id)
            o.zoomIn(to: self.trueFrames(at: target)) {
                self.afterStow {
                    self.offset = target
                    self.applyFrames()
                    self.pad?.update(offset: target)
                    self.columns.first { $0.id == id }?.window.raise()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        o.close()
                        self.overview = nil
                    }
                }
            }
        }
        o.onDismiss = { [weak self, weak o] in
            // Held until it's closed: AppKit keeps a panel on screen after its owner lets go.
            guard let o else { return }
            self?.afterStow {
                self?.applyFrames()
                self?.overview = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { o.close() }
            }
        }
        overview = o
        // The tiles go up exactly over the windows; the windows step out from under
        // them, and only then does the view pull back, so no real window shows behind.
        o.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak o] in
            guard let self, let o, self.overview === o else { return }
            self.stowWindows { o.present() }
        }
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
    static var duration: CFTimeInterval {
        let d = UserDefaults.standard.double(forKey: "PanesOverviewDuration")   // debug override
        return d > 0 ? d : 0.65
    }

    init(area: CGRect, images: [CGWindowID: CGImage], icons: [CGWindowID: NSImage],
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
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let row = (overview.map(\.1.maxY).max() ?? area.midY) + 12
        let side = min(48, max(24, (overview.map(\.1.width).min() ?? 48) - 8))
        for (id, f) in overview {
            guard let icon = icons[id] else { continue }
            var rect = CGRect(x: 0, y: 0, width: side * scale, height: side * scale)
            let b = CALayer()
            b.contents = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            b.frame = StripProxy.local(CGRect(x: f.midX - side / 2, y: row, width: side, height: side), in: area)
            b.shadowOpacity = 0.35
            b.shadowRadius = 6
            b.shadowOffset = CGSize(width: 0, height: -2)
            b.opacity = 0
            root.addSublayer(b)
            badges.append(b)
        }
        view.onClick = { [weak self] p in self?.clicked(p) }
        panel.contentView = view
    }

    private func local(_ ax: CGRect) -> CGRect { StripProxy.local(ax, in: area) }

    /// Up over the windows, tiles exactly where the windows are: nothing changes yet.
    func show() { panel.orderFrontRegardless() }

    func present() {
        guard !dismissed else { return }
        panel.orderFrontRegardless()
        // Out: quick to leave, then easing gently into place.
        animate(to: target, timing: CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)) { [weak self] in
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
    private let area: CGRect

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
        for (id, img) in images {
            let l = CALayer()
            l.contents = img
            l.contentsGravity = .resize
            l.cornerRadius = 10
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

    func layout(_ frames: [(CGWindowID, CGRect)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, f) in frames { layers[id]?.frame = Self.local(f, in: area) }
        CATransaction.commit()
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }
    deinit { panel.orderOut(nil) }
}

/// The scroll pad: a strip-shaped map at the bottom left, as tall as the Dock.
/// Drag it like a scroll bar, or scroll the wheel over it — no Shift needed.
final class ScrollPad: NSPanel {
    var layout: () -> ([CGFloat], CGFloat, CGFloat) = { ([], 0, 1) }
    var onDrag: (CGFloat) -> Void = { _ in }
    var onRelease: (CGFloat) -> Void = { _ in }
    var onWheel: (CGFloat) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    private let view = PadView()
    var mapWidth: CGFloat { view.mapRect.width }

    init(screen: NSScreen) {
        let frame = Self.placement(on: screen)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
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

    /// Bottom left, as tall as the Dock, in the free space left of the Dock's icons;
    /// when there's no room there, just above the Dock. Never on top of the Dock.
    static func placement(on screen: NSScreen) -> CGRect {
        let f = screen.frame, vf = screen.visibleFrame
        let band = vf.minY - f.minY                              // Cocoa: a bottom Dock sits under the visible frame
        let width: CGFloat = 260
        guard band >= 30 else { return CGRect(x: vf.minX + 8, y: vf.minY + 8, width: width, height: 52) }
        let room = (dockIconsFrame().map { $0.minX } ?? f.midX) - f.minX - 16
        if room >= 140 {
            return CGRect(x: f.minX + 8, y: f.minY + 4, width: min(width, room), height: band - 8)
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

    func update(offset: CGFloat) {
        let (cols, start, visible) = layout()
        view.columns = cols
        view.viewport = (start, visible)
        view.needsDisplay = true
    }
}

private final class PadView: NSView {
    var columns: [CGFloat] = [] { didSet { map.columns = columns } }
    var viewport: (CGFloat, CGFloat) = (0, 1) { didSet { map.viewport = viewport; map.needsDisplay = true } }
    var onDrag: (CGFloat) -> Void = { _ in }
    var onRelease: (CGFloat) -> Void = { _ in }
    var onWheel: (CGFloat) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    private var last: (x: CGFloat, t: TimeInterval)?
    private var velocity: CGFloat = 0
    private let glass = NSVisualEffectView()
    private let map = MapView()

    var mapRect: CGRect { bounds.insetBy(dx: 12, dy: 10) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 12
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
        // Drawn above the glass (a parent's own drawing would sit underneath it).
        map.frame = bounds
        map.autoresizingMask = [.width, .height]
        addSubview(map)
        toolTip = "拖动或在上面滚动滚轮来滚动卷轴"
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

/// The strip in miniature: columns and the part on screen.
private final class MapView: NSView {
    var columns: [CGFloat] = []
    var viewport: (CGFloat, CGFloat) = (0, 1)

    override func draw(_ dirtyRect: NSRect) {
        let map = bounds.insetBy(dx: 12, dy: 10)
        var x = map.minX
        for (i, c) in columns.enumerated() {
            let w = map.width * c
            let r = CGRect(x: x + 1, y: map.minY, width: max(1, w - 2), height: map.height)
            NSColor.white.withAlphaComponent(i % 2 == 0 ? 0.30 : 0.20).setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            x += w
        }
        let vp = CGRect(x: map.minX + map.width * viewport.0, y: map.minY - 3, width: map.width * viewport.1, height: map.height + 6)
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        let path = NSBezierPath(roundedRect: vp, xRadius: 5, yRadius: 5)
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
