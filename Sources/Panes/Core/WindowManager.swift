import AppKit

/// Executes window actions and keeps per-window history for restore and cycling.
final class WindowManager {
    static let shared = WindowManager()

    private struct CycleState { var actionID: UUID; var index: Int; var frame: CGRect }

    /// Frame before Panes first touched the window (for Restore and drag-away).
    private var original: [CGWindowID: CGRect] = [:]
    /// Last frame Panes set, used to tell whether the user moved it since.
    private var lastSet: [CGWindowID: CGRect] = [:]
    private var cycle: [CGWindowID: CycleState] = [:]

    private var settings: SettingsData { Settings.shared.data }

    // MARK: Public entry points

    func perform(_ action: WindowAction, on target: AXWindow? = nil) {
        switch action.kind {
        case .showPalette:
            PaletteController.shared.showForFocusedWindow()
            return
        case .rollUp, .pin, .magicTiling:
            return
        case .carry:
            CarryController.shared.toggle(target)
            return
        case .slideOver:
            SlideOverController.shared.toggle(target)
            return
        default:
            break
        }
        guard let w = target ?? AXWindow.focused() else { NSSound.beep(); return }
        guard !Settings.shared.isExcluded(w.bundleID), !w.isFullScreen else { return }
        guard let frame = w.frame, let screen = NSScreen.screen(forAX: frame) else { return }
        guard let dest = destination(for: action, window: w, frame: frame, screen: screen) else { return }
        apply(dest, to: w)
    }

    /// Places a window on a unit rect of a given screen (used by snap, palette, grid).
    func place(_ w: AXWindow, unit: UnitRect, on screen: NSScreen) {
        apply(targetFrame(unit: unit, screen: screen), to: w)
    }

    func apply(_ frame: CGRect, to w: AXWindow) {
        let id = w.cgWindowID
        if let id, let cur = w.frame {
            // Remember the "free" frame only if the user hasn't just come from one of ours.
            if original[id] == nil || !(lastSet[id].map { $0.roughlyEquals(cur) } ?? false) {
                original[id] = cur
            }
        }
        w.setFrame(frame.integral)
        if let id { lastSet[id] = w.frame ?? frame }
        SplitDividers.shared.soon()
    }

    /// Frame the window had before Panes moved it, if it is still sitting where Panes put it.
    func preSnapFrame(of w: AXWindow) -> CGRect? {
        guard let id = w.cgWindowID, let cur = w.frame,
              let set = lastSet[id], set.roughlyEquals(cur), let orig = original[id] else { return nil }
        return orig
    }

    func forget(_ w: AXWindow) {
        guard let id = w.cgWindowID else { return }
        original[id] = nil; lastSet[id] = nil; cycle[id] = nil
    }

    // MARK: Geometry

    /// Turns a unit rect into a concrete frame on a screen, honouring the window gap.
    func targetFrame(unit: UnitRect, screen: NSScreen) -> CGRect {
        let vf = screen.axVisibleFrame
        var r = vf.subrect(unit: unit.cgRect)
        let g = CGFloat(settings.gap)
        guard g > 0 else { return r }
        let eps: CGFloat = 2
        let left = abs(r.minX - vf.minX) < eps ? g : g / 2
        let right = abs(r.maxX - vf.maxX) < eps ? g : g / 2
        let top = abs(r.minY - vf.minY) < eps ? g : g / 2
        let bottom = abs(r.maxY - vf.maxY) < eps ? g : g / 2
        r.origin.x += left; r.origin.y += top
        r.size.width -= left + right; r.size.height -= top + bottom
        return r
    }

    private func screen(_ base: NSScreen, shiftedBy target: DisplayTarget) -> NSScreen {
        let all = NSScreen.ordered
        guard all.count > 1, let i = all.firstIndex(of: base) else { return base }
        switch target {
        case .current: return base
        case .next: return all[(i + 1) % all.count]
        case .previous: return all[(i - 1 + all.count) % all.count]
        }
    }

    private func destination(for action: WindowAction, window w: AXWindow, frame: CGRect, screen: NSScreen) -> CGRect? {
        let vf = screen.axVisibleFrame
        switch action.kind {
        case .unitRect:
            guard !action.rects.isEmpty else { return nil }
            let dest = self.screen(screen, shiftedBy: action.display)
            var idx = 0
            if let id = w.cgWindowID, let st = cycle[id], st.actionID == action.id,
               st.frame.roughlyEquals(frame, tolerance: 6), action.rects.count > 1 {
                idx = (st.index + 1) % action.rects.count
            }
            let r = targetFrame(unit: action.rects[idx], screen: dest)
            if let id = w.cgWindowID {
                // Store after the move so the next press can detect "still here".
                DispatchQueue.main.async { [weak self] in
                    self?.cycle[id] = CycleState(actionID: action.id, index: idx, frame: w.frame ?? r)
                }
            }
            return r

        case .maximize:
            return targetFrame(unit: .full, screen: screen)

        case .almostMaximize:
            let s = settings.almostMaximizeInset
            return targetFrame(unit: UnitRect((1 - s) / 2, (1 - s) / 2, s, s), screen: screen)

        case .maximizeHeight:
            let full = targetFrame(unit: .full, screen: screen)
            return CGRect(x: frame.minX, y: full.minY, width: frame.width, height: full.height)

        case .center:
            let w = min(frame.width, vf.width), h = min(frame.height, vf.height)
            return CGRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h)

        case .restore:
            guard let id = w.cgWindowID, let o = original[id] else { NSSound.beep(); return nil }
            original[id] = nil; lastSet[id] = nil; cycle[id] = nil
            w.setFrame(o)
            return nil

        case .nextDisplay, .previousDisplay:
            let dest = self.screen(screen, shiftedBy: action.kind == .nextDisplay ? .next : .previous)
            guard dest != screen else { NSSound.beep(); return nil }
            // Keep the window's relative placement; clamp to the new screen.
            let u = frame.unit(in: vf)
            let ux = max(0, min(u.minX, 1)), uy = max(0, min(u.minY, 1))
            let uw = min(u.width, 1), uh = min(u.height, 1)
            return dest.axVisibleFrame.subrect(unit: CGRect(x: min(ux, 1 - uw), y: min(uy, 1 - uh), width: uw, height: uh))

        case .larger, .smaller:
            let step = (action.kind == .larger ? 1 : -1) * CGFloat(0.05)
            let dx = vf.width * step / 2, dy = vf.height * step / 2
            var r = frame.insetBy(dx: -dx, dy: -dy)
            if r.width < 200 || r.height < 120 { return nil }
            r = r.intersection(vf)
            return r

        case .showPalette, .rollUp, .pin, .magicTiling, .carry, .slideOver:
            return nil
        }
    }
}
