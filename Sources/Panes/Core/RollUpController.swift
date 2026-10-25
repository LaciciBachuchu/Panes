// Roll up ("卷起"): a window collapses to a strip as tall as its title bar.
// macOS can't draw another app's window as just its title bar, so the real window
// is put away and Panes draws the strip. Approach adapted from WindowShade
// (MIT, https://github.com/surfine/WindowShade):
//   prototype/App/FoldTransaction.swift — try put-away methods in order (off screen →
//     hide the app → minimize), verify each with the window server, roll back on failure,
//     hand focus to another window on this Space before hiding a frontmost app;
//   prototype/Recovery/Journal.swift — a durable journal so a crash never strands windows;
//   prototype/App/EventTapCallback.swift — an active tap that only asks about double-clicks.

import AppKit
import ApplicationServices

final class RollUpController {
    static let shared = RollUpController()

    enum HideMethod: String, Codable { case offscreen, hiddenApp, minimized }

    final class Rolled {
        let id: CGWindowID
        let window: AXWindow
        let pid: pid_t
        let bundleID: String?
        let title: String
        let frame: CGRect          // AX frame before rolling up
        let barHeight: CGFloat
        let snapshot: CGImage?
        var method: HideMethod
        var strip: ShadeStrip?

        init(id: CGWindowID, window: AXWindow, frame: CGRect, barHeight: CGFloat, snapshot: CGImage?, method: HideMethod) {
            self.id = id; self.window = window; self.pid = window.pid
            self.bundleID = window.bundleID; self.title = window.title
            self.frame = frame; self.barHeight = barHeight; self.snapshot = snapshot; self.method = method
        }
    }

    private(set) var rolled: [CGWindowID: Rolled] = [:]
    private var busy: Set<CGWindowID> = []
    private var watchers: [pid_t: AXWatch] = [:]
    private var signalSources: [DispatchSourceSignal] = []

    private var settings: SettingsData { Settings.shared.data }

    // MARK: Lifecycle

    func start() {
        RollUpJournal.recover()
        installSignalHandlers()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appQuit(app.processIdentifier)
        }
        applySettings()
    }

    /// Called whenever settings change: install or tear down the double-click tap.
    func applySettings() {
        let wantTap = settings.rollUpEnabled && settings.rollUpOnDoubleClick
        if wantTap { DoubleClickTap.shared.install() } else { DoubleClickTap.shared.remove() }
        if !settings.rollUpEnabled { unrollAll() }
        if !settings.glanceEnabled { rolled.values.forEach { $0.strip?.closeGlance(animated: false) } }
    }

    /// Put every rolled window back (quit, crash signal, feature switched off).
    func unrollAll() {
        for id in Array(rolled.keys) { unroll(id, at: nil, activate: false) }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.unrollAll()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Entry points

    /// Hotkey: unroll the strip under the pointer, else roll up the focused window.
    func toggle(_ target: AXWindow?) {
        if let r = rolled.values.first(where: { $0.strip?.frame.contains(NSEvent.mouseLocation) == true }) {
            unroll(r.id, at: r.strip?.axOrigin, activate: true)
            return
        }
        guard let w = target ?? AXWindow.focused() else { NSSound.beep(); return }
        rollUp(w)
    }

    func isRolled(_ w: AXWindow) -> Bool { w.cgWindowID.map { rolled[$0] != nil } ?? false }

    // MARK: Roll up

    func rollUp(_ w: AXWindow, completion: ((Bool) -> Void)? = nil) {
        guard settings.rollUpEnabled, let id = w.cgWindowID, rolled[id] == nil, !busy.contains(id),
              !Settings.shared.isExcluded(w.bundleID), w.isStandard, !w.isFullScreen, !w.isMinimized,
              let frame = w.frame else { completion?(false); return }
        busy.insert(id)
        let bar = Titlebar.height(of: w)
        let snapshot = WindowCapture.snapshot(id)
        let r = Rolled(id: id, window: w, frame: frame, barHeight: bar, snapshot: snapshot, method: .offscreen)

        tryMethods([.offscreen, .hiddenApp, .minimized], for: r) { [weak self] method in
            guard let self else { return }
            self.busy.remove(id)
            guard let method else {
                Debug.log("rollup: every put-away method failed for \(w.bundleID ?? "?")")
                NSSound.beep()
                completion?(false)
                return
            }
            r.method = method
            self.rolled[id] = r
            r.strip = ShadeStrip(rolled: r)
            r.strip?.show()
            self.watch(r)
            RollUpJournal.save(Array(self.rolled.values))
            Debug.log("rollup: \(w.bundleID ?? "?") via \(method)")
            completion?(true)
        }
    }

    /// Tries each put-away method in turn; a failed attempt is undone before the next.
    private func tryMethods(_ methods: [HideMethod], for r: Rolled, done: @escaping (HideMethod?) -> Void) {
        guard let m = methods.first else { done(nil); return }
        let rest = Array(methods.dropFirst())
        guard prepare(m, r) else { tryMethods(rest, for: r, done: done); return }
        perform(m, r)
        // Give the window server a moment, then believe only what it reports.
        DispatchQueue.main.asyncAfter(deadline: .now() + (m == .minimized ? 0.45 : 0.12)) { [weak self] in
            guard let self else { return }
            if self.isPutAway(r, by: m) {
                done(m)
            } else {
                Debug.log("rollup: \(m) did not take effect, rolling back")
                self.restore(r, from: m)
                self.tryMethods(rest, for: r, done: done)
            }
        }
    }

    /// Whether a method may be used at all for this window.
    private func prepare(_ m: HideMethod, _ r: Rolled) -> Bool {
        switch m {
        case .offscreen:
            return true
        case .hiddenApp:
            // Hiding the app hides all its windows: only when this is its only visible one.
            let visible = AXWindow.windows(of: r.pid).filter { $0.isStandard && !$0.isMinimized }
            guard visible.count == 1 else { return false }
            return handOffFocus(from: r.pid)
        case .minimized:
            return true
        }
    }

    private func perform(_ m: HideMethod, _ r: Rolled) {
        switch m {
        case .offscreen:
            // Far beyond every display; many AppKit windows get pulled back, which the
            // verification catches.
            r.window.setPosition(CGPoint(x: -32000, y: -32000))
        case .hiddenApp:
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(r.pid), kAXHiddenAttribute as CFString, kCFBooleanTrue)
        case .minimized:
            AXUIElementSetAttributeValue(r.window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func isPutAway(_ r: Rolled, by m: HideMethod) -> Bool {
        switch m {
        case .offscreen:
            guard let sf = AXWindow.serverFrame(of: r.id) else { return false }
            return !NSScreen.screens.contains { $0.axFrame.intersects(sf) }
        case .hiddenApp:
            return NSRunningApplication(processIdentifier: r.pid)?.isHidden ?? false
        case .minimized:
            return r.window.isMinimized
        }
    }

    private func restore(_ r: Rolled, from m: HideMethod) {
        switch m {
        case .offscreen:
            break
        case .hiddenApp:
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(r.pid), kAXHiddenAttribute as CFString, kCFBooleanFalse)
            NSRunningApplication(processIdentifier: r.pid)?.unhide()
        case .minimized:
            AXUIElementSetAttributeValue(r.window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        r.window.setPosition(r.frame.origin)
    }

    /// Before hiding a frontmost app, give focus to the top window of another app
    /// on this Space; otherwise macOS picks a successor that may live on another
    /// Space and jump there. No other window → don't hide the app (minimize instead).
    private func handOffFocus(from pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != pid, owner != me,
                  let app = NSRunningApplication(processIdentifier: owner), app.activationPolicy == .regular else { continue }
            app.activate()
            return true
        }
        return false
    }

    // MARK: Unroll

    /// Puts the window back. `origin` is where the strip now sits (AX space).
    func unroll(_ id: CGWindowID, at origin: CGPoint?, activate: Bool) {
        guard let r = rolled.removeValue(forKey: id) else { return }
        r.strip?.dismiss()
        r.strip = nil
        restore(r, from: r.method)
        if let origin, origin != r.frame.origin {
            r.window.setPosition(origin)
        }
        if activate { r.window.raise() }
        unwatch(r.pid)
        RollUpJournal.save(Array(rolled.values))
    }

    /// The user brought the window back by other means (Dock, ⌘Tab, app quit).
    private func forget(_ id: CGWindowID) {
        guard let r = rolled.removeValue(forKey: id) else { return }
        r.strip?.dismiss()
        unwatch(r.pid)
        RollUpJournal.save(Array(rolled.values))
    }

    private func appQuit(_ pid: pid_t) {
        for r in rolled.values where r.pid == pid { forget(r.id) }
    }

    // MARK: Watching the real window

    private func watch(_ r: Rolled) {
        guard watchers[r.pid] == nil else { return }
        let pid = r.pid
        watchers[pid] = AXWatch(pid: pid, notifications: [
            kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXApplicationShownNotification,
        ]) { [weak self] note in
            self?.windowEvent(pid: pid, note: note)
        }
    }

    private func unwatch(_ pid: pid_t) {
        guard !rolled.values.contains(where: { $0.pid == pid }) else { return }
        watchers[pid] = nil
    }

    private func windowEvent(pid: pid_t, note: String) {
        for r in rolled.values where r.pid == pid && !busy.contains(r.id) {
            switch note {
            case kAXUIElementDestroyedNotification:
                // Destroyed elements can't be compared reliably; check the window server.
                if AXWindow.serverFrame(of: r.id) == nil { forget(r.id) }
            case kAXWindowDeminiaturizedNotification where r.method == .minimized:
                if !r.window.isMinimized { forget(r.id) }
            case kAXApplicationShownNotification where r.method == .hiddenApp:
                if !(NSRunningApplication(processIdentifier: pid)?.isHidden ?? true) { forget(r.id) }
            default:
                break
            }
        }
    }
}

/// Observes a handful of AX notifications for one app; tears down on deinit.
final class AXWatch {
    private var observer: AXObserver?
    private let handler: (String) -> Void

    init?(pid: pid_t, notifications: [String], handler: @escaping (String) -> Void) {
        self.handler = handler
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXWatch>.fromOpaque(refcon).takeUnretainedValue()
            me.handler(name as String)
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return nil }
        observer = obs
        let app = AXUIElementCreateApplication(pid)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for n in notifications { AXObserverAddNotification(obs, app, n as CFString, ref) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
    }
}

// MARK: - Crash recovery

/// What's rolled up right now, on disk. Rewritten after every change; read at
/// launch to bring back windows a crash left hidden.
enum RollUpJournal {
    struct Entry: Codable {
        var pid: Int32
        var bundleID: String?
        var windowID: UInt32
        var method: RollUpController.HideMethod
        var x: Double, y: Double
    }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Panes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rolled-up.json")
    }

    static func save(_ rolled: [RollUpController.Rolled]) {
        let entries = rolled.map {
            Entry(pid: $0.pid, bundleID: $0.bundleID, windowID: $0.id, method: $0.method,
                  x: $0.frame.minX, y: $0.frame.minY)
        }
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Restores whatever the last run left rolled up, then clears the journal.
    static func recover() {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for e in entries {
            guard let app = NSRunningApplication(processIdentifier: e.pid), !app.isTerminated,
                  app.bundleIdentifier == e.bundleID else { continue }
            switch e.method {
            case .hiddenApp:
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(e.pid), kAXHiddenAttribute as CFString, kCFBooleanFalse)
                app.unhide()
            case .minimized, .offscreen:
                break
            }
            if let w = AXWindow.windows(of: e.pid).first(where: { $0.cgWindowID == e.windowID }) {
                if e.method == .minimized {
                    AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                w.setPosition(CGPoint(x: e.x, y: e.y))
            }
            Debug.log("rollup: recovered \(e.bundleID ?? "?") from journal")
        }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Title-bar double-click

/// An active event tap on its own thread. Single clicks pass untouched; only a
/// second click asks the main thread (bounded wait) whether it hit a title bar,
/// and if so is swallowed so macOS's own double-click action doesn't also run.
final class DoubleClickTap {
    static let shared = DoubleClickTap()

    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: doubleClickTapCallback, userInfo: nil) else {
            Debug.log("doubleclick: tap creation failed")
            return
        }
        tap = port
        let t = Thread { [weak self] in
            guard let self, let port = self.tap else { return }
            let src = CFMachPortCreateRunLoopSource(nil, port, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        t.name = "panes.doubleclick"
        t.start()
        thread = t
    }

    func remove() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let rl = runLoop { CFRunLoopStop(rl) }
        tap = nil; runLoop = nil; thread = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Main thread: roll up if this double-click landed on a title bar.
    fileprivate static func decide(at p: CGPoint) -> Bool {
        guard Settings.shared.data.rollUpEnabled, Settings.shared.data.rollUpOnDoubleClick,
              let hit = Titlebar.hit(at: p), !Settings.shared.isExcluded(hit.window.bundleID) else { return false }
        RollUpController.shared.rollUp(hit.window)
        return true
    }
}

private func doubleClickTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                    refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DoubleClickTap.shared.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard type == .leftMouseDown, event.getIntegerValueField(.mouseEventClickState) == 2,
          event.flags.intersection([.maskAlternate, .maskCommand, .maskShift, .maskControl]).isEmpty else {
        return Unmanaged.passUnretained(event)
    }
    let p = event.location
    // Cheap window-server pre-check: clicks far from any title bar never wait.
    guard Titlebar.mayBeTitlebar(p) else { return Unmanaged.passUnretained(event) }
    let done = DispatchSemaphore(value: 0)
    let result = TapResult()
    DispatchQueue.main.async {
        guard result.claim() else { return }      // timed out already: let the app have it
        result.swallow = DoubleClickTap.decide(at: p)
        done.signal()
    }
    if done.wait(timeout: .now() + .milliseconds(300)) == .success {
        return result.swallow ? nil : Unmanaged.passUnretained(event)
    }
    // Too slow: hand the click to the app unless the main thread already took it.
    return result.claim() ? Unmanaged.passUnretained(event) : nil
}

/// Who gets to decide a pending double-click: the main thread or the timeout.
private final class TapResult {
    private let lock = NSLock()
    private var claimed = false
    var swallow = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
