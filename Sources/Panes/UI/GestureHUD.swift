// The little "what happens when you let go" bubble for title-bar gestures.
// Look adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// docs/gestures.md "提示浮窗" / prototype/Overlay/GestureHUD.swift — the system volume
// HUD's glass capsule with a title and a progress bar that follows the fingers 1:1,
// turns accent-coloured when the action is armed, hangs 10pt under the title bar
// centred on the pointer, never takes clicks or focus.

import AppKit
import SwiftUI

final class GestureHUD {
    static let shared = GestureHUD()

    private let model = HUDModel()
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 290, height: 63),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.contentView = NSHostingView(rootView: HUDView(model: model))
        return p
    }()
    private var hideWork: DispatchWorkItem?

    /// Shows or updates the bubble. `anchor` is the AX point it hangs under.
    func update(title: String, symbol: String, progress: CGFloat, reversed: Bool, anchor: CGPoint) {
        hideWork?.cancel()
        model.messageOnly = false
        model.title = title
        model.symbol = symbol
        model.progress = max(0, min(1, progress))
        model.reversed = reversed
        let size = panel.frame.size
        var r = Geometry.cocoaRect(fromAX: CGRect(x: anchor.x - size.width / 2, y: anchor.y + 10, width: size.width, height: size.height))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(r.center) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            r.origin.x = min(max(r.minX, vf.minX + 4), vf.maxX - size.width - 4)
            r.origin.y = min(max(r.minY, vf.minY + 4), vf.maxY - size.height - 4)
        }
        panel.setFrameOrigin(r.origin)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    /// A one-line note (no progress bar), e.g. "this window can't be rolled up".
    func flash(_ title: String, symbol: String = "exclamationmark.circle", anchor: CGPoint) {
        update(title: title, symbol: symbol, progress: 0, reversed: false, anchor: anchor)
        model.messageOnly = true
        fadeOut(after: 1.2, duration: 0.25)
    }

    /// After the action ran: linger 0.45s, then fade.
    func finish() { fadeOut(after: 0.45, duration: 0.2) }

    /// Gesture abandoned: fade quickly.
    func cancel() { fadeOut(after: 0, duration: 0.15) }

    private func fadeOut(after delay: TimeInterval, duration: TimeInterval) {
        guard panel.isVisible else { return }
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let p = self.panel
            NSAnimationContext.runAnimationGroup({ $0.duration = duration; p.animator().alphaValue = 0 },
                                                 completionHandler: { if p.alphaValue == 0 { p.orderOut(nil) } })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

final class HUDModel: ObservableObject {
    @Published var title = ""
    @Published var symbol = "macwindow"
    @Published var progress: CGFloat = 0
    @Published var reversed = false
    @Published var messageOnly = false
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        let armed = model.progress >= 1
        VStack(spacing: 8) {
            if model.messageOnly {
                Label(model.title, systemImage: model.symbol)
                    .font(.system(size: 13, weight: .semibold))
            } else {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Image(systemName: model.reversed ? model.symbol : "macwindow")
                    .font(.system(size: 12))
                GeometryReader { g in
                    ZStack(alignment: model.reversed ? .trailing : .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(armed ? Color.accentColor : Color.primary.opacity(0.6))
                            .frame(width: g.size.width * model.progress)
                    }
                }
                .frame(height: 6)
                Image(systemName: model.reversed ? "macwindow" : model.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(armed ? Color.accentColor : Color.primary)
                    .scaleEffect(armed ? 1.15 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: armed)
            }
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 290, height: 63)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }
}
