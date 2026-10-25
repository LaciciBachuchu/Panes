// Glance ("看一眼"): rest the pointer on a rolled-up window for ~0.2s and a card
// hangs under it showing the window's content; leave both for ~0.16s and it goes
// away; click the card to unroll.
// Behaviour adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// docs/glance.md and prototype/Overlay/GlancePanel.swift — the timings, the 6pt gap,
// ignoring the pointer that was already there when the window rolled up, skipping the
// traffic lights, and labelling a picture that isn't live.
// The rolled window really is short now, so the card shows the snapshot taken at
// roll-up time (needs Screen Recording).

import AppKit

final class GlanceController {
    static let shared = GlanceController()

    private var moveMonitor: Any?
    private var clickMonitor: Any?
    private var lastCheck = Date.distantPast
    private var hovered: CGWindowID?
    private var card: GlanceCard?
    private var showWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    /// The window the pointer was resting on when it rolled up: ignore until left.
    private var ignoring: CGWindowID?

    private var rolled: [CGWindowID: RollUpController.Rolled] { RollUpController.shared.rolled }

    /// Listens to the mouse only while something is rolled up and glance is on.
    func update(justRolled: CGWindowID? = nil) {
        if let justRolled { ignoring = justRolled }
        let want = Settings.shared.data.glanceEnabled && !rolled.isEmpty
        if want, moveMonitor == nil {
            moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.mouseMoved() }
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.close(animated: false)
            }
        } else if !want {
            if let m = moveMonitor { NSEvent.removeMonitor(m) }
            if let m = clickMonitor { NSEvent.removeMonitor(m) }
            moveMonitor = nil; clickMonitor = nil
            close(animated: false)
        }
    }

    /// The topmost window under the pointer, if it's a rolled-up one.
    func rolledWindowUnderPointer() -> CGWindowID? {
        guard !rolled.isEmpty else { return nil }
        let p = Geometry.mouseAX
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p) else { continue }
            let id = info[kCGWindowNumber as String] as? CGWindowID
            return id.flatMap { rolled[$0] != nil ? $0 : nil }
        }
        return nil
    }

    private func mouseMoved() {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 0.03 else { return }
        lastCheck = now
        var id = rolledWindowUnderPointer()
        // The traffic lights have their own hover menu.
        if let i = id, let f = AXWindow.serverFrame(of: i), Geometry.mouseAX.x - f.minX < 80 { id = nil }
        if id != ignoring { ignoring = nil }
        if id != nil && id == ignoring { id = nil }

        if card?.frame.contains(NSEvent.mouseLocation) == true {
            closeWork?.cancel()
            return
        }
        guard id != hovered else { return }
        hovered = id
        showWork?.cancel()
        if let id {
            closeWork?.cancel()
            if card?.windowID == id { return }
            let w = DispatchWorkItem { [weak self] in self?.show(id) }
            showWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
        } else if card != nil {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.card?.frame.contains(NSEvent.mouseLocation) != true else { return }
                self.close(animated: true)
            }
            closeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: w)
        }
    }

    private func show(_ id: CGWindowID) {
        guard let r = rolled[id], let strip = AXWindow.serverFrame(of: id) else { return }
        close(animated: false)
        let c = GlanceCard(rolled: r, below: strip)
        c.onClick = { RollUpController.shared.unroll(id, activate: true) }
        c.present()
        card = c
    }

    func close(animated: Bool) {
        showWork?.cancel()
        card?.close(animated: animated)
        card = nil
        hovered = nil
    }
}

/// The card under a rolled-up window showing what it held.
final class GlanceCard {
    let windowID: CGWindowID
    private let panel: NSPanel
    var onClick: () -> Void = {}
    var frame: CGRect { panel.frame }

    init(rolled r: RollUpController.Rolled, below strip: CGRect) {
        windowID = r.id
        let gap: CGFloat = 6
        var ax = CGRect(x: strip.minX, y: strip.maxY + gap, width: strip.width, height: max(80, r.fullHeight - r.barHeight))
        if let screen = NSScreen.screen(containingAX: CGPoint(x: strip.midX, y: strip.minY)) {
            ax.size.height = min(ax.height, screen.axVisibleFrame.maxY - ax.minY - 4)
        }
        panel = NSPanel(contentRect: Geometry.cocoaRect(fromAX: ax), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        let view = GlanceView(frame: CGRect(origin: .zero, size: ax.size))
        view.onClick = { [weak self] in self?.onClick() }
        if let img = r.snapshot.flatMap({ Self.cropBelowBar($0, bar: r.barHeight, height: ax.height, windowWidth: r.snapshotWidth) }) {
            view.show(image: img, note: nil)
        } else {
            view.show(image: nil, note: WindowCapture.hasPermission
                      ? "画面暂时看不到"
                      : "画面暂时看不到\n需要在“系统设置 → 隐私与安全性 → 屏幕录制”里允许 Panes")
        }
        panel.contentView = view
    }

    static func cropBelowBar(_ img: CGImage, bar: CGFloat, height: CGFloat, windowWidth: CGFloat) -> CGImage? {
        let scale = CGFloat(img.width) / max(1, windowWidth)
        let top = (bar * scale).rounded()
        let h = min(CGFloat(img.height) - top, (height * scale).rounded())
        guard h > 0 else { return nil }
        return img.cropping(to: CGRect(x: 0, y: top, width: CGFloat(img.width), height: h))
    }

    func present() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    func close(animated: Bool) {
        let p = panel
        guard animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }
}

private final class GlanceView: NSView {
    var onClick: () -> Void = {}
    private let imageLayer = CALayer()
    private let badge = NSTextField(labelWithString: "  收起时的画面  ")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageLayer.frame = bounds
        imageLayer.contentsGravity = .topLeft
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(imageLayer)
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.layer?.cornerRadius = 5
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        noteLabel.alignment = .center
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noteLabel)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            noteLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            noteLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            noteLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(image: CGImage?, note: String?) {
        imageLayer.contents = image
        if let image { imageLayer.contentsScale = CGFloat(image.width) / max(1, bounds.width) }
        badge.isHidden = image == nil
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick() }
}
