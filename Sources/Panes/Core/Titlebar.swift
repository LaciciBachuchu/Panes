// Title-bar geometry and hit-testing.
// Approach adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// prototype/Window/AXWindow.swift — chromeHeight (traffic lights / toolbar bottom)
// and isChromeControlRole (which controls keep their own double-click).

import AppKit
import ApplicationServices

enum Titlebar {
    /// Height of a plain macOS title bar when nothing better can be measured.
    static let standardHeight: CGFloat = 28

    /// Height of the window's top chrome: the title bar, or the title bar plus a
    /// unified toolbar when the app has one.
    static func height(of w: AXWindow) -> CGFloat {
        guard let f = w.frame else { return standardHeight }
        var h = standardHeight
        // Traffic lights sit vertically centred in the title bar.
        if let close: AXUIElement = w.element.attr(kAXCloseButtonAttribute), let b = close.frame {
            h = max(h, (b.midY - f.minY) * 2)
        }
        if let toolbar = firstChild(of: w.element, role: "AXToolbar"), let t = toolbar.frame {
            h = max(h, t.maxY - f.minY)
        }
        return min(max(h, 20), min(f.height, 120))
    }

    private static func firstChild(of el: AXUIElement, role: String) -> AXUIElement? {
        let kids: [AXUIElement] = el.attr(kAXChildrenAttribute) ?? []
        return kids.first { $0.role == role }
    }

    /// Controls that have their own meaning for clicks and scrolls; the title-bar
    /// features leave them alone.
    static func isControl(_ role: String?) -> Bool {
        switch role ?? "" {
        case "AXButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXSearchField",
             "AXComboBox", "AXCheckBox", "AXSlider", "AXSegmentedControl", "AXDisclosureTriangle",
             "AXLink", "AXTextArea", "AXIncrementor", "AXMenuBar", "AXMenuBarItem":
            return true
        default:
            return false
        }
    }

    /// Content that scrolls by itself (web pages, lists, tables, text).
    static func isScrollableContent(_ role: String?) -> Bool {
        switch role ?? "" {
        case "AXScrollArea", "AXWebArea", "AXTable", "AXOutline", "AXList", "AXBrowser",
             "AXTextArea", "AXCollection", "AXGrid":
            return true
        default:
            return false
        }
    }

    /// Controls that use horizontal swipes themselves (tabs, address bars, sliders).
    static func usesHorizontalSwipes(_ role: String?, subrole: String?) -> Bool {
        switch role ?? "" {
        case "AXRadioButton", "AXTabGroup", "AXRadioGroup", "AXTextField", "AXSearchField",
             "AXComboBox", "AXSlider", "AXScrollBar":
            return true
        default:
            return subrole == "AXTabButton"
        }
    }

    struct Hit {
        let window: AXWindow
        let frame: CGRect
        let barHeight: CGFloat
        let element: AXUIElement
        /// Roles from the hit element up to (not including) the window.
        let chain: [(role: String?, subrole: String?)]
    }

    /// The standard window whose title bar is under an AX-space point, if any.
    /// Pass `allowControls` to accept hits on title-bar controls (e.g. for swipes,
    /// where the caller decides per direction).
    static func hit(at p: CGPoint, allowControls: Bool = false) -> Hit? {
        guard let el = AXWindow.element(at: p) else { return nil }
        var chain: [(String?, String?)] = []
        var cur: AXUIElement? = el
        var win: AXWindow?
        for _ in 0..<12 {
            guard let c = cur else { break }
            if c.role == kAXWindowRole { win = AXWindow(c); break }
            chain.append((c.role, c.subrole))
            cur = c.attr(kAXParentAttribute)
        }
        guard let w = win ?? AXWindow.window(containing: el) else { return nil }
        guard w.pid != ProcessInfo.processInfo.processIdentifier, w.isStandard,
              !w.isFullScreen, let f = w.frame else { return nil }
        let bar = height(of: w)
        guard p.y >= f.minY, p.y <= f.minY + bar else { return nil }
        if !allowControls, chain.contains(where: { isControl($0.0) }) { return nil }
        if chain.contains(where: { isScrollableContent($0.0) }) { return nil }
        return Hit(window: w, frame: f, barHeight: bar, element: el, chain: chain)
    }

    /// Cheap pre-check with the window server only (safe off the main thread):
    /// is the point within the top 120pt of some normal on-screen window?
    static func mayBeTitlebar(_ p: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p) else { continue }
            return p.y <= r.minY + 120
        }
        return false
    }
}
