// Roll up ("卷起"): the window itself shrinks to the height of its title bar and
// stays where it is, like the classic Mac OS window shade. Nothing is hidden,
// parked off screen or minimized — dragging the strip drags the real window, and
// unrolling gives it back its height wherever it now sits.
// Pieces adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// prototype/Recovery/Journal.swift (a durable journal so a crash never strands a
// window rolled up) and prototype/App/EventTapCallback.swift (an active tap that only
// asks about double-clicks).

import AppKit
import ApplicationServices

final class RollUpController {
    static let shared = RollUpController()

    final class Rolled {
        let id: CGWindowID
        let window: AXWindow
        let pid: pid_t
        let bundleID: String?
        let fullHeight: CGFloat
        let barHeight: CGFloat
        let snapshot: CGImage?
        let snapshotWidth: CGFloat

        init(id: CGWindowID, window: AXWindow, fullHeight: CGFloat, barHeight: CGFloat, snapshot: CGImage?, width: CGFloat) {
            self.id = id; self.window = window; self.pid = window.pid; self.bundleID = window.bundleID
            self.fullHeight = fullHeight; self.barHeight = barHeight; self.snapshot = snapshot; self.snapshotWidth = width
        }
    }

    private(set) var rolled: [CGWindowID: Rolled] = [:]
    private var watchers: [pid_t: AXWatch] = [:]
    private var signalSources: [DispatchSourceSignal] = []
    /// The tallest a window may stay and still count as rolled up. Many apps have a
    /// minimum height a bit above the title bar (TextEdit: title + format bar, 82pt);
    /// apps whose minimum is taller than this can't be rolled up.
    private static let maxRolledHeight: CGFloat = 120

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
        GlanceController.shared.update()
    }

    /// Give every rolled window its height back (quit, signal, feature switched off).
    func unrollAll() {
        for id in Array(rolled.keys) { unroll(id, activate: false) }
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

    /// Hotkey: unroll the rolled window under the pointer or in focus, else roll up the focused window.
    func toggle(_ target: AXWindow?) {
        if let id = GlanceController.shared.rolledWindowUnderPointer() {
            unroll(id, activate: true)
            return
        }
        guard let w = target ?? AXWindow.focused() else { NSSound.beep(); return }
        if let id = w.cgWindowID, rolled[id] != nil {
            unroll(id, activate: true)
        } else if !rollUp(w) {
            NSSound.beep()
        }
    }

    func isRolled(_ w: AXWindow) -> Bool { w.cgWindowID.map { rolled[$0] != nil } ?? false }

    // MARK: Roll up / unroll

    /// Shrinks the window to its title bar. Returns false (and leaves the window as
    /// it was) when the app won't let it get that short.
    @discardableResult
    func rollUp(_ w: AXWindow) -> Bool {
        guard settings.rollUpEnabled, let id = w.cgWindowID, rolled[id] == nil,
              !Settings.shared.isExcluded(w.bundleID), w.isStandard, !w.isFullScreen, !w.isMinimized,
              w.isResizable, let frame = w.frame else { return false }
        let bar = Titlebar.height(of: w)
        let snapshot = WindowCapture.snapshot(id)
        w.setSize(CGSize(width: frame.width, height: bar))
        guard let after = w.frame, after.height <= max(bar + 40, Self.maxRolledHeight) else {
            Debug.log("rollup: \(w.bundleID ?? "?") refuses to get shorter than \(Int(w.frame?.height ?? 0))pt")
            w.setSize(frame.size)
            w.setPosition(frame.origin)
            GestureHUD.shared.flash("这个窗口不能卷起", anchor: CGPoint(x: frame.midX, y: frame.minY + bar))
            return false
        }
        // Some apps keep the window's bottom fixed while resizing: put the top back.
        if abs(after.minY - frame.minY) > 1 { w.setPosition(CGPoint(x: after.minX, y: frame.minY)) }
        rolled[id] = Rolled(id: id, window: w, fullHeight: frame.height, barHeight: after.height,
                            snapshot: snapshot, width: frame.width)
        watch(w.pid)
        RollUpJournal.save(Array(rolled.values))
        GlanceController.shared.update(justRolled: id)
        Debug.log("rollup: \(w.bundleID ?? "?") to \(Int(after.height))pt")
        return true
    }

    /// Gives the window its height back, below wherever its title bar is now.
    func unroll(_ id: CGWindowID, activate: Bool) {
        guard let r = rolled.removeValue(forKey: id) else { return }
        GlanceController.shared.close(animated: false)
        if let f = r.window.frame {
            // setFrame keeps the window on screen if the full height wouldn't fit below the bar.
            r.window.setFrame(CGRect(x: f.minX, y: f.minY, width: f.width, height: r.fullHeight))
        }
        if activate { r.window.raise() }
        unwatch(r.pid)
        RollUpJournal.save(Array(rolled.values))
        GlanceController.shared.update()
    }

    /// The user brought the window back by other means (resized it, closed it, quit).
    private func forget(_ id: CGWindowID) {
        guard let r = rolled.removeValue(forKey: id) else { return }
        unwatch(r.pid)
        RollUpJournal.save(Array(rolled.values))
        GlanceController.shared.update()
    }

    private func appQuit(_ pid: pid_t) {
        for r in rolled.values where r.pid == pid { forget(r.id) }
    }

    // MARK: Watching rolled windows

    private func watch(_ pid: pid_t) {
        guard watchers[pid] == nil else { return }
        watchers[pid] = AXWatch(pid: pid, notifications: [
            kAXUIElementDestroyedNotification, kAXWindowResizedNotification, kAXWindowMovedNotification,
        ]) { [weak self] note in
            self?.windowEvent(pid: pid, note: note)
        }
    }

    private func unwatch(_ pid: pid_t) {
        guard !rolled.values.contains(where: { $0.pid == pid }) else { return }
        watchers[pid] = nil
    }

    private func windowEvent(pid: pid_t, note: String) {
        for r in rolled.values where r.pid == pid {
            switch note {
            case kAXUIElementDestroyedNotification:
                if AXWindow.serverFrame(of: r.id) == nil { forget(r.id) }
            case kAXWindowResizedNotification:
                // Dragged taller by hand: it's no longer rolled up.
                if let f = r.window.frame, f.height > r.barHeight + 40 { forget(r.id) }
            default:
                GlanceController.shared.close(animated: false)    // the strip is being dragged
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
/// launch to give back the height of windows a crash left rolled up.
enum RollUpJournal {
    struct Entry: Codable {
        var pid: Int32
        var bundleID: String?
        var windowID: UInt32
        var height: Double
    }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Panes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rolled-up.json")
    }

    static func save(_ rolled: [RollUpController.Rolled]) {
        let entries = rolled.map { Entry(pid: $0.pid, bundleID: $0.bundleID, windowID: $0.id, height: $0.fullHeight) }
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Restores whatever the last run left rolled up, then clears the journal.
    /// Journals from the earlier hide/minimize design don't decode and are dropped.
    static func recover() {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for e in entries {
            guard let app = NSRunningApplication(processIdentifier: e.pid), !app.isTerminated,
                  app.bundleIdentifier == e.bundleID,
                  let w = AXWindow.windows(of: e.pid).first(where: { $0.cgWindowID == e.windowID }),
                  let f = w.frame else { continue }
            w.setFrame(CGRect(x: f.minX, y: f.minY, width: f.width, height: e.height))
            Debug.log("rollup: recovered \(e.bundleID ?? "?") from journal")
        }
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
              let hit = Titlebar.hit(at: p), !Settings.shared.isExcluded(hit.window.bundleID) else {
            Debug.log("doubleclick: not a title bar at \(p) role=\(AXWindow.element(at: p)?.role ?? "nil")")
            return false
        }
        let rc = RollUpController.shared
        if let id = hit.window.cgWindowID, rc.rolled[id] != nil {
            rc.unroll(id, activate: true)
            return true
        }
        // Only swallow the click if the window actually rolled up; otherwise the
        // app (and macOS) keep their own double-click behaviour.
        return rc.rollUp(hit.window)
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
