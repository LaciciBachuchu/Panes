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
        Debug.log("strip: \(columns.count) columns, total \(Int(totalWidth))pt")
        GestureHUD.shared.flash("卷轴：\(columns.count) 列", symbol: "rectangle.split.3x1", anchor: CGPoint(x: area.midX, y: area.minY + 40))
    }

    func exit() {
        guard isActive else { return }
        animation?.invalidate()
        closePeek()
        overview?.close(); overview = nil
        for c in columns { if let f = originals[c.id] { c.window.setFrame(f) } }
        columns = []
        originals = [:]
        watchers = [:]
        removeMonitors()
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

    /// Finger movement (content direction): the strip follows 1:1.
    func scroll(by dx: CGFloat) {
        animation?.invalidate()
        closePeek()
        // Past the ends it moves at a third of the speed (rubber band).
        let next = offset - dx
        offset = (next < 0 || next > maxOffset) ? offset - dx / 3 : next
        applyPositions()
    }

    /// Fingers lifted with a velocity (pt/s, content direction): coast, then stop on a column edge.
    func release(velocity v: CGFloat) {
        // iOS-style projection with deceleration rate 0.998 per ms.
        let projected = offset - v / 1000 * 0.998 / (1 - 0.998)
        animate(to: snapped(projected))
    }

    /// One column left or right (mouse wheel, keyboard).
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

    /// Ease the offset to a target (~0.3s); positions only, full frames at the end.
    private func animate(to target: CGFloat) {
        animation?.invalidate()
        let from = offset, began = Date(), duration = 0.3
        guard abs(target - from) > 0.5 else { offset = clamp(target); applyFrames(); return }
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let k = min(1, Date().timeIntervalSince(began) / duration)
            let e = 1 - pow(1 - k, 3)
            self.offset = from + (target - from) * e
            if k >= 1 {
                t.invalidate()
                self.offset = target
                self.applyFrames()
            } else {
                self.applyPositions()
            }
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
