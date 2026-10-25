// The strip a rolled-up window leaves behind, and the glance card under it.
// Behaviour adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// docs/glance.md and prototype/Overlay/{ShadeStrip,GlancePanel}.swift — show after a
// ~0.2s rest, close ~0.16s after leaving both strip and card, card hangs 6pt below,
// click the card to unroll, label stale pictures, ignore the pointer that was already
// on the strip when it appeared until it leaves once.

import AppKit

final class ShadeStrip: NSObject {
    private unowned let rolled: RollUpController.Rolled
    private let panel: NSPanel
    private let view: StripView
    private var card: GlanceCard?
    private var showTimer: Timer?
    private var closeTimer: Timer?
    private var insideStrip = false
    private var insideCard = false
    /// The pointer was already on the strip when it appeared (it just rolled up).
    private var ignoreUntilExit = false

    var frame: CGRect { panel.frame }
    var axOrigin: CGPoint { Geometry.axRect(fromCocoa: panel.frame).origin }

    init(rolled: RollUpController.Rolled) {
        self.rolled = rolled
        let ax = CGRect(x: rolled.frame.minX, y: rolled.frame.minY, width: rolled.frame.width, height: rolled.barHeight)
        panel = NSPanel(contentRect: Geometry.cocoaRect(fromAX: ax), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        view = StripView(frame: CGRect(origin: .zero, size: ax.size))
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        view.configure(snapshot: rolled.snapshot, windowWidth: rolled.frame.width, barHeight: rolled.barHeight, title: rolled.title,
                       icon: NSRunningApplication(processIdentifier: rolled.pid)?.icon)
        view.onDoubleClick = { [weak self] in self?.unroll() }
        view.onClick = { [weak self] in self?.openGlanceNow() }
        view.onDragBegan = { [weak self] in self?.closeGlance(animated: false) }
        view.onHover = { [weak self] inside in self?.stripHover(inside) }
        panel.contentView = view
    }

    func show() {
        ignoreUntilExit = panel.frame.contains(NSEvent.mouseLocation)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    func dismiss() {
        closeGlance(animated: false)
        showTimer?.invalidate(); closeTimer?.invalidate()
        panel.orderOut(nil)
    }

    private func unroll() {
        RollUpController.shared.unroll(rolled.id, at: axOrigin, activate: true)
    }

    // MARK: Hover → glance

    private func stripHover(_ inside: Bool) {
        insideStrip = inside
        if !inside { ignoreUntilExit = false }
        guard Settings.shared.data.glanceEnabled, !ignoreUntilExit else { return }
        if inside {
            closeTimer?.invalidate()
            guard card == nil else { return }
            prepareCard()   // start the picture now so it's ready when the card shows
            showTimer?.invalidate()
            showTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in self?.card?.present() }
        } else {
            showTimer?.invalidate()
            scheduleClose()
        }
    }

    private func cardHover(_ inside: Bool) {
        insideCard = inside
        if inside { closeTimer?.invalidate() } else { scheduleClose() }
    }

    private func scheduleClose() {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: false) { [weak self] _ in
            guard let self, !self.insideStrip, !self.insideCard else { return }
            self.closeGlance(animated: true)
        }
    }

    private func openGlanceNow() {
        guard Settings.shared.data.glanceEnabled else { return }
        ignoreUntilExit = false
        showTimer?.invalidate()
        if card == nil { prepareCard() }
        card?.present()
    }

    private func prepareCard() {
        let stripAX = Geometry.axRect(fromCocoa: panel.frame)
        let c = GlanceCard(rolled: rolled, below: stripAX)
        c.onHover = { [weak self] inside in self?.cardHover(inside) }
        c.onClick = { [weak self] in self?.unroll() }
        card = c
    }

    func closeGlance(animated: Bool) {
        showTimer?.invalidate()
        insideCard = false
        card?.close(animated: animated)
        card = nil
    }
}

/// Draws the strip: the real title bar cut from the snapshot when there is one,
/// otherwise the app icon and window title on a title-bar material.
private final class StripView: NSView {
    var onDoubleClick: () -> Void = {}
    var onClick: () -> Void = {}
    var onDragBegan: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    private let imageLayer = CALayer()
    private var downPoint: CGPoint?
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(snapshot: CGImage?, windowWidth: CGFloat, barHeight: CGFloat, title: String, icon: NSImage?) {
        if let snapshot, let bar = Self.cropTop(snapshot, points: barHeight, windowWidth: windowWidth) {
            imageLayer.contents = bar
            imageLayer.contentsGravity = .resize
            imageLayer.frame = bounds
            imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(imageLayer)
            return
        }
        let bg = NSVisualEffectView(frame: bounds)
        bg.material = .titlebar
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.autoresizingMask = [.width, .height]
        addSubview(bg)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        if let icon {
            let iv = NSImageView(image: icon)
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 16).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 16).isActive = true
            stack.addArrangedSubview(iv)
        }
        let label = NSTextField(labelWithString: title.isEmpty ? "已卷起的窗口" : title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 80),
        ])
    }

    /// The top `points` of a window snapshot (pixels per point = image width / window width).
    static func cropTop(_ img: CGImage, points: CGFloat, windowWidth: CGFloat) -> CGImage? {
        let scale = CGFloat(img.width) / max(1, windowWidth)
        let h = min(CGFloat(img.height), (points * scale).rounded())
        return img.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(img.width), height: h))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick(); return }
        downPoint = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downPoint, !dragged else { return }
        let p = event.locationInWindow
        guard hypot(p.x - d.x, p.y - d.y) > 3 else { return }
        dragged = true
        onDragBegan()
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        // A single click opens the glance right away; wait out the double-click
        // interval so a double-click doesn't flash the card first.
        guard !dragged, event.clickCount == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) { [weak self] in
            guard let self, self.window?.isVisible == true, self.downPoint == nil else { return }
            self.onClick()
        }
    }
}

/// The card under the strip showing the window's content at its real size.
final class GlanceCard {
    private let rolled: RollUpController.Rolled
    private let panel: NSPanel
    private let content = GlanceView()
    private var stream: LiveWindowStream?
    private(set) var isShown = false
    var onHover: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}

    init(rolled: RollUpController.Rolled, below strip: CGRect) {
        self.rolled = rolled
        // Same width and x as the real window, 6pt under the strip, clipped to the screen.
        let gap: CGFloat = 6
        var ax = CGRect(x: strip.minX, y: strip.maxY + gap, width: rolled.frame.width,
                        height: max(80, rolled.frame.height - rolled.barHeight))
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
        content.frame = CGRect(origin: .zero, size: ax.size)
        content.onHover = { [weak self] in self?.onHover($0) }
        content.onClick = { [weak self] in self?.onClick() }
        panel.contentView = content

        // Picture: live when the window is still composited (parked off screen),
        // else the snapshot from roll-up time, else a note.
        let cropped = rolled.snapshot.flatMap { Self.cropBelowBar($0, bar: rolled.barHeight, height: ax.height, windowWidth: rolled.frame.width) }
        if rolled.method == .offscreen, WindowCapture.hasPermission {
            content.show(image: cropped, stale: false, note: nil)
            let s = LiveWindowStream(layer: content.liveLayer)
            s.onFirstFrame = { [weak self] in self?.content.liveStarted(barHeight: rolled.barHeight, full: rolled.frame.size) }
            s.start(windowID: rolled.id, size: rolled.frame.size, scale: NSScreen.main?.backingScaleFactor ?? 2)
            stream = s
        } else if let cropped {
            content.show(image: cropped, stale: true, note: nil)
        } else {
            content.show(image: nil, stale: true,
                         note: WindowCapture.hasPermission ? "画面暂时看不到" : "画面暂时看不到\n需要在“系统设置 → 隐私与安全性 → 屏幕录制”里允许 Panes")
        }
    }

    static func cropBelowBar(_ img: CGImage, bar: CGFloat, height: CGFloat, windowWidth: CGFloat) -> CGImage? {
        let scale = CGFloat(img.width) / max(1, windowWidth)
        let top = (bar * scale).rounded()
        let h = min(CGFloat(img.height) - top, (height * scale).rounded())
        guard h > 0 else { return nil }
        return img.cropping(to: CGRect(x: 0, y: top, width: CGFloat(img.width), height: h))
    }

    func present() {
        guard !isShown else { return }
        isShown = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    func close(animated: Bool) {
        stream?.stop()
        stream = nil
        let p = panel
        guard isShown, animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }
}

private final class GlanceView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}
    let liveLayer = CALayer()
    private let imageLayer = CALayer()
    private let badge = NSTextField(labelWithString: "收起时的画面")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        for l in [imageLayer, liveLayer] {
            l.frame = bounds
            l.contentsGravity = .topLeft
            l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(l)
        }
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.layer?.cornerRadius = 5
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        noteLabel.alignment = .center
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.isHidden = true
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

    func show(image: CGImage?, stale: Bool, note: String?) {
        imageLayer.contents = image
        // Draw at the window's real size: pixels per point of the picture.
        if let image { imageLayer.contentsScale = CGFloat(image.width) / max(1, bounds.width) }
        badge.stringValue = "  收起时的画面  "
        badge.isHidden = !(stale && image != nil)
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil
    }

    /// Live frames include the title bar: shift them up so the content lines up.
    func liveStarted(barHeight: CGFloat, full: CGSize) {
        liveLayer.contentsGravity = .resize
        liveLayer.frame = CGRect(x: 0, y: bounds.height - full.height + barHeight, width: full.width, height: full.height)
        liveLayer.autoresizingMask = []
        imageLayer.contents = nil
        badge.isHidden = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func mouseUp(with event: NSEvent) { onClick() }
}
