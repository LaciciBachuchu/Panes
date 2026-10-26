// Carry a window to every Space ("带到每张桌面"): the window stays where it is; on
// every other Space a strip for it sits at the top right under the menu bar. Rest on
// the strip to see the window live; click to go back to it (macOS switches Space).
// Adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// prototype/App/Carry.swift and docs/glance.md "带到每张桌面" — strips right to left,
// hidden where the window is already in view, a picture streamed from the other Space
// (scaled so it's at most 70% of the screen wide, right-aligned under the strip), a
// snapshot labelled "不是实时画面" when the window is minimized or its app hidden,
// unminimize before bringing it back. WindowShade re-checks on a timer; Panes only
// reacts to Space changes and AX notifications.

import AppKit
import ApplicationServices

final class CarryController {
    static let shared = CarryController()

    final class Carried {
        let id: CGWindowID
        let window: AXWindow
        let pid: pid_t
        let appName: String
        var title: String
        var snapshot: CGImage?
        let strip: CarryStrip

        init(id: CGWindowID, window: AXWindow, strip: CarryStrip) {
            self.id = id; self.window = window; self.pid = window.pid
            self.appName = window.app?.localizedName ?? window.bundleID ?? "?"
            self.title = window.title
            self.strip = strip
        }
    }

    private(set) var carried: [CGWindowID] = []        // order of carrying: first is rightmost
    private var items: [CGWindowID: Carried] = [:]
    private var watchers: [pid_t: AXWatch] = [:]
    private var spaceObserver: Any?
    private var appObservers: [Any] = []
    private var card: CarryCard?

    private var settings: SettingsData { Settings.shared.data }

    func applySettings() {
        if !settings.carryEnabled { stopAll() }
        installDebugHook()
    }

    private var debugHook: Any?

    /// Debug mode only: "open the first carried window", the same path as a click on
    /// its strip, so going back across Spaces can be checked without a real click.
    private func installDebugHook() {
        guard Debug.enabled, debugHook == nil else { return }
        debugHook = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.thomas.panes.debug.carryOpen"), object: nil, queue: .main
        ) { [weak self] _ in
            if let id = self?.carried.first { self?.open(id) }
        }
    }

    // MARK: Carry / stop

    /// Hotkey: carry the focused window, or stop carrying it.
    func toggle(_ target: AXWindow?) {
        guard settings.carryEnabled, let w = target ?? AXWindow.focused(), let id = w.cgWindowID else { NSSound.beep(); return }
        if items[id] != nil {
            stop(id)
            GestureHUD.shared.flash("不再带到每张桌面", symbol: "rectangle.on.rectangle.slash", anchor: Self.anchor(w))
        } else {
            carry(w)
        }
    }

    func carry(_ w: AXWindow) {
        guard let id = w.cgWindowID, items[id] == nil, !Settings.shared.isExcluded(w.bundleID), w.isStandard else { NSSound.beep(); return }
        let strip = CarryStrip()
        let c = Carried(id: id, window: w, strip: strip)
        c.snapshot = WindowCapture.snapshot(id)
        strip.setContent(icon: w.app?.icon, title: c.title.isEmpty ? c.appName : c.title)
        strip.onHover = { [weak self] inside in self?.hover(id, inside) }
        strip.onClick = { [weak self] in self?.open(id) }
        strip.onClose = { [weak self] in self?.stop(id) }
        items[id] = c
        carried.append(id)
        defer { watchers[c.pid]?.add(w.element, kAXUIElementDestroyedNotification) }
        Debug.log("carry: \(w.bundleID ?? "?") id=\(id)")
        watch(c.pid)
        observeSpaces()
        refresh()
        GestureHUD.shared.flash("已带到每张桌面", symbol: "rectangle.on.rectangle", anchor: Self.anchor(w))
        if !WindowCapture.hasPermission { WindowCapture.requestPermission() }
    }

    func stop(_ id: CGWindowID) {
        guard let c = items.removeValue(forKey: id) else { return }
        carried.removeAll { $0 == id }
        if card?.windowID == id { closeCard() }
        c.strip.orderOut(nil)
        if !items.values.contains(where: { $0.pid == c.pid }) { watchers[c.pid] = nil }
        if items.isEmpty { unobserveSpaces() }
        refresh()
    }

    func stopAll() {
        for id in carried { stop(id) }
    }

    var menuEntries: [(id: CGWindowID, label: String)] {
        carried.compactMap { id in items[id].map { (id, $0.title.isEmpty ? $0.appName : "\($0.appName) — \($0.title)") } }
    }

    private static func anchor(_ w: AXWindow) -> CGPoint {
        let f = w.frame ?? .zero
        return CGPoint(x: f.midX, y: f.minY + Titlebar.height(of: w))
    }

    // MARK: Visibility

    /// Strips show for windows that aren't in view right now, laid out right to left.
    private func refresh() {
        guard let screen = NSScreen.main else { return }
        let onScreen = Self.onScreenIDs()
        var x = screen.visibleFrame.maxX - 8
        let y = screen.visibleFrame.maxY - 6
        for id in carried {
            guard let c = items[id] else { continue }
            let visible = onScreen.contains(id) && !c.window.isMinimized
            Debug.log("carry: refresh id=\(id) visible=\(visible)")
            if visible {
                c.strip.orderOut(nil)
                continue
            }
            let size = c.strip.frame.size
            x -= size.width
            guard x > screen.visibleFrame.minX + 100 else { c.strip.orderOut(nil); continue }
            c.strip.setFrameOrigin(CGPoint(x: x, y: y - size.height))
            c.strip.orderFrontRegardless()
            x -= 6
        }
    }

    private static func onScreenIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    private func observeSpaces() {
        guard spaceObserver == nil else { return }
        let nc = NSWorkspace.shared.notificationCenter
        spaceObserver = nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.spaceChanged()
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if name == NSWorkspace.didTerminateApplicationNotification {
                    for c in self.items.values where c.pid == app.processIdentifier { self.stop(c.id) }
                } else {
                    self.refresh()
                }
            })
        }
    }

    private func unobserveSpaces() {
        let nc = NSWorkspace.shared.notificationCenter
        if let o = spaceObserver { nc.removeObserver(o) }
        appObservers.forEach(nc.removeObserver)
        spaceObserver = nil
        appObservers = []
    }

    private func spaceChanged() {
        Debug.log("carry: space changed")
        closeCard()
        refresh()
        // The switch animation settles a beat later; check once more, and keep a
        // fresh picture for when the live one isn't available.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.refresh()
            for c in self.items.values { if let s = WindowCapture.snapshot(c.id) { c.snapshot = s } }
        }
    }

    private func watch(_ pid: pid_t) {
        guard watchers[pid] == nil else { return }
        watchers[pid] = AXWatch(pid: pid, notifications: [
            kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
            kAXTitleChangedNotification,
        ]) { [weak self] note in
            guard let self else { return }
            for c in self.items.values where c.pid == pid {
                if note == kAXUIElementDestroyedNotification, AXWindow.serverFrame(of: c.id) == nil { self.stop(c.id); continue }
                if note == kAXTitleChangedNotification {
                    c.title = c.window.title
                    c.strip.setContent(icon: c.window.app?.icon, title: c.title.isEmpty ? c.appName : c.title)
                }
            }
            self.refresh()
        }
    }

    // MARK: Glance and going back

    private func hover(_ id: CGWindowID, _ inside: Bool) {
        if inside {
            card?.cancelClose()
            guard card?.windowID != id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, let c = self.items[id], c.strip.isMouseInside else { return }
                self.showCard(c)
            }
        } else {
            card?.scheduleClose()
        }
    }

    private func showCard(_ c: Carried) {
        closeCard()
        guard let screen = NSScreen.main, let size = AXWindow.serverFrame(of: c.id)?.size ?? c.window.frame?.size else { return }
        let live = !c.window.isMinimized && !(c.window.app?.isHidden ?? false) && WindowCapture.hasPermission
        let k = CarryCard(windowID: c.id, size: size, screen: screen, under: c.strip.frame,
                          snapshot: c.snapshot, live: live)
        k.onClick = { [weak self] in self?.open(c.id) }
        k.onClosed = { [weak self, weak k] in if self?.card === k { self?.card = nil } }
        card = k
        k.present()
    }

    private func closeCard() {
        card?.close()
        card = nil
    }

    /// Bring the window back: unminimize, unhide, raise; macOS switches to its Space.
    func open(_ id: CGWindowID) {
        guard let c = items[id] else { return }
        closeCard()
        if c.window.isMinimized {
            AXUIElementSetAttributeValue(c.window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if c.window.app?.isHidden == true { c.window.app?.unhide() }
        AXUIElementSetAttributeValue(c.window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        c.window.raise()
    }
}

/// The strip on other Spaces: icon, title, and a close button on the right.
final class CarryStrip: NSPanel {
    var onHover: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onClose: () -> Void = {}
    private let view = CarryStripView()
    var isMouseInside: Bool { frame.contains(NSEvent.mouseLocation) }

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 220, height: 30), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        // On every Space, including full-screen ones; not in the window cycle.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        view.frame = CGRect(x: 0, y: 0, width: 220, height: 30)
        view.onHover = { [weak self] in self?.onHover($0) }
        view.onClick = { [weak self] in self?.onClick() }
        view.onClose = { [weak self] in self?.onClose() }
        contentView = view
    }

    func setContent(icon: NSImage?, title: String) { view.set(icon: icon, title: title) }
}

private final class CarryStripView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onClose: () -> Void = {}
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let bg = NSVisualEffectView(frame: bounds)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 9
        bg.autoresizingMask = [.width, .height]
        addSubview(bg)
        iconView.frame = CGRect(x: 8, y: 7, width: 16, height: 16)
        addSubview(iconView)
        label.frame = CGRect(x: 30, y: 7, width: 160, height: 16)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        close.frame = CGRect(x: 196, y: 6, width: 18, height: 18)
        close.bezelStyle = .inline
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "不再带着")
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closePressed)
        close.toolTip = "不再带到每张桌面"
        addSubview(close)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(icon: NSImage?, title: String) {
        iconView.image = icon
        label.stringValue = title
    }

    @objc private func closePressed() { onClose() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func mouseUp(with event: NSEvent) {
        // The close button handles its own clicks; anything else opens the window.
        if convert(event.locationInWindow, from: nil).x < close.frame.minX - 2 { onClick() }
    }
}

/// The picture under a carried window's strip: live from the other Space when the
/// window is still composited, else the last snapshot, labelled.
final class CarryCard {
    let windowID: CGWindowID
    private let panel: NSPanel
    private let picture = CALayer()
    private var stream: LiveWindowStream?
    private var closeWork: DispatchWorkItem?
    var onClick: () -> Void = {}
    var onClosed: () -> Void = {}

    init(windowID: CGWindowID, size: CGSize, screen: NSScreen, under strip: CGRect, snapshot: CGImage?, live: Bool) {
        self.windowID = windowID
        let vf = screen.visibleFrame
        let scale = min(1, (vf.width * 0.7) / max(1, size.width), (strip.minY - vf.minY - 10) / max(1, size.height))
        let w = size.width * scale, h = size.height * scale
        let frame = CGRect(x: strip.maxX - w, y: strip.minY - 6 - h, width: w, height: h)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        let view = CardView(frame: CGRect(origin: .zero, size: frame.size))
        view.onClick = { [weak self] in self?.onClick() }
        view.onHover = { [weak self] inside in inside ? self?.cancelClose() : self?.scheduleClose() }
        picture.frame = view.bounds
        picture.contentsGravity = .resizeAspect
        picture.contents = snapshot
        view.layer?.addSublayer(picture)
        panel.contentView = view
        if live {
            let s = LiveWindowStream(layer: picture)
            s.onFirstFrame = { view.setBadge(nil) }
            s.start(windowID: windowID, size: frame.size, scale: screen.backingScaleFactor)
            stream = s
        }
        view.setBadge(live ? nil : (snapshot == nil ? "画面暂时看不到" : "不是实时画面"))
        if snapshot == nil && !live && !WindowCapture.hasPermission { view.setBadge("需要屏幕录制权限") }
    }

    func present() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    func cancelClose() { closeWork?.cancel() }

    /// Leaving both the strip and the card for ~0.16s closes it.
    func scheduleClose() {
        closeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.close()
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: w)
    }

    func close() {
        stream?.stop()
        stream = nil
        panel.orderOut(nil)
        onClosed()
    }

    private final class CardView: NSView {
        var onClick: () -> Void = {}
        var onHover: (Bool) -> Void = { _ in }
        private let badge = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            badge.font = .systemFont(ofSize: 11, weight: .medium)
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            badge.layer?.cornerRadius = 5
            badge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        func setBadge(_ text: String?) {
            badge.stringValue = text.map { "  \($0)  " } ?? ""
            badge.isHidden = text == nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
        override func mouseUp(with event: NSEvent) { onClick() }
    }
}
