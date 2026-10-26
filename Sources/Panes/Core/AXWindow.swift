import AppKit
import ApplicationServices

/// Thin wrapper around an AXUIElement that represents a top-level window.
struct AXWindow: Hashable {
    let element: AXUIElement
    let pid: pid_t

    init(_ element: AXUIElement) {
        self.element = element
        var p: pid_t = 0
        AXUIElementGetPid(element, &p)
        self.pid = p
    }

    static func == (a: AXWindow, b: AXWindow) -> Bool { CFEqual(a.element, b.element) }
    func hash(into h: inout Hasher) { h.combine(CFHash(element)) }

    // MARK: Discovery

    static let systemWide = AXUIElementCreateSystemWide()

    /// The focused window of the frontmost application.
    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        if let w: AXUIElement = appEl.attr(kAXFocusedWindowAttribute) { return AXWindow(w) }
        if let w: AXUIElement = appEl.attr(kAXMainWindowAttribute) { return AXWindow(w) }
        return nil
    }

    /// The deepest element at an AX-space point.
    static func element(at p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &el)
        return err == .success ? el : nil
    }

    /// The top-level window under an AX-space point.
    static func at(_ p: CGPoint) -> AXWindow? {
        if let el = element(at: p), let w = window(containing: el) {
            return w
        }
        // Some apps don't answer hit-tests well; fall back to the CGWindow list.
        return fromWindowList(at: p)
    }

    /// Walks up from any element to its owning window.
    static func window(containing el: AXUIElement) -> AXWindow? {
        if el.role == kAXWindowRole { return AXWindow(el) }
        if let w: AXUIElement = el.attr(kAXWindowAttribute) { return AXWindow(w) }
        var cur: AXUIElement? = el
        for _ in 0..<20 {
            guard let c = cur else { break }
            if c.role == kAXWindowRole { return AXWindow(c) }
            cur = c.attr(kAXParentAttribute)
        }
        return nil
    }

    private static func fromWindowList(at p: CGPoint) -> AXWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p) else { continue }
            // CGWindow bounds are already in top-left space.
            for w in windows(of: pid) where w.frame?.roughlyEquals(r, tolerance: 2) == true {
                return w
            }
            return nil
        }
        return nil
    }

    /// All standard windows of an application.
    static func windows(of pid: pid_t) -> [AXWindow] {
        let appEl = AXUIElementCreateApplication(pid)
        let arr: [AXUIElement] = appEl.attr(kAXWindowsAttribute) ?? []
        return arr.map(AXWindow.init)
    }

    /// The app's windows by window number; nil when the app doesn't answer.
    static func windowIDs(of pid: pid_t) -> Set<CGWindowID>? {
        let appEl = AXUIElementCreateApplication(pid)
        guard let arr: [AXUIElement] = appEl.attr(kAXWindowsAttribute) else { return nil }
        return Set(arr.compactMap { AXWindow($0).cgWindowID })
    }

    // MARK: Attributes

    var position: CGPoint? {
        get {
            guard let v: AXValue = element.attr(kAXPositionAttribute) else { return nil }
            var p = CGPoint.zero
            return AXValueGetValue(v, .cgPoint, &p) ? p : nil
        }
    }

    var size: CGSize? {
        guard let v: AXValue = element.attr(kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Frame as the window server sees it. Unlike the AX frame, which the app
    /// reports and which can lag a live title-bar drag by 100ms or more, this
    /// tracks the drag in real time.
    static func serverFrame(of id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: b)
    }

    var title: String { element.attr(kAXTitleAttribute) ?? "" }
    var subrole: String? { element.attr(kAXSubroleAttribute) }
    var isMinimized: Bool { element.attr(kAXMinimizedAttribute) ?? false }
    var isFullScreen: Bool { element.attr("AXFullScreen") ?? false }
    var isStandard: Bool { subrole == kAXStandardWindowSubrole }

    var isResizable: Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
        return settable.boolValue
    }

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    var bundleID: String? { app?.bundleIdentifier }

    /// Stable-ish identity for remembering per-window state across calls.
    var cgWindowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success ? id : nil
    }

    // MARK: Mutation

    func setPosition(_ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v)
        }
    }

    func setSize(_ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v)
        }
    }

    /// Moves and resizes reliably. Apps clamp sizes against the current screen,
    /// so moving across displays needs size→position→size. Enhanced UI (set by
    /// VoiceOver-style tools) makes some apps animate and drop the second call,
    /// so it's switched off for the duration.
    func setFrame(_ r: CGRect) {
        let appEl = AXUIElementCreateApplication(pid)
        let enhanced: Bool = appEl.attr("AXEnhancedUserInterface") ?? false
        if enhanced { AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }

        setSize(r.size)
        setPosition(r.origin)
        setSize(r.size)

        // If the app refused the full size (minimum sizes), keep it on screen.
        if let actual = frame, let screen = NSScreen.screen(forAX: r) {
            let vf = screen.axVisibleFrame
            var o = actual.origin
            if actual.maxX > vf.maxX { o.x = max(vf.minX, vf.maxX - actual.width) }
            if actual.maxY > vf.maxY { o.y = max(vf.minY, vf.maxY - actual.height) }
            if o != actual.origin { setPosition(o) }
        }
    }

    /// Size then position (twice the size, for apps that clamp against the current
    /// screen), without pulling the window back on screen — for layouts that park
    /// windows past the edge on purpose.
    func setFrameUnclamped(_ r: CGRect) {
        setSize(r.size)
        setPosition(r.origin)
        setSize(r.size)
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        app?.activate()
    }

    func unminimize() {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
}

// Private but long-stable API to map an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func attr<T>(_ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self || T.self == AXValue.self { return (v as! T) }
        return v as? T
    }

    var role: String? { attr(kAXRoleAttribute) }
    var subrole: String? { attr(kAXSubroleAttribute) }

    var frame: CGRect? { AXWindow(self).frame }
}
