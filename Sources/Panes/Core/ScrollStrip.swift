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
    }

    private static let sliver: CGFloat = 10
    private static let presets: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3, 1]

    private var columns: [Column] = []
    private var originals: [CGWindowID: CGRect] = [:]
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
        // Written before anything moves, so a crash can't strand a window off screen.
        ParkedJournal.record("strip", found.map { ($0.1, $0.2) })
        // Columns in their current left-to-right order; widths snap to the presets.
        columns = found.sorted { $0.2.minX < $1.2.minX }.map { id, w, f in
            let share = Self.presets.min { abs($0 - f.width / area.width) < abs($1 - f.width / area.width) }!
            return Column(id: id, window: w, width: (area.width * share).rounded())
        }
        let focusIndex = columns.firstIndex { $0.id == focused?.cgWindowID } ?? 0
        offset = clamp(start(of: focusIndex))
        applyFrames()
        for c in columns { watch(c.window.pid) }
        installMonitors()
        refreshSnapshots()
        let p = ScrollPad(screen: s)
        p.layout = { [weak self] in self?.padModel() ?? ([], 0, 1) }
        p.onDrag = { [weak self] dx in self?.padDragged(dx) }
        p.onRelease = { [weak self] v in self?.padReleased(v) }
        p.onWheel = { [weak self] d in self?.wheel(by: d) }
        pad = p
        p.update(offset: offset)
        p.orderFrontRegardless()
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
        closePeek()
        overview?.close(); overview = nil
        for c in columns { if let f = originals[c.id] { c.window.setFrame(f) } }
        columns = []
        originals = [:]
        watchers = [:]
        removeMonitors()
        ParkedJournal.clear("strip")
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
        let r = CGRect(x: x, y: area.minY, width: c.width, height: area.height)
        return r.insetBy(dx: gap / 2, dy: gap > 0 ? gap : 0)
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
        animate(to: snapped(projected))
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
            self.animate(to: self.snapped(target))
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
    private func trueFrames() -> [(CGWindowID, CGRect)] {
        columns.indices.map { i in
            let r = CGRect(x: area.minX + start(of: i) - offset, y: area.minY, width: columns[i].width, height: area.height)
            return (columns[i].id, r.insetBy(dx: gap / 2, dy: gap > 0 ? gap : 0))
        }
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

    /// Fresh pictures of every column, taken off the main thread.
    private func refreshSnapshots() {
        guard isActive, WindowCapture.hasPermission else { return }
        let ids = columns.map(\.id)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var shots: [CGWindowID: CGImage] = [:]
            for id in ids { if let img = WindowCapture.snapshot(id) { shots[id] = img } }
            DispatchQueue.main.async { self?.snapshots.merge(shots) { $1 } }
        }
    }

    // MARK: Following the windows

    private func watch(_ pid: pid_t) {
        guard watchers[pid] == nil else { return }
        watchers[pid] = AXWatch(pid: pid, notifications: [kAXUIElementDestroyedNotification]) { [weak self] _ in
            guard let self else { return }
            let gone = self.columns.filter { AXWindow.serverFrame(of: $0.id) == nil }.map(\.id)
            guard !gone.isEmpty else { return }
            self.columns.removeAll { gone.contains($0.id) }
            if self.columns.isEmpty { self.exit(); return }
            self.offset = self.clamp(self.offset)
            self.applyFrames()
        }
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

    func showOverview() {
        guard isActive, overview == nil, let screen else { return }
        let items = columns.map { (id: $0.id, width: $0.width, image: WindowCapture.snapshot($0.id)) }
        let o = StripOverview(items: items, height: area.height, screen: screen)
        o.onPick = { [weak self] id in
            self?.overview = nil
            self?.scroll(toColumnOf: id)
            if let w = self?.columns.first(where: { $0.id == id })?.window { w.raise() }
        }
        o.onDismiss = { [weak self] in self?.overview = nil }
        overview = o
        o.present()
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

/// The whole strip scaled down across the screen; click a column to go there.
final class StripOverview: NSObject {
    var onPick: (CGWindowID) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    private let panel: NSPanel
    private var keyMonitor: Any?

    init(items: [(id: CGWindowID, width: CGFloat, image: CGImage?)], height: CGFloat, screen: NSScreen) {
        let bounds = screen.visibleFrame
        panel = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        let spacing: CGFloat = 16, margin: CGFloat = 48
        let total = items.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, items.count - 1))
        let scale = min(0.5, (bounds.width - 2 * margin) / max(1, total), (bounds.height - 2 * margin) / max(1, height))
        let content = OverviewView(frame: CGRect(origin: .zero, size: bounds.size))
        content.onBackground = { [weak self] in self?.close() }
        var x = (bounds.width - total * scale) / 2
        let h = height * scale
        for item in items {
            let w = item.width * scale
            let tile = OverviewTile(frame: CGRect(x: x, y: (bounds.height - h) / 2, width: w, height: h), image: item.image)
            tile.onClick = { [weak self] in
                self?.close(notify: false)
                self?.onPick(item.id)
            }
            content.addSubview(tile)
            x += w + spacing * scale
        }
        panel.contentView = content
    }

    func present() {
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.close() }        // Esc
        }
    }

    func close(notify: Bool = true) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        panel.orderOut(nil)
        if notify { onDismiss() }
    }

    private final class OverviewView: NSView {
        var onBackground: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseUp(with event: NSEvent) { onBackground() }
    }

    private final class OverviewTile: NSView {
        var onClick: () -> Void = {}
        init(frame: NSRect, image: CGImage?) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            let l = CALayer()
            l.frame = bounds
            l.contentsGravity = .resizeAspect
            l.contents = image
            layer?.addSublayer(l)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseUp(with event: NSEvent) { onClick() }
    }
}

/// Pictures of every column sliding over the screen while the strip moves.
final class StripProxy {
    private let panel: NSPanel
    private let root = CALayer()
    private var layers: [CGWindowID: CALayer] = [:]
    private let area: CGRect

    init(area: CGRect, images: [CGWindowID: CGImage]) {
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
        v.wantsLayer = true
        v.layer = root
        root.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.isGeometryFlipped = true          // lay out in AX-style top-down coordinates
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

    func layout(_ frames: [(CGWindowID, CGRect)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, f) in frames {
            layers[id]?.frame = f.offsetBy(dx: -area.minX, dy: -area.minY)
        }
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
