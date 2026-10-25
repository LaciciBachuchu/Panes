import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        // Debug: `Panes --render-ui <dir>` writes PNGs of the settings tabs and palette.
        if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), i + 1 < CommandLine.arguments.count {
            UIRenderer.renderAll(to: CommandLine.arguments[i + 1])
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var trustTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ note: Notification) {
        updateStatusItem()
        if AXIsProcessTrusted() {
            startServices()
        } else {
            showOnboarding()
            // Poll until the user flips the switch in System Settings.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard AXIsProcessTrusted() else { return }
                t.invalidate()
                self?.onboardingWindow?.close()
                self?.startServices()
            }
        }

        // Re-register hotkeys / menu whenever settings change.
        Settings.shared.$data
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                HotKeyManager.shared.reload()
                if AXIsProcessTrusted() {
                    TitlebarGestures.shared.applySettings()
                    CarryController.shared.applySettings()
                    SlideOverController.shared.applySettings()
                    SplitDividers.shared.applySettings()
                    ScrollStrip.shared.applySettings()
                }
                self?.updateStatusItem()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ note: Notification) {
        Self.restoreParkedWindows()
    }

    /// Nothing Panes parked past the screen edge may stay there after it quits.
    static func restoreParkedWindows() {
        ScrollStrip.shared.exit()
        SlideOverController.shared.restoreForQuit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    private func startServices() {
        // Don't let one hung app stall every mouse click for seconds.
        AXUIElementSetMessagingTimeout(AXWindow.systemWide, 0.3)
        // Windows a previous run parked off screen come back first.
        ParkedJournal.recover()
        ParkedJournal.installTerminationHandlers { Self.restoreParkedWindows() }
        HotKeyManager.shared.reload()
        SnapController.shared.start()
        HoverMoveResize.shared.start()
        PaletteController.shared.start()
        LayoutManager.shared.start()
        TitlebarGestures.shared.applySettings()
        CarryController.shared.applySettings()
        SplitDividers.shared.applySettings()
        ScrollStrip.shared.applySettings()
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        guard Settings.shared.data.showMenuBarIcon else {
            if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Panes")
            let menu = NSMenu()
            menu.delegate = self
            statusItem?.menu = menu
        }
    }

    // Built lazily so it always reflects current settings and the frontmost window.
    /// Debug aid: the status menu as indented text.
    func dumpMenu() -> String {
        let m = NSMenu()
        menuNeedsUpdate(m)
        func walk(_ m: NSMenu, _ depth: Int) -> [String] {
            m.items.flatMap { i -> [String] in
                let line = String(repeating: "  ", count: depth) + (i.isSeparatorItem ? "----" : i.title)
                return [line] + (i.submenu.map { walk($0, depth + 1) } ?? [])
            }
        }
        return walk(m, 0).joined(separator: "\n")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "授予辅助功能权限…", action: #selector(showOnboarding), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        let s = Settings.shared.data
        // Every placement lives in one grouped submenu; the top level stays short.
        let arrange = NSMenuItem(title: "摆放当前窗口", action: nil, keyEquivalent: "")
        arrange.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: nil)
        let arrangeMenu = NSMenu()
        let groups = Dictionary(grouping: s.actions.filter(\.inMenu), by: MenuGroup.of)
        for g in MenuGroup.allCases {
            guard let items = groups[g], !items.isEmpty else { continue }
            if arrangeMenu.numberOfItems > 0 { arrangeMenu.addItem(.separator()) }
            arrangeMenu.addItem(NSMenuItem.sectionHeader(title: g.title))
            for a in items { arrangeMenu.addItem(actionItem(a)) }
        }
        arrange.submenu = arrangeMenu
        menu.addItem(arrange)

        // One click in and out of the scroll strip, no shortcut needed.
        let strip = NSMenuItem(title: "卷轴", action: #selector(toggleStrip), keyEquivalent: "")
        strip.target = self
        strip.state = ScrollStrip.shared.isActive ? .on : .off
        strip.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: nil)
        strip.toolTip = "把当前屏幕的窗口排成一条横着的卷轴；再点一次复原"
        menu.addItem(strip)

        let carried = CarryController.shared.menuEntries
        if !carried.isEmpty {
            let item = NSMenuItem(title: "带到每张桌面的窗口（\(carried.count)）", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for e in carried {
                let i = NSMenuItem(title: e.label, action: #selector(openCarried(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = NSNumber(value: e.id)
                sub.addItem(i)
            }
            sub.addItem(.separator())
            sub.addItem(withTitle: "全部不再带着", action: #selector(stopAllCarried), keyEquivalent: "").target = self
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let layouts = NSMenuItem(title: "布局", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for l in s.layouts {
            let item = NSMenuItem(title: l.name, action: #selector(restoreLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = l
            if let sc = l.shortcut { applyShortcut(sc, to: item) }
            sub.addItem(item)
        }
        if !s.layouts.isEmpty { sub.addItem(.separator()) }
        sub.addItem(withTitle: "保存当前布局…", action: #selector(saveLayout), keyEquivalent: "").target = self
        layouts.submenu = sub
        menu.addItem(layouts)

        if let app = NSWorkspace.shared.frontmostApplication, let bid = app.bundleIdentifier, bid != Bundle.main.bundleIdentifier {
            let excluded = Settings.shared.isExcluded(bid)
            let item = NSMenuItem(title: excluded ? "恢复处理“\(app.localizedName ?? bid)”" : "忽略“\(app.localizedName ?? bid)”",
                                  action: #selector(toggleExclude(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bid
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let snap = NSMenuItem(title: "拖拽吸附", action: #selector(toggleSnap), keyEquivalent: "")
        snap.target = self
        snap.state = s.snapEnabled ? .on : .off
        menu.addItem(snap)
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "退出 Panes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func actionItem(_ a: WindowAction) -> NSMenuItem {
        let item = NSMenuItem(title: a.name, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = a
        item.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil)
        if let sc = a.shortcut { applyShortcut(sc, to: item) }
        return item
    }

    private func applyShortcut(_ sc: Shortcut, to item: NSMenuItem) {
        // Display only; the real hotkey is global via Carbon.
        let name = KeyNames.name(for: sc.keyCode)
        var key = name.count == 1 ? name.lowercased() : ""
        switch name {
        case "←": key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "→": key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "↑": key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "↓": key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "↩": key = "\r"
        case "⌫": key = String(UnicodeScalar(NSBackspaceCharacter)!)
        case "Space": key = " "
        default: break
        }
        guard !key.isEmpty else { return }
        item.keyEquivalent = key
        var m: NSEvent.ModifierFlags = []
        if sc.modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if sc.modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if sc.modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if sc.modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        item.keyEquivalentModifierMask = m
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? WindowAction else { return }
        // The menu closes first; give focus back to the previous window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { WindowManager.shared.perform(a) }
    }

    @objc private func restoreLayout(_ sender: NSMenuItem) {
        guard let l = sender.representedObject as? Layout else { return }
        LayoutManager.shared.restore(l)
    }

    @objc func saveLayout() {
        let alert = NSAlert()
        alert.messageText = "Save Current Layout"
        alert.informativeText = "Saves the position of every visible window on \(LayoutManager.displayDescription)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "Layout \(Settings.shared.data.layouts.count + 1)"
        alert.accessoryView = field
        let auto = NSButton(checkboxWithTitle: "Apply automatically when these displays are connected", target: nil, action: nil)
        let stack = NSStackView(views: [field, auto])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 52)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var layout = LayoutManager.shared.capture(name: field.stringValue.isEmpty ? "Layout" : field.stringValue)
        layout.autoApply = auto.state == .on
        Settings.shared.data.layouts.append(layout)
    }

    @objc private func toggleExclude(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        if let i = Settings.shared.data.excludedBundleIDs.firstIndex(of: bid) {
            Settings.shared.data.excludedBundleIDs.remove(at: i)
        } else {
            Settings.shared.data.excludedBundleIDs.append(bid)
        }
    }

    @objc private func openCarried(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        CarryController.shared.open(CGWindowID(n.uint32Value))
    }

    @objc private func stopAllCarried() { CarryController.shared.stopAll() }

    @objc private func toggleStrip() {
        // The menu item works even if the feature is switched off in settings.
        if !Settings.shared.data.scrollStripEnabled { Settings.shared.data.scrollStripEnabled = true }
        // Let the menu close and focus return to the previous app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { ScrollStrip.shared.toggle() }
    }

    @objc private func toggleSnap() { Settings.shared.data.snapEnabled.toggle() }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Panes Settings"
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(Settings.shared))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Drop closed windows (and their SwiftUI trees) instead of keeping them around.
    func windowWillClose(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        if w === settingsWindow {
            // Defer so the window finishes closing before its last reference goes.
            DispatchQueue.main.async { [weak self] in self?.settingsWindow = nil }
        } else if w === onboardingWindow {
            DispatchQueue.main.async { [weak self] in self?.onboardingWindow = nil }
        }
    }

    @objc func showOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Welcome to Panes"
            w.delegate = self
            w.contentView = NSHostingView(rootView: OnboardingView())
            w.isReleasedWhenClosed = false
            w.center()
            onboardingWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.2x2").font(.system(size: 44)).foregroundStyle(Color.accentColor)
            Text("Panes needs Accessibility access").font(.title2.bold())
            Text("macOS only lets apps move and resize other apps' windows with this permission. Turn on Panes in System Settings → Privacy & Security → Accessibility. Panes starts working as soon as it's on.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(opts)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 460)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Panes: login item change failed: \(error)")
        }
    }
}

/// Sections of the "摆放当前窗口" submenu.
private enum MenuGroup: CaseIterable {
    case halves, corners, thirds, other

    var title: String {
        switch self {
        case .halves: return "半屏"
        case .corners: return "四角"
        case .thirds: return "三分之一"
        case .other: return "其他"
        }
    }

    static func of(_ a: WindowAction) -> MenuGroup {
        guard a.kind == .unitRect, let r = a.rects.first else { return .other }
        func near(_ v: Double, _ t: Double) -> Bool { abs(v - t) < 0.02 }
        if (near(r.w, 0.5) && near(r.h, 1)) || (near(r.w, 1) && near(r.h, 0.5)) { return .halves }
        if near(r.w, 0.5) && near(r.h, 0.5) { return .corners }
        if near(r.w, 1.0 / 3) || near(r.w, 2.0 / 3) { return .thirds }
        return .other
    }
}
