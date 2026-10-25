import AppKit
import Carbon.HIToolbox

/// A rect in unit space (0...1) with top-left origin, relative to a screen's visible frame.
struct UnitRect: Codable, Hashable {
    var x: Double, y: Double, w: Double, h: Double

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    init(_ r: CGRect) { self.init(r.minX, r.minY, r.width, r.height) }

    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    static let full = UnitRect(0, 0, 1, 1)
    static let leftHalf = UnitRect(0, 0, 0.5, 1)
    static let rightHalf = UnitRect(0.5, 0, 0.5, 1)
    static let topHalf = UnitRect(0, 0, 1, 0.5)
    static let bottomHalf = UnitRect(0, 0.5, 1, 0.5)
}

/// A keyboard shortcut stored with Carbon key code and modifier flags.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon cmdKey/optionKey/controlKey/shiftKey

    init(_ keyCode: Int, _ modifiers: Int) {
        self.keyCode = UInt32(keyCode); self.modifiers = UInt32(modifiers)
    }

    init?(event: NSEvent) {
        var m = 0
        let f = event.modifierFlags
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        self.init(Int(event.keyCode), m)
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }

    static let ctrlOpt = controlKey | optionKey
    static let ctrlOptCmd = controlKey | optionKey | cmdKey
    static let ctrlOptShift = controlKey | optionKey | shiftKey
}

enum KeyNames {
    static let special: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_Tab: "⇥", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func name(for code: UInt32) -> String {
        if let s = special[Int(code)] { return s }
        // Ask the current keyboard layout for the printed character.
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { buf -> OSStatus in
            let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &dead, 4, &len, &chars)
        }
        guard status == noErr, len > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case unitRect        // place on a fraction of the screen (with optional cycle)
    case maximize
    case almostMaximize
    case maximizeHeight
    case center
    case restore
    case nextDisplay
    case previousDisplay
    case larger
    case smaller
    case showPalette
    // Removed features; kept so settings saved by earlier builds still decode.
    case rollUp
    case pin
    case magicTiling
    case carry

    var id: String { rawValue }

    static var allCases: [ActionKind] { [.unitRect, .maximize, .almostMaximize, .maximizeHeight, .center, .restore,
                                         .nextDisplay, .previousDisplay, .larger, .smaller, .showPalette, .carry] }

    /// Kinds that belong to an optional feature with its own on/off switch.
    var isFeatureAction: Bool { self == .carry }
    var isRemoved: Bool { self == .rollUp || self == .pin || self == .magicTiling }

    var label: String {
        switch self {
        case .unitRect: return "Position on grid"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost maximize"
        case .maximizeHeight: return "Maximize height"
        case .center: return "Center"
        case .restore: return "Restore previous size"
        case .nextDisplay: return "Move to next display"
        case .previousDisplay: return "Move to previous display"
        case .larger: return "Make larger"
        case .smaller: return "Make smaller"
        case .showPalette: return "Show palette"
        case .rollUp, .pin, .magicTiling: return "Removed"
        case .carry: return "带到每张桌面"
        }
    }
}

enum DisplayTarget: String, Codable, CaseIterable, Identifiable {
    case current, next, previous
    var id: String { rawValue }
    var label: String {
        switch self {
        case .current: return "Current display"
        case .next: return "Next display"
        case .previous: return "Previous display"
        }
    }
}

/// One window command. Unit-rect actions may cycle through several rects when
/// triggered repeatedly (e.g. ½ → ⅔ → ⅓), which replaces Moom's loop chains.
struct WindowAction: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: ActionKind
    var rects: [UnitRect] = []
    var display: DisplayTarget = .current
    var shortcut: Shortcut?
    var inPalette: Bool = false
    var inMenu: Bool = true

    var symbol: String {
        switch kind {
        case .maximize: return "macwindow"
        case .almostMaximize: return "rectangle.inset.filled"
        case .maximizeHeight: return "arrow.up.and.down.square"
        case .center: return "rectangle.center.inset.filled"
        case .restore: return "arrow.uturn.backward.square"
        case .nextDisplay: return "rectangle.righthalf.inset.filled.arrow.right"
        case .previousDisplay: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .larger: return "plus.square"
        case .smaller: return "minus.square"
        case .showPalette: return "square.grid.3x3"
        case .rollUp, .pin, .magicTiling: return "xmark"
        case .carry: return "rectangle.on.rectangle"
        case .unitRect: return "rectangle.split.2x1"
        }
    }
}

enum SnapEdge: String, Codable, CaseIterable, Identifiable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }
    var label: String {
        switch self {
        case .left: return "Left edge"
        case .right: return "Right edge"
        case .top: return "Top edge"
        case .bottom: return "Bottom edge"
        case .topLeft: return "Top-left corner"
        case .topRight: return "Top-right corner"
        case .bottomLeft: return "Bottom-left corner"
        case .bottomRight: return "Bottom-right corner"
        }
    }
}

/// Where the cursor must be (an edge segment or a corner) and where the window goes.
struct SnapArea: Codable, Identifiable, Hashable {
    var id = UUID()
    var edge: SnapEdge
    /// Segment along the edge, 0...1 (left→right for top/bottom, top→bottom for left/right).
    var from: Double = 0
    var to: Double = 1
    var target: UnitRect
    var enabled = true

    var summary: String {
        edge.isCorner ? edge.label : "\(edge.label) \(Int(from * 100))–\(Int(to * 100))%"
    }
}

enum ModifierSet: String, Codable, CaseIterable, Identifiable {
    case none, ctrlOpt, ctrlCmd, optCmd, ctrlOptCmd, ctrlOptCmdShift, ctrlOptShift, ctrlCmdShift, fnCtrl, option, command, shift, control

    var id: String { rawValue }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .none: return []
        case .ctrlOpt: return [.control, .option]
        case .ctrlCmd: return [.control, .command]
        case .optCmd: return [.option, .command]
        case .ctrlOptCmd: return [.control, .option, .command]
        case .ctrlOptCmdShift: return [.control, .option, .command, .shift]
        case .ctrlOptShift: return [.control, .option, .shift]
        case .ctrlCmdShift: return [.control, .command, .shift]
        case .fnCtrl: return [.function, .control]
        case .option: return [.option]
        case .command: return [.command]
        case .shift: return [.shift]
        case .control: return [.control]
        }
    }

    var label: String {
        switch self {
        case .none: return "Off"
        case .ctrlOpt: return "⌃⌥"
        case .ctrlCmd: return "⌃⌘"
        case .optCmd: return "⌥⌘"
        case .ctrlOptCmd: return "⌃⌥⌘"
        case .ctrlOptCmdShift: return "⌃⌥⌘⇧"
        case .ctrlOptShift: return "⌃⌥⇧"
        case .ctrlCmdShift: return "⌃⌘⇧"
        case .fnCtrl: return "fn⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        case .shift: return "⇧"
        case .control: return "⌃"
        }
    }

    /// Exact match on the four main modifiers (plus fn when required).
    func matches(_ f: NSEvent.ModifierFlags) -> Bool {
        guard self != .none else { return false }
        var mask: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        if flags.contains(.function) { mask.insert(.function) }
        return f.intersection(mask) == flags
    }
}

struct SavedWindow: Codable, Hashable {
    var bundleID: String
    var appName: String
    var title: String
    var frame: UnitRect          // absolute AX frame, stored as plain numbers
    var unit: UnitRect           // relative to its display's visible frame
    var displayIndex: Int
}

struct Layout: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var windows: [SavedWindow]
    var displaySignature: String
    var autoApply = false
    var shortcut: Shortcut?
}
