import AppKit

/// Hold a modifier combo and just move the mouse to move (or resize) the window
/// under the cursor — no clicking, works on background windows.
final class HoverMoveResize {
    static let shared = HoverMoveResize()

    private enum Mode { case move, resize }
    private var monitors: [Any] = []
    private var mode: Mode?
    private var window: AXWindow?
    private var lastMouse: CGPoint = .zero
    private var frame: CGRect = .zero
    private var corner: (left: Bool, top: Bool) = (false, false)
    private var pendingApply = false

    func start() {
        stop()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in self?.flagsChanged(e.modifierFlags) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in self?.mouseMoved() }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        end()
    }

    private func flagsChanged(_ f: NSEvent.ModifierFlags) {
        let s = Settings.shared.data
        // Check resize first: its combo is usually a superset of the move combo.
        let newMode: Mode? = s.resizeModifier.matches(f) ? .resize : (s.moveModifier.matches(f) ? .move : nil)
        guard newMode != mode else { return }
        end()
        guard let newMode else { return }
        let p = Geometry.mouseAX
        guard let w = AXWindow.at(p), w.pid != ProcessInfo.processInfo.processIdentifier,
              !Settings.shared.isExcluded(w.bundleID), !w.isFullScreen, let fr = w.frame else { return }
        mode = newMode
        window = w
        frame = fr
        lastMouse = p
        corner = (p.x < fr.midX, p.y < fr.midY)
        if s.raiseOnHoverMove { w.raise() }
    }

    private func end() {
        mode = nil
        window = nil
    }

    private func mouseMoved() {
        guard let mode, let w = window else { return }
        let p = Geometry.mouseAX
        let dx = p.x - lastMouse.x, dy = p.y - lastMouse.y
        lastMouse = p
        switch mode {
        case .move:
            frame.origin.x += dx
            frame.origin.y += dy
        case .resize:
            if corner.left { frame.origin.x += dx; frame.size.width -= dx } else { frame.size.width += dx }
            if corner.top { frame.origin.y += dy; frame.size.height -= dy } else { frame.size.height += dy }
            frame.size.width = max(frame.width, 120)
            frame.size.height = max(frame.height, 80)
        }
        // Coalesce: AX calls are slow, so apply at most once per runloop pass.
        guard !pendingApply else { return }
        pendingApply = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingApply = false
            guard self.mode != nil else { return }
            if mode == .move {
                w.setPosition(self.frame.origin)
            } else {
                w.setPosition(self.frame.origin)
                w.setSize(self.frame.size)
            }
        }
    }
}
