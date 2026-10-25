// Pin a window on top ("置顶").
// macOS has no public way to raise another app's window above everything. Approach
// adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// prototype/PinnedPreview.swift + PinnedPreviewPanel.swift + ScreenCaptureBridge.swift —
// a floating panel at the window's frame mirrors it live through ScreenCaptureKit; the
// mirror is only a picture, so when the pointer enters it the real window is moved under
// the panel, activated and raised, and the panel turns see-through and click-through for
// the duration; a click that lands before the hand-off is re-posted to the real window.
// When the pointer leaves, the mirror comes back on top.

import AppKit
import ApplicationServices

final class PinController {
    static let shared = PinController()

    final class Pin {
        let id: CGWindowID
        let window: AXWindow
        let pid: pid_t
        let appName: String
        let title: String
        let panel: PinPanel
        let stream: LiveWindowStream
        var interacting = false
        var exitMonitor: Any?
        var pendingClick: (point: CGPoint, count: Int)?

        init(id: CGWindowID, window: AXWindow, panel: PinPanel, stream: LiveWindowStream) {
            self.id = id; self.window = window; self.pid = window.pid
            self.appName = window.app?.localizedName ?? window.bundleID ?? "?"
            self.title = window.title
            self.panel = panel; self.stream = stream
        }
    }

    private(set) var pins: [CGWindowID: Pin] = [:]
    private var watchers: [pid_t: AXWatch] = [:]
    private var activationObserver: Any?

    private var settings: SettingsData { Settings.shared.data }

    func applySettings() {
        if !settings.pinEnabled { unpinAll() }
    }

    // MARK: Entry points

    /// Hotkey: unpin the focused window if it's pinned, else pin it.
    func toggle(_ target: AXWindow?) {
        guard let w = target ?? AXWindow.focused(), let id = w.cgWindowID else { NSSound.beep(); return }
        if pins[id] != nil { unpin(id) } else { pin(w) }
    }

    func pin(_ w: AXWindow) {
        guard settings.pinEnabled, let id = w.cgWindowID, pins[id] == nil,
              !Settings.shared.isExcluded(w.bundleID), w.isStandard, !w.isFullScreen, !w.isMinimized,
              let f = w.frame else { NSSound.beep(); return }
        // Debug mode may pin without the picture, to exercise the hand-off logic.
        guard WindowCapture.hasPermission || Debug.enabled else {
            askForScreenRecording()
            return
        }
        let panel = PinPanel(frame: Geometry.cocoaRect(fromAX: f))
        let stream = LiveWindowStream(layer: panel.mirror.layer!)
        let p = Pin(id: id, window: w, panel: panel, stream: stream)
        panel.onEnter = { [weak self] in self?.beginInteraction(id) }
        panel.onEarlyClick = { [weak self] point, count in
            self?.pins[id]?.pendingClick = (point, count)
            self?.beginInteraction(id)
        }
        pins[id] = p
        stream.start(windowID: id, size: f.size, scale: NSScreen.main?.backingScaleFactor ?? 2)
        panel.orderFrontRegardless()
        watch(p)
        observeActivation()
        // The pointer is usually on the window that was just pinned: start in hand-off.
        if Geometry.cocoaRect(fromAX: f).contains(NSEvent.mouseLocation) { beginInteraction(id) }
        Debug.log("pin: \(w.bundleID ?? "?") \(f)")
    }

    func unpin(_ id: CGWindowID) {
        guard let p = pins.removeValue(forKey: id) else { return }
        p.stream.stop()
        if let m = p.exitMonitor { NSEvent.removeMonitor(m) }
        p.panel.orderOut(nil)
        if !pins.values.contains(where: { $0.pid == p.pid }) { watchers[p.pid] = nil }
        if pins.isEmpty, let o = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            activationObserver = nil
        }
    }

    func unpinAll() {
        for id in Array(pins.keys) { unpin(id) }
    }

    /// For the menu bar: (id, "App — title") of every pinned window.
    var menuEntries: [(id: CGWindowID, label: String)] {
        pins.values.sorted { $0.id < $1.id }.map { p in
            (p.id, p.title.isEmpty ? p.appName : "\(p.appName) — \(p.title)")
        }
    }

    private func askForScreenRecording() {
        WindowCapture.requestPermission()
        let a = NSAlert()
        a.messageText = "置顶需要屏幕录制权限"
        a.informativeText = "macOS 不允许把别的 App 的窗口放到最上层。Panes 用一层实时画面盖在最上面来做到置顶，这需要“屏幕录制”权限。请在 系统设置 → 隐私与安全性 → 屏幕录制 里打开 Panes，然后重新打开 Panes。"
        a.addButton(withTitle: "打开系统设置")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    // MARK: Hand-off between mirror and real window

    /// Pointer entered the mirror: put the real window exactly under it, bring it
    /// forward, then let the pointer through to it.
    private func beginInteraction(_ id: CGWindowID) {
        guard let p = pins[id], !p.interacting else { return }
        p.interacting = true
        let target = Geometry.axRect(fromCocoa: p.panel.frame)
        if let f = p.window.frame, !f.roughlyEquals(target, tolerance: 2) { p.window.setFrame(target) }
        AXUIElementSetAttributeValue(p.window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        p.window.raise()
        // Give the app a beat to come forward before the mirror steps aside.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, let p = self.pins[id], p.interacting else { return }
            p.panel.passThrough(true)
            if let click = p.pendingClick {
                p.pendingClick = nil
                Self.postClick(at: click.point, count: click.count)
            }
            // Watch for the pointer leaving the real window (it now gets the events).
            p.exitMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { [weak self] _ in
                self?.checkExit(id)
            }
        }
    }

    private func checkExit(_ id: CGWindowID) {
        guard let p = pins[id], p.interacting, NSEvent.pressedMouseButtons == 0 else { return }
        // The user may have moved or resized the real window meanwhile.
        if let f = p.window.frame {
            let r = Geometry.cocoaRect(fromAX: f)
            if !r.equalTo(p.panel.frame) { p.panel.setFrame(r, display: true) }
        }
        guard !p.panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
        endInteraction(id)
    }

    private func endInteraction(_ id: CGWindowID) {
        guard let p = pins[id], p.interacting else { return }
        p.interacting = false
        if let m = p.exitMonitor { NSEvent.removeMonitor(m) }
        p.exitMonitor = nil
        p.panel.passThrough(false)
        p.panel.orderFrontRegardless()
    }

    private static func postClick(at axPoint: CGPoint, count: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: axPoint, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Switching to another app with the keyboard while the pointer rests on the
    /// pinned window: put the mirror back on top so it stays visible.
    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            for p in self.pins.values where p.interacting && p.pid != app.processIdentifier {
                self.endInteraction(p.id)
            }
        }
    }

    // MARK: Following the real window

    private func watch(_ p: Pin) {
        guard watchers[p.pid] == nil else { return }
        let pid = p.pid
        watchers[pid] = AXWatch(pid: pid, notifications: [
            kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        ]) { [weak self] note in
            self?.windowEvent(pid: pid, note: note)
        }
    }

    private func windowEvent(pid: pid_t, note: String) {
        for p in pins.values where p.pid == pid {
            switch note {
            case kAXUIElementDestroyedNotification:
                if AXWindow.serverFrame(of: p.id) == nil { unpin(p.id) }
            case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
                if p.window.isMinimized { p.panel.orderOut(nil) } else { p.panel.orderFrontRegardless() }
            default:
                guard let f = p.window.frame else { continue }
                let r = Geometry.cocoaRect(fromAX: f)
                if !r.equalTo(p.panel.frame) { p.panel.setFrame(r, display: true) }
                // The window may have moved out from under a resting pointer.
                if p.interacting { checkExit(p.id) }
            }
        }
    }
}

/// The floating mirror of a pinned window.
final class PinPanel: NSPanel {
    let mirror = MirrorView()
    var onEnter: () -> Void = {}
    var onEarlyClick: (CGPoint, Int) -> Void = { _, _ in }

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        mirror.frame = CGRect(origin: .zero, size: frame.size)
        mirror.autoresizingMask = [.width, .height]
        mirror.onEnter = { [weak self] in self?.onEnter() }
        mirror.onMouseDown = { [weak self] e in
            guard let self else { return }
            let screen = self.convertPoint(toScreen: e.locationInWindow)
            self.onEarlyClick(Geometry.axPoint(fromCocoa: screen), e.clickCount)
        }
        contentView = mirror
    }

    /// See-through and click-through while the real window has the pointer.
    func passThrough(_ on: Bool) {
        ignoresMouseEvents = on
        alphaValue = on ? 0 : 1
        hasShadow = !on
    }
}

final class MirrorView: NSView {
    var onEnter: () -> Void = {}
    var onMouseDown: (NSEvent) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseMoved(with event: NSEvent) { onEnter() }
    override func mouseDown(with event: NSEvent) { onMouseDown(event) }
}
