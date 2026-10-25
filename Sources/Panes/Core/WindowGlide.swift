// Slides a window into place after a fling.
// Approach adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// prototype/App/WindowGlide.swift — frames run on their own serial queue and read the
// path by elapsed time (a slow frame is skipped, not stretched); the size is set once up
// front because resizing makes the app re-layout; if one AX call takes over 80ms the app
// can't keep up, so jump straight to the end; finish with a size/position calibration.

import AppKit
import ApplicationServices

final class WindowGlide {
    private static var active: [CGWindowID: WindowGlide] = [:]
    private let queue = DispatchQueue(label: "panes.glide", qos: .userInteractive)
    private let window: AXWindow
    private let from: CGRect
    private let to: CGRect
    private let duration: TimeInterval
    private var cancelled = false
    private let lock = NSLock()

    private init(window: AXWindow, from: CGRect, to: CGRect, duration: TimeInterval) {
        self.window = window; self.from = from; self.to = to; self.duration = duration
    }

    /// Glides `w` from its current frame to `to`. Main thread.
    static func glide(_ w: AXWindow, to: CGRect, duration: TimeInterval = 0.28, completion: (() -> Void)? = nil) {
        guard let from = w.frame else { w.setFrame(to); completion?(); return }
        let id = w.cgWindowID
        if let id { active[id]?.cancel() }
        let g = WindowGlide(window: w, from: from, to: to.integral, duration: duration)
        if let id { active[id] = g }
        g.run {
            if let id, active[id] === g { active[id] = nil }
            completion?()
        }
    }

    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func run(completion: @escaping () -> Void) {
        queue.async { [self] in
            let start = Date()
            func timed(_ body: () -> Void) -> TimeInterval {
                let t = Date(); body(); return Date().timeIntervalSince(t)
            }
            var frames: [TimeInterval] = []
            defer {
                let ms = frames.map { Int($0 * 1000) }
                Debug.log("glide: \(frames.count) frames in \(Int(Date().timeIntervalSince(start) * 1000))ms, per-call ms \(ms)")
            }
            // Resize once, at the start; from then on only the (cheap) position moves.
            var gaveUp = timed { window.setSize(to.size) } > 0.08
            while !gaveUp && !isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / duration)
                let e = 1 - pow(1 - t, 3)    // ease-out cubic: leaves at fling speed, settles gently
                let p = CGPoint(x: from.minX + (to.minX - from.minX) * e, y: from.minY + (to.minY - from.minY) * e)
                let spent = timed({ window.setPosition(p) })
                frames.append(spent)
                if spent > 0.08 { gaveUp = true }
                if t >= 1 { break }
                // Leave the app a breather between moves so it can draw; flooding it
                // makes every reply slower.
                usleep(8_000)
            }
            if !isCancelled { window.setFrame(to) }   // calibrate: size + position, twice inside
            DispatchQueue.main.async(execute: completion)
        }
    }
}

/// Undo history for gesture and fling placements (pinch-in undoes the last one),
/// and which windows were filled by a gesture (so "up" first undoes that fill).
final class GesturePlacements {
    static let shared = GesturePlacements()

    private struct Entry { var previous: CGRect; var placed: CGRect; var wasFill: Bool }
    private var stacks: [CGWindowID: [Entry]] = [:]

    func record(_ w: AXWindow, previous: CGRect, placed: CGRect, fill: Bool = false) {
        guard let id = w.cgWindowID else { return }
        var s = stacks[id] ?? []
        s.append(Entry(previous: previous, placed: placed, wasFill: fill))
        stacks[id] = Array(s.suffix(10))
    }

    /// The window is still sitting where a gesture "fill" put it.
    func gestureFilled(_ w: AXWindow) -> Bool {
        guard let id = w.cgWindowID, let last = stacks[id]?.last, let f = w.frame else { return false }
        return last.wasFill && last.placed.roughlyEquals(f, tolerance: 8)
    }

    /// Pops the last placement and returns the frame to go back to.
    func undo(_ w: AXWindow) -> CGRect? {
        guard let id = w.cgWindowID, var s = stacks[id], let last = s.popLast() else { return nil }
        stacks[id] = s
        return last.previous
    }

    func canUndo(_ w: AXWindow) -> Bool {
        guard let id = w.cgWindowID else { return false }
        return !(stacks[id]?.isEmpty ?? true)
    }
}

/// Where a gesture or fling sends a window, and the words for it.
struct Placement {
    enum Kind { case unfill, frame, undo }
    var kind: Kind
    var frame: CGRect?
    var title: String
    var fill = false
}

enum Side { case left, right }

extension WindowManager {
    /// The same ½ → ⅔ → ⅓ ladder as the Left/Right Half shortcuts; one more step past
    /// the last rung moves to the display on that side (landing on the half next to
    /// the shared edge), or back to the first rung when there is none.
    func ladder(_ w: AXWindow, side: Side) -> Placement? {
        guard let f = w.frame, let screen = NSScreen.screen(forAX: f) else { return nil }
        let rects = ladderRects(side)
        let names = side == .left ? ["左半屏", "左 ⅔", "左 ⅓"] : ["右半屏", "右 ⅔", "右 ⅓"]
        let current = rects.firstIndex { targetFrame(unit: $0, screen: screen).roughlyEquals(f, tolerance: 8) }
        func name(_ i: Int) -> String { i < names.count ? names[i] : (side == .left ? "左边第 \(i + 1) 档" : "右边第 \(i + 1) 档") }
        guard let i = current else {
            return Placement(kind: .frame, frame: targetFrame(unit: rects[0], screen: screen), title: name(0))
        }
        if i + 1 < rects.count {
            return Placement(kind: .frame, frame: targetFrame(unit: rects[i + 1], screen: screen), title: name(i + 1))
        }
        if let next = Self.screen(beside: screen, side: side) {
            let half: UnitRect = side == .left ? .rightHalf : .leftHalf
            return Placement(kind: .frame, frame: targetFrame(unit: half, screen: next),
                             title: side == .left ? "移到左边的显示器" : "移到右边的显示器")
        }
        return Placement(kind: .frame, frame: targetFrame(unit: rects[0], screen: screen), title: name(0))
    }

    func corner(_ w: AXWindow, side: Side, top: Bool) -> Placement? {
        guard let f = w.frame, let screen = NSScreen.screen(forAX: f) else { return nil }
        let u = UnitRect(side == .left ? 0 : 0.5, top ? 0 : 0.5, 0.5, 0.5)
        let title = (side == .left ? "左" : "右") + (top ? "上角" : "下角")
        return Placement(kind: .frame, frame: targetFrame(unit: u, screen: screen), title: title)
    }

    func half(_ w: AXWindow, side: Side) -> Placement? {
        guard let f = w.frame, let screen = NSScreen.screen(forAX: f) else { return nil }
        return Placement(kind: .frame, frame: targetFrame(unit: side == .left ? .leftHalf : .rightHalf, screen: screen),
                         title: side == .left ? "左半屏" : "右半屏")
    }

    func fill(_ w: AXWindow) -> Placement? {
        guard let f = w.frame, let screen = NSScreen.screen(forAX: f) else { return nil }
        return Placement(kind: .frame, frame: targetFrame(unit: .full, screen: screen), title: "铺满", fill: true)
    }

    /// The rects of the user's Left/Right Half action (falls back to ½ ⅔ ⅓).
    private func ladderRects(_ side: Side) -> [UnitRect] {
        let first: UnitRect = side == .left ? .leftHalf : .rightHalf
        if let a = Settings.shared.data.actions.first(where: { $0.kind == .unitRect && $0.rects.first == first }) {
            return a.rects
        }
        let t = 1.0 / 3.0
        return side == .left
            ? [.leftHalf, UnitRect(0, 0, 2 * t, 1), UnitRect(0, 0, t, 1)]
            : [.rightHalf, UnitRect(t, 0, 2 * t, 1), UnitRect(2 * t, 0, t, 1)]
    }

    private static func screen(beside s: NSScreen, side: Side) -> NSScreen? {
        let f = s.frame
        let candidates = NSScreen.screens.filter { o in
            o != s && o.frame.maxY > f.minY && o.frame.minY < f.maxY &&
                (side == .left ? o.frame.maxX <= f.minX + 1 : o.frame.minX >= f.maxX - 1)
        }
        return candidates.min { abs($0.frame.midX - f.midX) < abs($1.frame.midX - f.midX) }
    }

    /// Carries out a placement for a gesture or fling, recording it for undo.
    func execute(_ p: Placement, on w: AXWindow, animated: Bool) {
        switch p.kind {
        case .unfill, .undo:
            guard let back = GesturePlacements.shared.undo(w) else { NSSound.beep(); return }
            if animated { WindowGlide.glide(w, to: back) } else { w.setFrame(back) }
        case .frame:
            guard let target = p.frame, let cur = w.frame else { return }
            GesturePlacements.shared.record(w, previous: cur, placed: target, fill: p.fill)
            if animated {
                WindowGlide.glide(w, to: target)
            } else {
                apply(target, to: w)
            }
        }
    }
}
