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

    init?(keyCode: Int, flags: CGEventFlags, handler: @escaping () -> Void) {
        self.keyCode = Int64(keyCode)
        self.flags = flags
        self.handler = handler
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
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
    guard event.getIntegerValueField(.keyboardEventKeycode) == me.keyCode else { return Unmanaged.passUnretained(event) }
    if type == .keyUp {
        if me.swallowUp { me.swallowUp = false; return nil }
        return Unmanaged.passUnretained(event)
    }
    // Exactly the wanted modifiers (arrow keys also carry fn / numeric-pad bits).
    let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    guard event.flags.intersection(relevant) == me.flags else { return Unmanaged.passUnretained(event) }
    me.swallowUp = true
    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        let h = me.handler
        DispatchQueue.main.async { h() }
    }
    return nil
}
