import AppKit

/// Which Space a display is showing, through the window server's private (long
/// stable, widely used) Spaces calls.
enum Spaces {
    /// The display's identifier as the window server names it (its UUID string).
    static func displayID(of screen: NSScreen) -> String? {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The Space the display shows now; nil if it can't be told.
    static func current(on display: String?) -> Int? {
        guard let display else { return nil }
        let id = CGSManagedDisplayGetCurrentSpace(CGSMainConnectionID(), display as CFString)
        return id == 0 ? nil : id
    }
}

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
private func CGSManagedDisplayGetCurrentSpace(_ cid: Int32, _ display: CFString) -> Int
