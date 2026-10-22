import AppKit

/// Translucent rectangle that shows where a window will land.
final class PreviewOverlay {
    static let shared = PreviewOverlay()

    private let panel: NSPanel
    private let box = NSVisualEffectView()
    private let tint = NSView()
    private(set) var isVisible = false
    private var currentAX: CGRect?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating + 1
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none

        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 2
        box.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        box.autoresizingMask = [.width, .height]

        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        tint.autoresizingMask = [.width, .height]
        box.addSubview(tint)
        panel.contentView = box
    }

    func show(axFrame: CGRect) {
        if let c = currentAX, c == axFrame, isVisible { return }
        currentAX = axFrame
        let target = Geometry.cocoaRect(fromAX: axFrame).insetBy(dx: 2, dy: 2)
        if isVisible && Settings.shared.data.previewAnimates {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        } else {
            // Grow out of the cursor for the first appearance.
            let m = NSEvent.mouseLocation
            panel.setFrame(CGRect(x: m.x - 20, y: m.y - 20, width: 40, height: 40), display: false)
            tint.frame = box.bounds
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Settings.shared.data.previewAnimates ? 0.15 : 0
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        }
        isVisible = true
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        currentAX = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.isVisible == false { self?.panel.orderOut(nil) }
        })
    }
}
