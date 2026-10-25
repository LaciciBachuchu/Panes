// Split dividers ("分屏分隔线"): when windows tile a screen (two halves, corners,
// thirds, grids — however they got there), each seam between them gets a small bar.
// Dragging it resizes the windows on both sides together; on release the seam lands on
// ⅓, ½ or ⅔ of its span.
// Adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// prototype/App/SplitView.swift and Core/SeamLayout.swift — find seams from the window
// server's window list only (no per-app queries), one bar per seam, every window
// touching the seam moves with it, landing on ⅓ / ½ / ⅔. WindowShade re-checks on a
// timer; Panes checks only when something happened (mouse released, Panes placed a
// window, app switched, Space changed).

import AppKit

final class SplitDividers {
    static let shared = SplitDividers()

    struct Seam {
        var vertical: Bool             // a vertical line (windows left/right of it)
        var position: CGFloat          // x (vertical) or y, AX space
        var span: ClosedRange<CGFloat> // along the line
        var before: [CGWindowID]       // left / above
        var after: [CGWindowID]        // right / below
        var extent: ClosedRange<CGFloat> // across: from the before windows' start to the after windows' end
    }

    private var bars: [DividerBar] = []
    private var seams: [Seam] = []
    private var monitors: [Any] = []
    private var observers: [Any] = []
    private var pending: DispatchWorkItem?
    private var drag: Drag?

    private final class Drag {
        let seam: Seam
        var position: CGFloat
        let windows: [CGWindowID: (AXWindow, CGRect)]
        var pendingApply = false
        init(seam: Seam, windows: [CGWindowID: (AXWindow, CGRect)]) {
            self.seam = seam; self.position = seam.position; self.windows = windows
        }
    }

    private var settings: SettingsData { Settings.shared.data }

    // MARK: Install / remove

    private var debugHook: Any?

    /// Debug mode only: drag the first bar by `dx` points in a few steps and let go,
    /// through the same begin/move/end path a real drag uses.
    private func installDebugHook() {
        guard Debug.enabled, debugHook == nil else { return }
        debugHook = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.thomas.panes.debug.divider"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let dx = (note.object as? String).flatMap(Double.init),
                  let bar = self.bars.first(where: { $0.isVisible }) else { return }
            self.beginDrag(bar)
            for i in 1...10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i)) { self.updateDrag(CGFloat(dx) / 10) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.endDrag() }
        }
    }

    func applySettings() {
        installDebugHook()
        if settings.splitDividersEnabled {
            install()
            soon()
        } else {
            remove()
        }
    }

    private func install() {
        guard monitors.isEmpty else { return }
        // Something may have moved or resized: look once the mouse is released.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in self?.soon() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in self?.hideWhileDragging() }) {
            monitors.append(m)
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.soon() })
        }
    }

    private func remove() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        pending?.cancel()
        show([])
    }

    /// Re-check shortly (windows finish moving a moment after the event).
    func soon() {
        guard settings.splitDividersEnabled, drag == nil else { return }
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    /// A press that isn't on one of our bars may start a window drag: get out of the way.
    private func hideWhileDragging() {
        guard drag == nil else { return }
        let m = NSEvent.mouseLocation
        if !bars.contains(where: { $0.frame.contains(m) }) { bars.forEach { $0.orderOut(nil) } }
    }

    // MARK: Finding seams

    private func refresh() {
        guard drag == nil else { return }
        show(Self.findSeams(gap: CGFloat(settings.gap)))
    }

    /// Windows that tile a screen: front to back, keep the ones that don't overlap
    /// what's already kept, until they cover nearly the whole visible frame.
    static func findSeams(gap: CGFloat) -> [Seam] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var all: [(CGWindowID, CGRect)] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width >= 120, r.height >= 80,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
                  !Settings.shared.isExcluded(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) else { continue }
            all.append((id, r))
        }
        var result: [Seam] = []
        for screen in NSScreen.screens {
            let vf = screen.axVisibleFrame
            var kept: [(CGWindowID, CGRect)] = []
            var covered: CGFloat = 0
            for (id, r) in all where NSScreen.screen(forAX: r) == screen {
                let clipped = r.intersection(vf)
                guard !clipped.isNull, clipped.width * clipped.height > 0.5 * r.width * r.height else { continue }
                if kept.contains(where: { $0.1.insetBy(dx: 3, dy: 3).intersects(r) }) {
                    // Something behind the tiled windows peeks out: ignore it; something
                    // in front of them breaks the tiling.
                    if covered < vf.width * vf.height * 0.97 { kept.removeAll(); covered = 0; break }
                    continue
                }
                kept.append((id, r))
                covered += clipped.width * clipped.height
                if covered >= vf.width * vf.height * 0.97 { break }
            }
            // Allow the gap's worth of uncovered area between windows.
            let slack = (vf.width + vf.height) * (gap * 2 + 4)
            guard kept.count >= 2, covered + slack >= vf.width * vf.height * 0.97 else { continue }
            result += seams(in: kept, area: vf, gap: gap)
        }
        return result
    }

    /// Lines where windows on one side end and windows on the other begin.
    static func seams(in windows: [(CGWindowID, CGRect)], area: CGRect, gap: CGFloat) -> [Seam] {
        let tol = gap + 6
        var out: [Seam] = []
        for vertical in [true, false] {
            // Candidate lines: every inner edge.
            let edges = windows.map { vertical ? $0.1.maxX : $0.1.maxY }
            var seen: [CGFloat] = []
            for e in edges where !seen.contains(where: { abs($0 - e) < tol }) {
                seen.append(e)
                let lo = vertical ? area.minX : area.minY, hi = vertical ? area.maxX : area.maxY
                guard e > lo + 40, e < hi - 40 else { continue }
                let before = windows.filter { abs((vertical ? $0.1.maxX : $0.1.maxY) - e) < tol }
                let after = windows.filter { abs((vertical ? $0.1.minX : $0.1.minY) - e - gap) < tol || abs((vertical ? $0.1.minX : $0.1.minY) - e) < tol }
                guard !before.isEmpty, !after.isEmpty else { continue }
                // The two sides must run alongside each other over the same stretch.
                func range(_ ws: [(CGWindowID, CGRect)]) -> ClosedRange<CGFloat> {
                    let a = ws.map { vertical ? $0.1.minY : $0.1.minX }.min()!
                    let b = ws.map { vertical ? $0.1.maxY : $0.1.maxX }.max()!
                    return a...b
                }
                let rb = range(before), ra = range(after)
                guard abs(rb.lowerBound - ra.lowerBound) < tol + 2, abs(rb.upperBound - ra.upperBound) < tol + 2 else { continue }
                let startAcross = before.map { vertical ? $0.1.minX : $0.1.minY }.min()!
                let endAcross = after.map { vertical ? $0.1.maxX : $0.1.maxY }.max()!
                out.append(Seam(vertical: vertical, position: e + gap / 2,
                                span: max(rb.lowerBound, ra.lowerBound)...min(rb.upperBound, ra.upperBound),
                                before: before.map(\.0), after: after.map(\.0), extent: startAcross...endAcross))
            }
        }
        return out
    }

    // MARK: Bars

    private func show(_ found: [Seam]) {
        seams = found
        while bars.count < found.count {
            let b = DividerBar()
            b.onBegin = { [weak self, weak b] in if let b { self?.beginDrag(b) } }
            b.onMove = { [weak self] delta in self?.updateDrag(delta) }
            b.onEnd = { [weak self] in self?.endDrag() }
            bars.append(b)
        }
        for (i, b) in bars.enumerated() {
            guard i < found.count else { b.orderOut(nil); continue }
            b.seamIndex = i
            b.place(seam: found[i], center: Self.barCenter(found[i], among: found))
            b.orderFrontRegardless()
        }
    }

    private func beginDrag(_ bar: DividerBar) {
        guard bar.seamIndex < seams.count else { return }
        let seam = seams[bar.seamIndex]
        var map: [CGWindowID: (AXWindow, CGRect)] = [:]
        for id in seam.before + seam.after {
            guard let f = AXWindow.serverFrame(of: id), let pid = Self.owner(of: id),
                  let w = AXWindow.windows(of: pid).first(where: { $0.cgWindowID == id }) else { continue }
            map[id] = (w, f)
        }
        drag = Drag(seam: seam, windows: map)
        // Other bars would be stale while this one moves.
        for b in bars where b !== bar { b.orderOut(nil) }
    }

    private func updateDrag(_ delta: CGFloat) {
        guard let d = drag else { return }
        let lo = d.seam.extent.lowerBound + 120, hi = d.seam.extent.upperBound - 120
        d.position = min(max(d.position + delta, lo), hi)
        let s = moved(d.seam, to: d.position)
        bars.first { $0.seamIndex < seams.count && $0.isVisible }?.place(seam: s, center: Self.barCenter(s, among: [s]))
        // Resizing makes apps re-layout: at most once per runloop pass.
        guard !d.pendingApply else { return }
        d.pendingApply = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let d = self.drag else { return }
            d.pendingApply = false
            self.apply(d, at: d.position)
        }
    }

    private func endDrag() {
        guard let d = drag else { return }
        // Land on ⅓, ½ or ⅔ of the span across the seam.
        let lo = d.seam.extent.lowerBound, len = d.seam.extent.upperBound - d.seam.extent.lowerBound
        let fraction = (d.position - lo) / len
        let stops: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3]
        let landed = stops.min { abs($0 - fraction) < abs($1 - fraction) }!
        apply(d, at: lo + len * landed)
        drag = nil
        soon()
    }

    /// Moves the seam: windows before it end there, windows after it start there.
    private func apply(_ d: Drag, at position: CGFloat) {
        let half = CGFloat(settings.gap) / 2
        for id in d.seam.before {
            guard let (w, f) = d.windows[id] else { continue }
            let r = d.seam.vertical
                ? CGRect(x: f.minX, y: f.minY, width: position - half - f.minX, height: f.height)
                : CGRect(x: f.minX, y: f.minY, width: f.width, height: position - half - f.minY)
            w.setFrame(r)
        }
        for id in d.seam.after {
            guard let (w, f) = d.windows[id] else { continue }
            let r = d.seam.vertical
                ? CGRect(x: position + half, y: f.minY, width: f.maxX - position - half, height: f.height)
                : CGRect(x: f.minX, y: position + half, width: f.width, height: f.maxY - position - half)
            w.setFrame(r)
        }
    }

    /// Middle of the seam, unless another seam crosses there (a grid's centre): then
    /// the middle of the longer piece on either side of the crossing.
    static func barCenter(_ seam: Seam, among all: [Seam]) -> CGPoint {
        var lo = seam.span.lowerBound, hi = seam.span.upperBound
        let mid = (lo + hi) / 2
        let crossings = all.filter { $0.vertical != seam.vertical && $0.span.contains(seam.position) }.map(\.position)
        if let c = crossings.min(by: { abs($0 - mid) < abs($1 - mid) }), abs(c - mid) < 50 {
            if c - lo >= hi - c { hi = c } else { lo = c }
        }
        let along = (lo + hi) / 2
        return seam.vertical ? CGPoint(x: seam.position, y: along) : CGPoint(x: along, y: seam.position)
    }

    private func moved(_ s: Seam, to p: CGFloat) -> Seam {
        var s = s; s.position = p; return s
    }

    private static func owner(of id: CGWindowID) -> pid_t? {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first?[kCGWindowOwnerPID as String] as? pid_t
    }
}

/// The small grab bar sitting on a seam.
final class DividerBar: NSPanel {
    var seamIndex = 0
    var onBegin: () -> Void = {}
    var onMove: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private let bar = BarView()
    private var vertical = true

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 14, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        bar.onBegin = { [weak self] in self?.onBegin() }
        bar.onMove = { [weak self] dx, dy in
            guard let self else { return }
            // Cocoa y grows up, AX y grows down.
            self.onMove(self.vertical ? dx : -dy)
        }
        bar.onEnd = { [weak self] in self?.onEnd() }
        contentView = bar
    }

    func place(seam: SplitDividers.Seam, center: CGPoint) {
        vertical = seam.vertical
        let size = seam.vertical ? CGSize(width: 14, height: 60) : CGSize(width: 60, height: 14)
        let ax = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        setFrame(Geometry.cocoaRect(fromAX: ax), display: true)
        bar.vertical = seam.vertical
        bar.needsDisplay = true
    }
}

private final class BarView: NSView {
    var vertical = true
    var onBegin: () -> Void = {}
    var onMove: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onEnd: () -> Void = {}
    private var last: CGPoint?
    private var hover = false

    override func draw(_ dirtyRect: NSRect) {
        let pill = vertical ? bounds.insetBy(dx: 3, dy: 2) : bounds.insetBy(dx: 2, dy: 3)
        let r = min(pill.width, pill.height) / 2
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: pill.insetBy(dx: -1, dy: -1), xRadius: r + 1, yRadius: r + 1).fill()
        (hover ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.9)).setFill()
        NSBezierPath(roundedRect: pill, xRadius: r, yRadius: r).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        last = NSEvent.mouseLocation
        onBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let l = last else { return }
        let m = NSEvent.mouseLocation
        last = m
        onMove(m.x - l.x, m.y - l.y)
    }

    override func mouseUp(with event: NSEvent) {
        last = nil
        onEnd()
    }
}
