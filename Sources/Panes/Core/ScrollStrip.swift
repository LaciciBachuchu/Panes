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
    private var activationObserver: Any?
    private var peek: PeekCard?
    private var peekWork: DispatchWorkItem?
    private var overview: StripOverview?

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
        refreshSnapshots()
        backdrop = DesktopBackdrop.image(for: s)
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
        snapshots = [:]
        backdrop = nil
        closePeek()
        overview?.close(); overview = nil
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

    /// Some windows won't grow to the column (small fixed-size panels, minimum/maximum
    /// sizes). Read back what each one actually took and size its column to that, so
    /// nothing is pictured stretched.
    private func fitColumnsToWindows() {
        var changed = false
        for i in columns.indices {
            let want = frame(of: i, at: offset)
            guard let got = columns[i].window.frame else { continue }
            if got.width < want.width - 4 { columns[i].width = got.width + gap; changed = true }
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
    /// The desktop picture, taken when the strip starts: the backdrop for pictures.
    private var backdrop: CGImage?
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
        let p = StripProxy(area: area, screen: screen, images: snapshots, backdrop: backdrop)
        p.layout(trueFrames())
        p.show()
        proxy = p
    }

    private func render() {
        pad?.update(offset: offset)
        if let proxy { proxy.layout(trueFrames()) } else { applyPositions() }
    }

    /// Motion ended: move the real windows once, then lift the picture off.
    private func endMotion() {
        applyFrames()
        pad?.update(offset: offset)
        if let p = proxy {
            proxy = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { p.close() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshSnapshots() }
    }

    /// Columns at least half on screen: a parked window's picture would come out blank.
    private func mostlyVisibleColumns() -> [CGWindowID] {
        trueFrames().filter { _, f in
            let v = f.intersection(area)
            return !v.isNull && v.width >= f.width * 0.5
        }.map(\.0)
    }

    /// Fresh pictures of every column, taken off the main thread.
    private func refreshSnapshots() {
        guard isActive, WindowCapture.hasPermission else { return }
        let ids = mostlyVisibleColumns()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var shots: [CGWindowID: CGImage] = [:]
            for id in ids { if let img = WindowCapture.snapshot(id) { shots[id] = img } }
            DispatchQueue.main.async { self?.snapshots.merge(shots) { $1 } }
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
    private func dropGoneColumns() {
        let gone = columns.filter { AXWindow.serverFrame(of: $0.id) == nil || $0.window.isMinimized }.map(\.id)
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

    /// The whole strip at a glance (double-click the pad, or pinch out on a title
    /// bar): the screen zooms out from where things are now; pick a window and it
    /// zooms back in onto that window's column.
    func showOverview() {
        guard isActive, overview == nil else { return }
        animation?.invalidate()
        proxy?.close(); proxy = nil
        closePeek()
        // Retake what's on screen right now, so the tiles you're looking at are current.
        for id in mostlyVisibleColumns() { if let img = WindowCapture.snapshot(id) { snapshots[id] = img } }
        let images = snapshots
        Debug.log("strip: overview with pictures for \(columns.filter { images[$0.id] != nil }.count)/\(columns.count); missing \(columns.filter { images[$0.id] == nil }.map { $0.window.bundleID ?? "?" })")
        if backdrop == nil, let screen { backdrop = DesktopBackdrop.image(for: screen) }
        let o = StripOverview(area: area, screen: screen, backdrop: backdrop, images: images,
                              now: trueFrames(), overview: overviewFrames())
        o.onPick = { [weak self, weak o] id in
            guard let self, let o else { return }
            let target = self.visibleOffset(for: id)
            o.zoomIn(to: self.trueFrames(at: target)) {
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
        o.onDismiss = { [weak self] in self?.overview = nil }
        overview = o
        o.present()
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

/// The zoomed-out strip, GTA-map style: the desktop picture dims behind, and every
/// tile starts exactly where its window is, then shrinks out to the overview; picking
/// one zooms back in onto that column. Animations are explicit (from → to) so they
/// play even on the panel's very first frame.
final class StripOverview: NSObject {
    var onPick: (CGWindowID) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    private let panel: NSPanel
    private let root = CALayer()
    private let backdropLayer = CALayer()
    private let dim = CALayer()
    private var tiles: [CGWindowID: CALayer] = [:]
    private let area: CGRect
    private let now: [(CGWindowID, CGRect)]
    private let target: [(CGWindowID, CGRect)]
    private var keyMonitor: Any?
    private var busy = false
    static var duration: CFTimeInterval {
        let d = UserDefaults.standard.double(forKey: "PanesOverviewDuration")   // debug override
        return d > 0 ? d : 0.65
    }

    init(area: CGRect, screen: NSScreen?, backdrop: CGImage?, images: [CGWindowID: CGImage],
         now: [(CGWindowID, CGRect)], overview: [(CGWindowID, CGRect)]) {
        self.area = area
        self.now = now
        self.target = overview
        panel = NSPanel(contentRect: Geometry.cocoaRect(fromAX: area), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.level = .floating
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        let view = OverviewView(frame: CGRect(origin: .zero, size: area.size))
        // Layer-hosting: give the view our layer first, then turn layers on, or
        // AppKit takes the tree over and drops our animations.
        view.layer = root
        view.wantsLayer = true
        root.backgroundColor = NSColor.black.cgColor
        // The desktop, and a dimmer over it that deepens as the view pulls back.
        backdropLayer.contents = backdrop
        backdropLayer.contentsGravity = .resizeAspectFill
        backdropLayer.frame = screen.map { StripProxy.local($0.axFrame, in: area) } ?? root.bounds
        root.addSublayer(backdropLayer)
        dim.frame = CGRect(origin: .zero, size: area.size)
        dim.backgroundColor = NSColor.black.cgColor
        dim.opacity = 0
        root.addSublayer(dim)
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
        view.onClick = { [weak self] p in self?.clicked(p) }
        panel.contentView = view
    }

    private func local(_ ax: CGRect) -> CGRect { StripProxy.local(ax, in: area) }

    func present() {
        panel.orderFrontRegardless()
        animate(to: target, dim: 0.5, backdropScale: 0.94) {}
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.dismiss() }        // Esc
        }
    }

    /// Glide every tile (and the backdrop's pull-back) to a state, explicitly.
    private func animate(to frames: [(CGWindowID, CGRect)], dim toDim: Float, backdropScale: CGFloat, done: @escaping () -> Void) {
        busy = true
        // A gentle start, then a long glide in: the pull-back reads as a camera move.
        let timing = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.15, 1)
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
        let fromDim = dim.presentation()?.opacity ?? dim.opacity
        dim.opacity = toDim
        animate(dim, "opacity", from: fromDim, to: toDim)
        let fromT = backdropLayer.presentation()?.transform ?? backdropLayer.transform
        let toT = CATransform3DMakeScale(backdropScale, backdropScale, 1)
        backdropLayer.transform = toT
        animate(backdropLayer, "transform", from: NSValue(caTransform3D: fromT), to: NSValue(caTransform3D: toT))
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
        animate(to: frames, dim: 0, backdropScale: 1, done: done)
    }

    /// Esc or a click on empty space: zoom back to how things were.
    func dismiss() {
        guard !busy else { return }
        zoomIn(to: now) { [weak self] in
            self?.close()
            self?.onDismiss()
        }
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        panel.orderOut(nil)
    }

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

/// Pictures of every column sliding over the screen while the strip moves, on top
/// of the desktop picture (so around short windows it looks like the desktop, and the
/// real windows' stale positions don't show through).
final class StripProxy {
    private let panel: NSPanel
    private let root = CALayer()
    private var layers: [CGWindowID: CALayer] = [:]
    private let area: CGRect

    init(area: CGRect, screen: NSScreen?, images: [CGWindowID: CGImage], backdrop: CGImage?) {
        self.area = area
        panel = NSPanel(contentRect: Geometry.cocoaRect(fromAX: area), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        // No zoom-out when it goes away: the real windows are already in place.
        panel.animationBehavior = .none
        let v = NSView(frame: CGRect(origin: .zero, size: area.size))
        v.layer = root
        v.wantsLayer = true
        root.backgroundColor = NSColor.windowBackgroundColor.cgColor
        if let backdrop, let screen {
            let bg = CALayer()
            bg.contents = backdrop
            bg.contentsGravity = .resizeAspectFill
            bg.frame = Self.local(screen.axFrame, in: area)
            root.addSublayer(bg)
        }
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
        let f = screen.frame, vf = screen.visibleFrame
        let dock = vf.minY - f.minY                  // Cocoa: the Dock sits under the visible frame
        let height = dock >= 30 ? dock - 8 : 52
        let y = dock >= 30 ? f.minY + 4 : vf.minY + 8
        super.init(contentRect: CGRect(x: f.minX + 8, y: y, width: 260, height: height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(NSWindow.Level.dock.rawValue + 1)
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        view.frame = CGRect(x: 0, y: 0, width: 260, height: height)
        view.onDrag = { [weak self] in self?.onDrag($0) }
        view.onRelease = { [weak self] in self?.onRelease($0) }
        view.onWheel = { [weak self] in self?.onWheel($0) }
        view.onDoubleClick = { [weak self] in self?.onDoubleClick() }
        contentView = view
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
