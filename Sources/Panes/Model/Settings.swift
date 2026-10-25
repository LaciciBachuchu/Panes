import AppKit
import Carbon.HIToolbox
import Combine

struct SettingsData: Codable {
    // Snapping
    var snapEnabled = true
    var snapThreshold: Double = 8
    var cornerSize: Double = 40
    var snapAreas: [SnapArea] = Defaults.snapAreas
    var restoreSizeOnDragAway = true
    var disableSnapModifier: ModifierSet = .command
    var previewAnimates = true

    // Layout
    var gap: Double = 0
    var almostMaximizeInset: Double = 0.9

    // Actions & shortcuts
    var actions: [WindowAction] = Defaults.actions

    // Palette (Moom-style)
    var paletteOnHover = true
    var paletteHoverDelay: Double = 0.45
    var gridColumns = 8
    var gridRows = 6

    // Hover move / resize
    var moveModifier: ModifierSet = .ctrlOptCmd
    var resizeModifier: ModifierSet = .ctrlOptCmdShift
    var raiseOnHoverMove = false

    // Layouts
    var layouts: [Layout] = []
    var skipMinimizedOnRestore = true

    // Roll up (卷起) and glance (看一眼)
    var rollUpEnabled = true
    var rollUpOnDoubleClick = true
    var glanceEnabled = true

    // Titlebar gestures
    var trackpadGesturesEnabled = true
    var scrollWheelGesturesEnabled = true
    var flingEnabled = true

    // Pin and magic tiling
    var pinEnabled = true
    var magicTilingEnabled = true

    // General
    var excludedBundleIDs: [String] = []
    var showMenuBarIcon = true

    init() {}

    // Tolerate new keys being added between versions.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ cur: inout T) {
            if let v = try? c.decode(T.self, forKey: k) { cur = v }
        }
        d(.snapEnabled, &snapEnabled); d(.snapThreshold, &snapThreshold); d(.cornerSize, &cornerSize)
        d(.snapAreas, &snapAreas); d(.restoreSizeOnDragAway, &restoreSizeOnDragAway)
        d(.disableSnapModifier, &disableSnapModifier); d(.previewAnimates, &previewAnimates)
        d(.gap, &gap); d(.almostMaximizeInset, &almostMaximizeInset); d(.actions, &actions)
        d(.paletteOnHover, &paletteOnHover); d(.paletteHoverDelay, &paletteHoverDelay)
        d(.gridColumns, &gridColumns); d(.gridRows, &gridRows)
        d(.moveModifier, &moveModifier); d(.resizeModifier, &resizeModifier); d(.raiseOnHoverMove, &raiseOnHoverMove)
        d(.layouts, &layouts); d(.skipMinimizedOnRestore, &skipMinimizedOnRestore)
        d(.excludedBundleIDs, &excludedBundleIDs); d(.showMenuBarIcon, &showMenuBarIcon)
        d(.rollUpEnabled, &rollUpEnabled); d(.rollUpOnDoubleClick, &rollUpOnDoubleClick); d(.glanceEnabled, &glanceEnabled)
        d(.trackpadGesturesEnabled, &trackpadGesturesEnabled); d(.scrollWheelGesturesEnabled, &scrollWheelGesturesEnabled)
        d(.flingEnabled, &flingEnabled); d(.pinEnabled, &pinEnabled); d(.magicTilingEnabled, &magicTilingEnabled)
        // Settings saved before a feature existed lack its action: add the default one.
        for a in Defaults.actions where a.kind.isFeatureAction && !actions.contains(where: { $0.kind == a.kind }) {
            actions.append(a)
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private static let key = "PanesSettings.v1"

    @Published var data: SettingsData {
        didSet { save() }
    }

    private init() {
        if let raw = UserDefaults.standard.data(forKey: Self.key),
           let d = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            data = d
        } else {
            data = SettingsData()
        }
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(raw, forKey: Self.key)
        }
    }

    /// Whether an action's feature is switched on (always true for plain actions).
    func isEnabled(_ kind: ActionKind) -> Bool {
        switch kind {
        case .rollUp: return data.rollUpEnabled
        case .pin: return data.pinEnabled
        case .magicTiling: return data.magicTilingEnabled
        default: return true
        }
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        return data.excludedBundleIDs.contains(b)
    }

    func exportJSON() -> Data? {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(data)
    }

    func importJSON(_ raw: Data) -> Bool {
        guard let d = try? JSONDecoder().decode(SettingsData.self, from: raw) else { return false }
        data = d
        return true
    }

    func resetActions() { data.actions = Defaults.actions }
    func resetSnapAreas() { data.snapAreas = Defaults.snapAreas }
}

enum Defaults {
    static let third = 1.0 / 3.0

    static var actions: [WindowAction] {
        let m = Shortcut.ctrlOpt
        func a(_ name: String, _ rects: [UnitRect], _ key: Int, palette: Bool = false) -> WindowAction {
            WindowAction(name: name, kind: .unitRect, rects: rects, shortcut: Shortcut(key, m), inPalette: palette)
        }
        func k(_ name: String, _ kind: ActionKind, _ sc: Shortcut?, palette: Bool = false) -> WindowAction {
            WindowAction(name: name, kind: kind, shortcut: sc, inPalette: palette)
        }
        return [
            a("Left Half", [.leftHalf, UnitRect(0, 0, 2 * third, 1), UnitRect(0, 0, third, 1)], kVK_LeftArrow, palette: true),
            a("Right Half", [.rightHalf, UnitRect(third, 0, 2 * third, 1), UnitRect(2 * third, 0, third, 1)], kVK_RightArrow, palette: true),
            a("Top Half", [.topHalf, UnitRect(0, 0, 1, 2 * third), UnitRect(0, 0, 1, third)], kVK_UpArrow),
            a("Bottom Half", [.bottomHalf, UnitRect(0, third, 1, 2 * third), UnitRect(0, 2 * third, 1, third)], kVK_DownArrow),
            a("Top Left", [UnitRect(0, 0, 0.5, 0.5)], kVK_ANSI_U, palette: true),
            a("Top Right", [UnitRect(0.5, 0, 0.5, 0.5)], kVK_ANSI_I, palette: true),
            a("Bottom Left", [UnitRect(0, 0.5, 0.5, 0.5)], kVK_ANSI_J, palette: true),
            a("Bottom Right", [UnitRect(0.5, 0.5, 0.5, 0.5)], kVK_ANSI_K, palette: true),
            a("Left Third", [UnitRect(0, 0, third, 1)], kVK_ANSI_D),
            a("Center Third", [UnitRect(third, 0, third, 1)], kVK_ANSI_F),
            a("Right Third", [UnitRect(2 * third, 0, third, 1)], kVK_ANSI_G),
            a("Left Two Thirds", [UnitRect(0, 0, 2 * third, 1)], kVK_ANSI_E),
            a("Right Two Thirds", [UnitRect(third, 0, 2 * third, 1)], kVK_ANSI_T),
            k("Maximize", .maximize, Shortcut(kVK_Return, m), palette: true),
            k("Almost Maximize", .almostMaximize, Shortcut(kVK_ANSI_M, m)),
            k("Maximize Height", .maximizeHeight, Shortcut(kVK_UpArrow, m | shiftKey)),
            k("Center", .center, Shortcut(kVK_ANSI_C, m), palette: true),
            k("Restore", .restore, Shortcut(kVK_Delete, m)),
            k("Larger", .larger, Shortcut(kVK_ANSI_Equal, m)),
            k("Smaller", .smaller, Shortcut(kVK_ANSI_Minus, m)),
            k("Next Display", .nextDisplay, Shortcut(kVK_RightArrow, Shortcut.ctrlOptCmd), palette: true),
            k("Previous Display", .previousDisplay, Shortcut(kVK_LeftArrow, Shortcut.ctrlOptCmd)),
            k("Show Palette", .showPalette, Shortcut(kVK_ANSI_P, m)),
            // ⌃⌥⌘ is held for hover-move, so the newer features live on ⌃⌥⇧.
            k("Roll Up", .rollUp, Shortcut(kVK_ANSI_C, Shortcut.ctrlOptShift)),
            k("Pin on Top", .pin, Shortcut(kVK_ANSI_P, Shortcut.ctrlOptShift)),
            k("Magic Tiling", .magicTiling, Shortcut(kVK_ANSI_T, Shortcut.ctrlOptShift)),
        ]
    }

    static var snapAreas: [SnapArea] {
        [
            SnapArea(edge: .topLeft, target: UnitRect(0, 0, 0.5, 0.5)),
            SnapArea(edge: .topRight, target: UnitRect(0.5, 0, 0.5, 0.5)),
            SnapArea(edge: .bottomLeft, target: UnitRect(0, 0.5, 0.5, 0.5)),
            SnapArea(edge: .bottomRight, target: UnitRect(0.5, 0.5, 0.5, 0.5)),
            SnapArea(edge: .top, from: 0, to: 1, target: .full),
            SnapArea(edge: .left, from: 0, to: 1, target: .leftHalf),
            SnapArea(edge: .right, from: 0, to: 1, target: .rightHalf),
            SnapArea(edge: .bottom, from: 0, to: third, target: UnitRect(0, 0, third, 1)),
            SnapArea(edge: .bottom, from: third, to: 2 * third, target: UnitRect(third, 0, third, 1)),
            SnapArea(edge: .bottom, from: 2 * third, to: 1, target: UnitRect(2 * third, 0, third, 1)),
        ]
    }
}
