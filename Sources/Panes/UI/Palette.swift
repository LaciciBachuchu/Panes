import AppKit
import SwiftUI

/// Moom-style palette with preset placements and a drag grid.
/// Hovering a window's green button lets macOS show its own menu as usual; the
/// moment that menu appears, the palette opens right beside it and then lives
/// and dies with it (a click elsewhere closes both). The hotkey opens the
/// palette directly. Clicking the green button itself still works as normal.
final class PaletteController: NSObject {
    static let shared = PaletteController()

    private struct SystemMenu { var id: CGWindowID; var rect: CGRect }

    private var panel: PalettePanel?
    private let model = PaletteModel()
    private var target: AXWindow?
    private var systemMenu: SystemMenu?
    private var monitors: [Any] = []
    private var waiting: DispatchWorkItem?
    private var pendingButton: AXUIElement?
    private var lastMove = Date.distantPast
    private var restCheckScheduled = false
    private var pollTimer: Timer?
    /// Opened by hotkey: stays until Esc, a click elsewhere, or a pick.
    private var sticky = false

    private static let greenSubroles: Set<String> = ["AXZoomButton", "AXFullScreenButton"]

    func start() {
        stop()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in self?.mouseMoved() }) {
            monitors.append(m)
        }
        // Like the system menu: a click anywhere else dismisses.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.hide(animated: true) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, self.panel?.isVisible == true else { return e }
            return self.keyDown(e) ? nil : e
        }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hide(animated: false)
    }

    // MARK: Hover detection

    /// Mouse moves only stamp a time. The (comparatively costly) accessibility
    /// hit-test runs once the cursor has rested for a moment — the system menu
    /// needs a ~1s rest anyway — so moving the mouse around costs next to nothing.
    private func mouseMoved() {
        // A pending wait tracks the cursor itself; an open palette needs no hover.
        guard pendingButton == nil, panel?.isVisible != true else { return }
        lastMove = Date()
        guard !restCheckScheduled else { return }
        restCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restDelay) { [weak self] in self?.restCheck() }
    }

    private static let restDelay: TimeInterval = 0.08

    private func restCheck() {
        let quiet = Date().timeIntervalSince(lastMove)
        if quiet < Self.restDelay {
            // Still moving: look again when it could have been still long enough.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restDelay - quiet) { [weak self] in self?.restCheck() }
            return
        }
        restCheckScheduled = false
        guard Settings.shared.data.paletteOnHover, pendingButton == nil, panel?.isVisible != true else { return }

        let p = Geometry.mouseAX
        let el = AXWindow.element(at: p)
        let sr = el?.subrole
        Debug.log("hover \(Int(p.x)),\(Int(p.y)) role=\(el?.role ?? "nil") subrole=\(sr ?? "nil")")
        guard let el, let sr, Self.greenSubroles.contains(sr) else { return }
        waiting?.cancel()
        pendingButton = el
        waitForSystemMenu(button: el)
    }

    /// Polls (once a frame, only while the cursor rests on a green button) for
    /// macOS's green-button menu and opens the palette beside it once it appears.
    /// The system gives no notification for that menu, so a few tens of ms behind
    /// it is as close as an outside app gets.
    /// Without a system menu (some apps) it falls back to the hover delay.
    private func waitForSystemMenu(button el: AXUIElement) {
        guard let btn = el.frame, let w = AXWindow.window(containing: el) else { pendingButton = nil; return }
        guard !Settings.shared.isExcluded(w.bundleID), !w.isFullScreen else { pendingButton = nil; return }
        prepare(for: w, keyboard: false)   // lay out now so showing costs nothing later
        let start = Date()
        let fallback = max(Settings.shared.data.paletteHoverDelay, 2.0)   // system menu takes ~1–1.5s
        let work = DispatchWorkItem {}
        waiting = work
        func check() {
            guard !work.isCancelled, pendingButton != nil else { return }
            if let menu = Self.findSystemMenu(near: btn) {
                pendingButton = nil
                Debug.log("palette: system menu after \(Int(Date().timeIntervalSince(start) * 1000))ms")
                present(beside: menu, button: btn)
            } else if !btn.insetBy(dx: -4, dy: -4).contains(Geometry.mouseAX) {
                pendingButton = nil
            } else if Date().timeIntervalSince(start) >= fallback {
                pendingButton = nil
                present(beside: nil, button: btn)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { check() }
            }
        }
        check()
    }

    func showForFocusedWindow() {
        guard let w = AXWindow.focused(), let f = w.frame else { NSSound.beep(); return }
        guard !Settings.shared.isExcluded(w.bundleID) else { return }
        prepare(for: w, keyboard: true)
        guard let panel else { return }
        let size = panel.frame.size
        let c = Geometry.cocoaRect(fromAX: f).center
        place(panel, at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    /// macOS draws its green-button menu in a separate window owned by a system
    /// process; find a popup-level window hanging off the button.
    private static func findSystemMenu(near btn: CGRect) -> SystemMenu? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer > 0, layer < 1000,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            let nearVertically = r.minY >= btn.minY - 8 && r.minY <= btn.maxY + 40
            let nearHorizontally = r.minX - 60 <= btn.midX && btn.midX <= r.maxX + 60
            if nearVertically && nearHorizontally && r.width > 60 && r.width < 700 && r.height > 40 && r.height < 700 {
                Debug.log("palette: system menu \(info[kCGWindowOwnerName as String] ?? "?") \(r)")
                return SystemMenu(id: id, rect: r)
            }
        }
        return nil
    }

    /// Whether the system menu is still fully on screen (it fades out when closing).
    private static func isShowing(_ m: SystemMenu) -> Bool {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], m.id) as? [[String: Any]])?.first else { return false }
        let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 0
        return onScreen && alpha > 0.95
    }

    // MARK: Showing

    /// Configures the model and builds/sizes the panel without showing it.
    private func prepare(for w: AXWindow, keyboard: Bool) {
        target = w
        let s = Settings.shared.data
        model.actions = s.actions.filter(\.inPalette)
        model.cols = max(2, s.gridColumns)
        model.rows = max(2, s.gridRows)
        model.onPick = { [weak self] a in self?.pick(a) }
        model.onGrid = { [weak self] u in self?.pickGrid(u) }
        model.onHoverAction = { [weak self] a in self?.preview(action: a) }
        model.onHoverGrid = { [weak self] u in self?.preview(unit: u) }
        model.reset()
        model.keyboardHint = keyboard
        sticky = keyboard

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = panel.contentView as! FirstMouseHostingView<PaletteView>
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
    }

    /// Opens the palette to the right of the system menu, top edges aligned —
    /// instantly, so it lands in the same frame as the menu.
    private func present(beside menu: SystemMenu?, button btn: CGRect) {
        guard let panel else { return }
        systemMenu = menu
        let size = panel.frame.size
        let originAX: CGPoint = menu.map { CGPoint(x: $0.rect.maxX + 6, y: $0.rect.minY) }
            ?? CGPoint(x: btn.minX - 8, y: btn.maxY + 6)
        let r = Geometry.cocoaRect(fromAX: CGRect(origin: originAX, size: size))
        place(panel, at: r.origin)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func place(_ panel: NSPanel, at origin: CGPoint) {
        var o = origin
        let size = panel.frame.size
        let probe = CGRect(origin: o, size: size).center
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            o.x = min(max(o.x, vf.minX + 4), vf.maxX - size.width - 4)
            o.y = min(max(o.y, vf.minY + 4), vf.maxY - size.height - 4)
        }
        panel.setFrameOrigin(o)
    }

    private func makePanel() -> PalettePanel {
        let p = PalettePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.contentView = FirstMouseHostingView(rootView: PaletteView(model: model))
        return p
    }

    /// Follows the system menu: when it starts to close (Esc, a pick in it, a
    /// click elsewhere), the palette fades out with it.
    private func poll() {
        guard let panel, panel.isVisible else { pollTimer?.invalidate(); return }
        guard let m = systemMenu else { return }
        // Once the cursor is in the palette, stop following the system menu: clicking
        // here closes that menu (it counts as "outside"), which must not close us.
        // From then on we close on a pick, a click elsewhere, or Esc.
        if panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) {
            systemMenu = nil
            return
        }
        if !Self.isShowing(m) { hide(animated: true) }
    }

    func hide(animated: Bool) {
        waiting?.cancel(); waiting = nil; pendingButton = nil
        pollTimer?.invalidate(); pollTimer = nil
        PreviewOverlay.shared.hide()
        systemMenu = nil
        target = nil
        guard let panel, panel.isVisible else { return }
        if animated {
            // Same 0.2s fade as the system menu.
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                                 completionHandler: { if panel.alphaValue == 0 { panel.orderOut(nil) } })
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: Actions

    private func pick(_ a: WindowAction) {
        let w = target
        hide(animated: false)
        if let w { WindowManager.shared.perform(a, on: w); w.raise() }
    }

    private func pickGrid(_ u: UnitRect) {
        guard let w = target, let f = w.frame, let screen = NSScreen.screen(forAX: f) else { hide(animated: false); return }
        hide(animated: false)
        WindowManager.shared.place(w, unit: u, on: screen)
        w.raise()
    }

    private func keyDown(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 { hide(animated: true); return true }   // Esc
        if let c = e.charactersIgnoringModifiers, let n = Int(c), n >= 1, n <= model.actions.count {
            pick(model.actions[n - 1]); return true
        }
        return false
    }

    private func preview(action a: WindowAction?) {
        guard let a, let w = target, let f = w.frame, let screen = NSScreen.screen(forAX: f) else {
            PreviewOverlay.shared.hide(); return
        }
        var dest = screen
        if a.display != .current || a.kind == .nextDisplay || a.kind == .previousDisplay {
            let all = NSScreen.ordered
            if let i = all.firstIndex(of: screen), all.count > 1 {
                let back = a.display == .previous || a.kind == .previousDisplay
                dest = all[(i + (back ? -1 : 1) + all.count) % all.count]
            }
        }
        let wm = WindowManager.shared
        switch a.kind {
        case .unitRect: if let r = a.rects.first { PreviewOverlay.shared.show(axFrame: wm.targetFrame(unit: r, screen: dest)) }
        case .maximize: PreviewOverlay.shared.show(axFrame: wm.targetFrame(unit: .full, screen: dest))
        case .almostMaximize:
            let s = Settings.shared.data.almostMaximizeInset
            PreviewOverlay.shared.show(axFrame: wm.targetFrame(unit: UnitRect((1 - s) / 2, (1 - s) / 2, s, s), screen: dest))
        case .center:
            let vf = dest.axVisibleFrame
            PreviewOverlay.shared.show(axFrame: CGRect(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2, width: f.width, height: f.height))
        default: PreviewOverlay.shared.hide()
        }
    }

    private func preview(unit u: UnitRect?) {
        guard let u, let w = target, let f = w.frame, let screen = NSScreen.screen(forAX: f) else {
            PreviewOverlay.shared.hide(); return
        }
        PreviewOverlay.shared.show(axFrame: WindowManager.shared.targetFrame(unit: u, screen: screen))
    }
}

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI

final class PaletteModel: ObservableObject {
    @Published var actions: [WindowAction] = []
    @Published var cols = 8
    @Published var rows = 6
    @Published var selection: (c0: Int, r0: Int, c1: Int, r1: Int)?
    @Published var hoverCell: (c: Int, r: Int)?
    @Published var keyboardHint = false
    var onPick: (WindowAction) -> Void = { _ in }
    var onGrid: (UnitRect) -> Void = { _ in }
    var onHoverAction: (WindowAction?) -> Void = { _ in }
    var onHoverGrid: (UnitRect?) -> Void = { _ in }

    func reset() { selection = nil; hoverCell = nil }

    func unit(_ s: (c0: Int, r0: Int, c1: Int, r1: Int)) -> UnitRect {
        let x0 = min(s.c0, s.c1), x1 = max(s.c0, s.c1), y0 = min(s.r0, s.r1), y1 = max(s.r0, s.r1)
        return UnitRect(Double(x0) / Double(cols), Double(y0) / Double(rows),
                        Double(x1 - x0 + 1) / Double(cols), Double(y1 - y0 + 1) / Double(rows))
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    private let gridWidth: CGFloat = 264

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.actions.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 6), count: 5), spacing: 6) {
                    ForEach(Array(model.actions.enumerated()), id: \.element.id) { i, a in
                        ActionTile(action: a, index: model.keyboardHint ? i + 1 : nil)
                            .onTapGesture { model.onPick(a) }
                            .onHover { model.onHoverAction($0 ? a : nil) }
                            .help(a.name)
                    }
                }
            }
            GridPicker(model: model)
                .frame(width: gridWidth, height: gridWidth * 0.62)
            Text(model.keyboardHint ? "在网格上拖动 · 1–9 选预设 · Esc 关闭" : "在网格上拖动来定窗口大小")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: gridWidth + 24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
    }
}

struct ActionTile: View {
    let action: WindowAction
    let index: Int?
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(hover ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
            UnitIcon(action: action)
                .padding(7)
            if let index, index <= 9 {
                Text("\(index)").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).padding(3)
            }
        }
        .frame(width: 48, height: 34)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Small screen-shaped icon showing where an action puts the window.
struct UnitIcon: View {
    let action: WindowAction

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
                if let u = unit {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: max(2, g.size.width * u.w - 3), height: max(2, g.size.height * u.h - 3))
                        .offset(x: g.size.width * u.x + 1.5, y: g.size.height * u.y + 1.5)
                } else {
                    Image(systemName: action.symbol)
                        .font(.system(size: 11))
                        .frame(width: g.size.width, height: g.size.height)
                }
            }
        }
    }

    private var unit: UnitRect? {
        switch action.kind {
        case .unitRect: return action.rects.first
        case .maximize: return .full
        case .almostMaximize: return UnitRect(0.1, 0.1, 0.8, 0.8)
        default: return nil
        }
    }
}

struct GridPicker: View {
    @ObservedObject var model: PaletteModel

    var body: some View {
        GeometryReader { g in
            let cw = g.size.width / CGFloat(model.cols), ch = g.size.height / CGFloat(model.rows)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))
                Path { p in
                    for c in 1..<model.cols { p.move(to: CGPoint(x: CGFloat(c) * cw, y: 0)); p.addLine(to: CGPoint(x: CGFloat(c) * cw, y: g.size.height)) }
                    for r in 1..<model.rows { p.move(to: CGPoint(x: 0, y: CGFloat(r) * ch)); p.addLine(to: CGPoint(x: g.size.width, y: CGFloat(r) * ch)) }
                }
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)

                if let s = model.selection ?? model.hoverCell.map({ ($0.c, $0.r, $0.c, $0.r) }) {
                    let u = model.unit(s)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(model.selection == nil ? 0.35 : 0.7))
                        .frame(width: g.size.width * u.w, height: g.size.height * u.h)
                        .offset(x: g.size.width * u.x, y: g.size.height * u.y)
                }
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.3))
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard model.selection == nil else { return }
                switch phase {
                case .active(let p):
                    let c = cell(p, g.size)
                    model.hoverCell = c
                    model.onHoverGrid(model.unit((c.c, c.r, c.c, c.r)))
                case .ended:
                    model.hoverCell = nil
                    model.onHoverGrid(nil)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let a = cell(v.startLocation, g.size), b = cell(v.location, g.size)
                        let s = (a.c, a.r, b.c, b.r)
                        model.selection = s
                        model.onHoverGrid(model.unit(s))
                    }
                    .onEnded { _ in
                        if let s = model.selection { model.onGrid(model.unit(s)) }
                        model.selection = nil
                    }
            )
        }
    }

    private func cell(_ p: CGPoint, _ size: CGSize) -> (c: Int, r: Int) {
        let c = Int(p.x / size.width * CGFloat(model.cols))
        let r = Int(p.y / size.height * CGFloat(model.rows))
        return (min(max(c, 0), model.cols - 1), min(max(r, 0), model.rows - 1))
    }
}
