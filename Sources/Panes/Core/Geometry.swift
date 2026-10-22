import AppKit

/// Accessibility APIs use a global coordinate space whose origin is the top-left
/// of the primary display, with Y growing downward. AppKit uses bottom-left with
/// Y growing upward. Everything inside Panes that talks to windows uses AX space.
enum Geometry {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Converts a Cocoa rect (bottom-left origin) to AX space (top-left origin).
    static func axRect(fromCocoa r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Converts an AX rect to Cocoa space. The conversion is its own inverse.
    static func cocoaRect(fromAX r: CGRect) -> CGRect {
        axRect(fromCocoa: r)
    }

    static func axPoint(fromCocoa p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Current mouse location in AX space.
    static var mouseAX: CGPoint {
        axPoint(fromCocoa: NSEvent.mouseLocation)
    }
}

extension NSScreen {
    /// Full frame in AX space.
    var axFrame: CGRect { Geometry.axRect(fromCocoa: frame) }
    /// Usable area (minus menu bar and Dock) in AX space.
    var axVisibleFrame: CGRect { Geometry.axRect(fromCocoa: visibleFrame) }

    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Screen containing an AX-space point.
    static func screen(containingAX p: CGPoint) -> NSScreen? {
        screens.first { $0.axFrame.contains(p) }
    }

    /// Screen that holds the largest part of an AX-space rect.
    static func screen(forAX rect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = -1
        for s in screens {
            let i = s.axFrame.intersection(rect)
            let area = i.isNull ? 0 : i.width * i.height
            if area > bestArea { bestArea = area; best = s }
        }
        if bestArea <= 0 {
            return screen(containingAX: CGPoint(x: rect.midX, y: rect.midY)) ?? main
        }
        return best
    }

    /// Screens ordered left-to-right, then top-to-bottom, for "next display".
    static var ordered: [NSScreen] {
        screens.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.frame.maxY > $1.frame.maxY
        }
    }
}

extension CGRect {
    /// Maps a unit rect (0...1, top-left origin) into this rect.
    func subrect(unit u: CGRect) -> CGRect {
        CGRect(x: minX + u.minX * width,
               y: minY + u.minY * height,
               width: u.width * width,
               height: u.height * height)
    }

    /// Expresses this rect as a unit rect relative to `container`.
    func unit(in container: CGRect) -> CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        return CGRect(x: (minX - container.minX) / container.width,
                      y: (minY - container.minY) / container.height,
                      width: width / container.width,
                      height: height / container.height)
    }

    func roughlyEquals(_ o: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(minX - o.minX) <= tolerance && abs(minY - o.minY) <= tolerance &&
            abs(width - o.width) <= tolerance && abs(height - o.height) <= tolerance
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
