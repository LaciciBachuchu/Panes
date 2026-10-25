import AppKit
import SwiftUI

/// Renders UI into PNG files without showing anything on screen (debug aid).
enum UIRenderer {
    static func renderAll(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = Settings.shared
        let tabs: [(String, AnyView)] = [
            ("general", AnyView(GeneralTab())),
            ("shortcuts", AnyView(ActionsTab())),
            ("snapping", AnyView(SnapTab())),
            ("mouse", AnyView(MouseTab())),
            ("layouts", AnyView(LayoutsTab())),
            ("features", AnyView(FeaturesTab())),
        ]
        for (name, view) in tabs {
            write(AnyView(view.environmentObject(s).padding(16)), size: CGSize(width: 760, height: 620), to: "\(dir)/\(name).png")
        }
        let model = PaletteModel()
        model.actions = s.data.actions.filter(\.inPalette)
        model.cols = s.data.gridColumns; model.rows = s.data.gridRows
        model.selection = (1, 1, 3, 4)
        model.keyboardHint = true
        write(AnyView(PaletteView(model: model)), size: nil, to: "\(dir)/palette.png")
        write(AnyView(OnboardingView()), size: nil, to: "\(dir)/onboarding.png")
    }

    private static func write(_ view: AnyView, size: CGSize?, to path: String) {
        let host = NSHostingView(rootView: view)
        let sz = size ?? host.fittingSize
        let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: sz),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        win.backgroundColor = .windowBackgroundColor
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        win.orderOut(nil)
    }
}
