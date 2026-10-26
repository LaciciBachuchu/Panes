import AppKit

/// Saves and restores arrangements of windows, and re-applies a layout
/// automatically when the display setup changes (dock / undock).
final class LayoutManager {
    static let shared = LayoutManager()

    private var lastSignature = ""
    private var pending: DispatchWorkItem?

    func start() {
        lastSignature = Self.displaySignature
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.displaysChanged() }
    }

    /// Identifies the current monitor arrangement (ids + resolutions).
    static var displaySignature: String {
        NSScreen.screens.map { "\($0.displayID):\(Int($0.frame.width))x\(Int($0.frame.height))" }
            .sorted().joined(separator: ",")
    }

    static var displayDescription: String {
        let n = NSScreen.screens.count
        let names = NSScreen.screens.map(\.localizedName).joined(separator: " + ")
        return n == 1 ? names : "\(n) 台显示器：\(names)"
    }

    private func displaysChanged() {
        let sig = Self.displaySignature
        guard sig != lastSignature else { return }
        lastSignature = sig
        guard let layout = Settings.shared.data.layouts.first(where: { $0.autoApply && $0.displaySignature == sig }) else { return }
        // Windows are still being shuffled by macOS right after a display change.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restore(layout) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: Capture

    func capture(name: String) -> Layout {
        let screens = NSScreen.ordered
        var saved: [SavedWindow] = []
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != me && !app.isHidden {
            guard let bid = app.bundleIdentifier, !Settings.shared.isExcluded(bid) else { continue }
            for w in AXWindow.windows(of: app.processIdentifier) where w.isStandard && !w.isMinimized && !w.isFullScreen {
                guard let f = w.frame, let s = NSScreen.screen(forAX: f) else { continue }
                saved.append(SavedWindow(bundleID: bid, appName: app.localizedName ?? bid, title: w.title,
                                         frame: UnitRect(f), unit: UnitRect(f.unit(in: s.axVisibleFrame)),
                                         displayIndex: screens.firstIndex(of: s) ?? 0))
            }
        }
        return Layout(name: name, windows: saved, displaySignature: Self.displaySignature)
    }

    // MARK: Restore

    func restore(_ layout: Layout) {
        let sameDisplays = layout.displaySignature == Self.displaySignature
        let screens = NSScreen.ordered
        let skipMin = Settings.shared.data.skipMinimizedOnRestore

        let byApp = Dictionary(grouping: layout.windows, by: \.bundleID)
        for (bid, entries) in byApp {
            guard !Settings.shared.isExcluded(bid),
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { continue }
            var live = AXWindow.windows(of: app.processIdentifier).filter { $0.isStandard && !$0.isFullScreen }
            if skipMin { live.removeAll(where: \.isMinimized) }

            // Exact title matches first, then the rest in order.
            var unmatched: [SavedWindow] = []
            for e in entries {
                if let i = live.firstIndex(where: { !e.title.isEmpty && $0.title == e.title }) {
                    apply(e, to: live.remove(at: i), same: sameDisplays, screens: screens)
                } else {
                    unmatched.append(e)
                }
            }
            for (e, w) in zip(unmatched, live) { apply(e, to: w, same: sameDisplays, screens: screens) }
        }
    }

    private func apply(_ e: SavedWindow, to w: AXWindow, same: Bool, screens: [NSScreen]) {
        if same {
            w.setFrame(e.frame.cgRect)
        } else {
            // Different monitors: map relative position onto the nearest equivalent display.
            let s = screens[min(e.displayIndex, screens.count - 1)]
            w.setFrame(s.axVisibleFrame.subrect(unit: e.unit.cgRect))
        }
    }
}
