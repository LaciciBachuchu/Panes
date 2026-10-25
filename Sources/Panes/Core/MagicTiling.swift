// Magic tiling ("魔法平铺"): arrange every visible window on the current display so
// they fill it without overlapping, once — afterwards windows move freely again;
// the same shortcut undoes it.
// Planning adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// prototype/Core/MagicTiling.swift — pick the window that needs the most room as the
// main one (browsers, editors, design tools over notes/terminals over light utilities;
// the focused window and already-large windows score extra), give it 5:5 / 6:4 / 7:3
// against the rest, keep it on the side it's already on, and stack the others beside it
// in their current order; portrait screens split top/bottom. WindowShade tucks windows
// that don't fit into the notch; Panes has no notch, so the side area grows into a grid
// instead and every visible window gets a place.

import AppKit

final class MagicTiling {
    static let shared = MagicTiling()

    struct Candidate {
        let window: AXWindow
        let id: CGWindowID
        let bundleID: String?
        let frame: CGRect
        let focused: Bool
    }

    private struct Applied { var screen: CGDirectDisplayID; var previous: [(AXWindow, CGRect)]; var placed: [(AXWindow, CGRect)] }
    private var last: Applied?

    // MARK: Entry points

    /// Hotkey: undo the last tiling if it's still in place, else tile.
    func toggle() {
        if canUndo { undo() } else { tile() }
    }

    /// The previous tiling is still (mostly) where it was put.
    var canUndo: Bool {
        guard let last else { return false }
        let still = last.placed.filter { w, f in w.frame.map { $0.roughlyEquals(f, tolerance: 8) } ?? false }
        return still.count * 2 >= last.placed.count
    }

    func tile() {
        guard Settings.shared.data.magicTilingEnabled else { return }
        let screen = AXWindow.focused().flatMap { $0.frame }.flatMap { NSScreen.screen(forAX: $0) }
            ?? NSScreen.screen(containingAX: Geometry.mouseAX) ?? NSScreen.main
        guard let screen else { return }
        let windows = Self.candidates(on: screen)
        guard !windows.isEmpty else { NSSound.beep(); return }
        let units = Self.plan(windows, area: screen.axVisibleFrame)
        var previous: [(AXWindow, CGRect)] = []
        var placed: [(AXWindow, CGRect)] = []
        for (c, unit) in units {
            // Round edges (not .integral, which grows the rect) so neighbours meet exactly.
            let r = WindowManager.shared.targetFrame(unit: unit, screen: screen)
            let x = r.minX.rounded(), y = r.minY.rounded()
            let target = CGRect(x: x, y: y, width: r.maxX.rounded() - x, height: r.maxY.rounded() - y)
            previous.append((c.window, c.frame))
            c.window.setFrame(target)
            placed.append((c.window, c.window.frame ?? target))
        }
        last = Applied(screen: screen.displayID, previous: previous, placed: placed)
        Debug.log("magic: tiled \(placed.count) windows")
    }

    func undo() {
        guard let l = last else { return }
        last = nil
        for (w, f) in l.previous { w.setFrame(f) }
    }

    // MARK: Which windows

    /// Visible standard windows on a display, front to back.
    static func candidates(on screen: NSScreen) -> [Candidate] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let focusedID = AXWindow.focused()?.cgWindowID
        var byPid: [pid_t: [AXWindow]] = [:]
        var out: [Candidate] = []
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
                  !w.isFullScreen, w.isResizable, let f = w.frame else { continue }
            out.append(Candidate(window: w, id: id, bundleID: app?.bundleIdentifier, frame: f, focused: id == focusedID))
        }
        return out
    }

    // MARK: Planning (pure)

    enum Role: Int { case light = 0, reference, wide }

    private static let wide: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox", "com.microsoft.edgemac",
        "com.brave.Browser", "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.figma.Desktop", "com.bohemiancoding.sketch3", "com.apple.FinalCut", "com.apple.Keynote", "com.apple.iWork.Keynote",
        "com.apple.iWork.Numbers", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.apple.Maps",
    ]
    private static let widePrefixes = ["com.jetbrains.", "com.adobe.", "com.affinity."]
    private static let light: Set<String> = [
        "com.apple.finder", "com.apple.iCal", "com.apple.reminders", "com.apple.Music", "com.spotify.client",
        "com.apple.systempreferences", "com.apple.calculator", "com.apple.Photos", "com.apple.ActivityMonitor",
        "com.apple.MobileSMS", "com.tencent.xinWeChat", "com.tencent.qq", "ru.keepcoder.Telegram", "com.tinyspeck.slackmacgap",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp",
    ]

    static func role(_ bundleID: String?) -> Role {
        guard let id = bundleID else { return .reference }
        if wide.contains(id) || widePrefixes.contains(where: id.hasPrefix) { return .wide }
        if light.contains(id) { return .light }
        return .reference
    }

    static func demand(_ r: Role) -> CGFloat {
        switch r { case .wide: return 3; case .reference: return 2; case .light: return 1.3 }
    }

    /// Main window's share of the long side: 0.5 / 0.6 / 0.7, stepping down when the
    /// side would get narrower than `minSide`.
    static func share(main: CGFloat, side: CGFloat, extent: CGFloat, minSide: CGFloat) -> CGFloat {
        let raw = main / max(0.01, main + side)
        var s: CGFloat = raw < 0.55 ? 0.5 : raw < 0.65 ? 0.6 : 0.7
        while s > 0.5, extent * (1 - s) < minSide { s -= 0.1 }
        return (s * 10).rounded() / 10
    }

    /// Unit rects (of the visible frame) for each window; together they tile it.
    static func plan(_ windows: [Candidate], area: CGRect) -> [(Candidate, UnitRect)] {
        guard !windows.isEmpty, area.width > 0, area.height > 0 else { return [] }
        let screenArea = area.width * area.height
        func score(_ c: Candidate) -> CGFloat {
            demand(role(c.bundleID)) + (c.focused ? 0.6 : 0) + 0.4 * min(1, c.frame.width * c.frame.height / screenArea)
        }
        let ranked = windows.enumerated().sorted { a, b in
            let (sa, sb) = (score(a.element), score(b.element))
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
        let main = ranked[0]
        guard ranked.count > 1 else { return [(main, .full)] }

        let vertical = area.height > area.width * 1.05
        let side = Array(ranked.dropFirst())
        let sideDemand = (side.map { demand(role($0.bundleID)) }.max() ?? 1) + 0.3 * CGFloat(min(side.count, 3) - 1)
        let extent = vertical ? area.height : area.width
        let s = share(main: demand(role(main.bundleID)) + (main.focused ? 0.6 : 0), side: sideDemand,
                      extent: extent, minSide: vertical ? 320 : 420)
        // Keep the main window on the side it's on now: least movement.
        let mainLeading = vertical ? main.frame.midY <= area.midY : main.frame.midX <= area.midX
        var out: [(Candidate, UnitRect)] = []
        let sideStart = mainLeading ? s : 0
        if vertical {
            out.append((main, UnitRect(0, mainLeading ? 0 : 1 - s, 1, s)))
        } else {
            out.append((main, UnitRect(mainLeading ? 0 : 1 - s, 0, s, 1)))
        }

        // Side area: as many rows (columns on portrait) as fit, then more lanes.
        let perLane = vertical ? max(1, min(3, Int(area.width / 360))) : max(1, min(3, Int(area.height / 280)))
        let lanes = Int((Double(side.count) / Double(perLane)).rounded(.up))
        // Preserve relative positions: split into lanes along the long axis, then order within each lane.
        let byLong = side.sorted { vertical ? $0.frame.midY < $1.frame.midY : $0.frame.midX < $1.frame.midX }
        let laneSize = 1 - s
        var index = 0
        for lane in 0..<lanes {
            let remaining = side.count - index
            let count = Int((Double(remaining) / Double(lanes - lane)).rounded(.up))
            let members = Array(byLong[index..<index + count])
                .sorted { vertical ? $0.frame.midX < $1.frame.midX : $0.frame.midY < $1.frame.midY }
            index += count
            let laneStart = sideStart + laneSize * CGFloat(lane) / CGFloat(lanes)
            let laneWidth = laneSize / CGFloat(lanes)
            // Within a lane, roomier apps get a bit more.
            let total = members.map { demand(role($0.bundleID)) }.reduce(0, +)
            var cursor: CGFloat = 0
            for (i, c) in members.enumerated() {
                let piece = i == members.count - 1 ? 1 - cursor : demand(role(c.bundleID)) / total
                let u = vertical
                    ? UnitRect(cursor, laneStart, piece, laneWidth)
                    : UnitRect(laneStart, cursor, laneWidth, piece)
                out.append((c, u))
                cursor += piece
            }
        }
        return out
    }
}
