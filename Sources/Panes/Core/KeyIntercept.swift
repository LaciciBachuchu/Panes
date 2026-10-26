import AppKit

/// Takes over one system shortcut while it's installed: an active event tap on its
/// own thread that swallows just that key combo (down and up) and calls back on the
/// main thread; every other key passes straight through. Used for ⌃↑ while the
/// scroll strip is on, so it opens the strip overview instead of Mission Control.
final class KeyIntercept {
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    fileprivate let keyCode: Int64
    fileprivate let flags: CGEventFlags
    fileprivate let handler: () -> Void
    fileprivate var swallowUp = false
    /// The last press was let through to the system (it opened Mission Control): the
    /// next one goes through too, to close it. Esc or a click closes it instead and
    /// clears this. Touched only on the tap's thread.
    fileprivate var letThrough = false
    /// Asked on the tap's thread at each press: false lets the combo through untouched.
    fileprivate let when: () -> Bool

    init?(keyCode: Int, flags: CGEventFlags, when: @escaping () -> Bool = { true }, handler: @escaping () -> Void) {
        self.keyCode = Int64(keyCode)
        self.flags = flags
        self.when = when
        self.handler = handler
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        // HID level: ahead of the system's own shortcut handling.
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: keyInterceptCallback, userInfo: ref) else { return nil }
        self.port = port
        let t = Thread { [weak self] in
            let src = CFMachPortCreateRunLoopSource(nil, port, 0)
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        t.name = "panes.keyintercept"
        t.start()
    }

    fileprivate func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    deinit {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}

private func keyInterceptCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                  refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<KeyIntercept>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reenable()
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseDown || type == .rightMouseDown {
        me.letThrough = false
        return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .keyDown && code == 53 { me.letThrough = false }      // Esc
    guard code == me.keyCode else { return Unmanaged.passUnretained(event) }
    if type == .keyUp {
        // A key-up whose key-down was swallowed is swallowed too, even if turned off since.
        if me.swallowUp { me.swallowUp = false; return nil }
        return Unmanaged.passUnretained(event)
    }
    // Exactly the wanted modifiers (arrow keys also carry fn / numeric-pad bits).
    let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    guard event.flags.intersection(relevant) == me.flags else { return Unmanaged.passUnretained(event) }
    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        if me.letThrough { me.letThrough = false; return Unmanaged.passUnretained(event) }
        if !me.when() { me.letThrough = true; return Unmanaged.passUnretained(event) }
    } else if me.letThrough || !me.when() {
        return Unmanaged.passUnretained(event)
    }
    me.swallowUp = true
    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        let h = me.handler
        DispatchQueue.main.async { h() }
    }
    return nil
}
