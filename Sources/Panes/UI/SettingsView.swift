import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            ActionsTab().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            SnapTab().tabItem { Label("Snapping", systemImage: "rectangle.split.2x2") }
            MouseTab().tabItem { Label("Palette & Mouse", systemImage: "cursorarrow.motionlines") }
            LayoutsTab().tabItem { Label("Layouts", systemImage: "square.on.square") }
            FeaturesTab().tabItem { Label("窗口功能", systemImage: "sparkles.rectangle.stack") }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var settings: Settings
    @State private var loginItem = LoginItem.isEnabled
    @State private var trusted = AXIsProcessTrusted()
    @State private var newExclusion = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "Accessibility access granted" : "Accessibility access needed")
                    Spacer()
                    if !trusted {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                Toggle("Launch at login", isOn: $loginItem)
                    .onChange(of: loginItem) { _, v in LoginItem.set(v) }
                Toggle("Show menu bar icon", isOn: $settings.data.showMenuBarIcon)
                if !settings.data.showMenuBarIcon {
                    Text("Open Panes again from Finder or Spotlight to get back to Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Window placement") {
                LabeledContent("Gap between windows") {
                    HStack {
                        Slider(value: $settings.data.gap, in: 0...40)
                        Text("\(Int(settings.data.gap)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Almost maximize size") {
                    HStack {
                        Slider(value: $settings.data.almostMaximizeInset, in: 0.5...0.98)
                        Text("\(Int(settings.data.almostMaximizeInset * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section {
                ForEach(settings.data.excludedBundleIDs, id: \.self) { bid in
                    HStack {
                        AppLabel(bundleID: bid)
                        Spacer()
                        Button(role: .destructive) {
                            settings.data.excludedBundleIDs.removeAll { $0 == bid }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                }
                HStack {
                    Menu("Add Running App") {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                                if let b = app.bundleIdentifier, !settings.data.excludedBundleIDs.contains(b) {
                                    settings.data.excludedBundleIDs.append(b)
                                }
                            }
                        }
                    }
                    .fixedSize()
                    Button("Choose App…") { chooseApp() }
                }
            } header: {
                Text("Ignored apps")
            } footer: {
                Text("Panes won't snap, move or resize these apps' windows, and its shortcuts pass straight through while they're frontmost — handy for remote desktop, VMs and games.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Backup") {
                HStack {
                    Button("Export Settings…", action: exportSettings)
                    Button("Import Settings…", action: importSettings)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { trusted = AXIsProcessTrusted(); loginItem = LoginItem.isEnabled }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func chooseApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let url = p.url, let b = Bundle(url: url)?.bundleIdentifier else { return }
        if !settings.data.excludedBundleIDs.contains(b) { settings.data.excludedBundleIDs.append(b) }
    }

    private func exportSettings() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]
        p.nameFieldStringValue = "Panes Settings.json"
        guard p.runModal() == .OK, let url = p.url, let data = settings.exportJSON() else { return }
        try? data.write(to: url)
    }

    private func importSettings() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return }
        if !settings.importJSON(data) {
            let a = NSAlert(); a.messageText = "That file isn't a Panes settings export."; a.runModal()
        }
    }
}

struct AppLabel: View {
    let bundleID: String
    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 6) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            }
            Text(url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID)
            Text(bundleID).font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Shortcuts / actions

struct ActionsTab: View {
    @EnvironmentObject var settings: Settings
    @State private var editing: WindowAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Every action works straight from its shortcut — no mode to enter first. Unit actions with several sizes cycle when you press the shortcut again (e.g. ½ → ⅔ → ⅓).")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach($settings.data.actions) { $a in
                    HStack(spacing: 10) {
                        UnitThumb(rect: a.kind == .unitRect ? a.rects.first : (a.kind == .maximize ? .full : nil), symbol: a.symbol)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name)
                            Text(detail(a)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Palette", isOn: $a.inPalette).toggleStyle(.checkbox).help("Show in the green-button palette")
                        Toggle("Menu", isOn: $a.inMenu).toggleStyle(.checkbox).help("Show in the menu bar menu")
                        ShortcutRecorder(shortcut: $a.shortcut)
                        Button { editing = a } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Edit…") { editing = a }
                        Button("Duplicate") {
                            var c = a; c.id = UUID(); c.name += " Copy"; c.shortcut = nil
                            settings.data.actions.append(c)
                        }
                        Button("Delete", role: .destructive) { settings.data.actions.removeAll { $0.id == a.id } }
                    }
                }
                .onMove { settings.data.actions.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { settings.data.actions.remove(atOffsets: $0) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Button("Add Action") {
                    let a = WindowAction(name: "New Action", kind: .unitRect, rects: [UnitRect(0.25, 0, 0.5, 1)], inPalette: true)
                    settings.data.actions.append(a)
                    editing = a
                }
                Spacer()
                if let dup = duplicateShortcut {
                    Label("\(dup) is used twice", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
                Button("Restore Defaults") { settings.resetActions() }
            }
        }
        .sheet(item: $editing) { a in
            ActionEditor(action: a) { updated in
                if let i = settings.data.actions.firstIndex(where: { $0.id == updated.id }) { settings.data.actions[i] = updated }
            }
        }
    }

    private func detail(_ a: WindowAction) -> String {
        var s = a.kind.label
        if a.kind == .unitRect {
            s = a.rects.map { "\(pct($0.w))×\(pct($0.h))" }.joined(separator: " → ")
            if a.display != .current { s += " · \(a.display.label)" }
        }
        return s
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private var duplicateShortcut: String? {
        var seen = Set<Shortcut>()
        for a in settings.data.actions { if let s = a.shortcut { if !seen.insert(s).inserted { return s.displayString } } }
        return nil
    }
}

struct ActionEditor: View {
    @State var action: WindowAction
    var onSave: (WindowAction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Action").font(.title3.bold())
            Form {
                TextField("Name", text: $action.name)
                Picker("Does", selection: $action.kind) {
                    ForEach(ActionKind.allCases) { Text($0.label).tag($0) }
                }
                if action.kind == .unitRect {
                    Picker("On", selection: $action.display) {
                        ForEach(DisplayTarget.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: action.kind == .unitRect ? 150 : 110)

            if action.kind == .unitRect {
                Text("Positions — pressing the shortcut again moves to the next one").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(action.rects.indices, id: \.self) { i in
                            HStack(alignment: .top) {
                                Text("\(i + 1)").font(.headline).frame(width: 18)
                                UnitRectEditor(rect: $action.rects[i])
                                Spacer()
                                Button(role: .destructive) { action.rects.remove(at: i) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .disabled(action.rects.count == 1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                Button("Add Cycle Step") { action.rects.append(action.rects.last ?? .leftHalf) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if action.kind == .unitRect && action.rects.isEmpty { action.rects = [.leftHalf] }
                    onSave(action); dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - Snapping

struct SnapTab: View {
    @EnvironmentObject var settings: Settings
    @State private var editing: SnapArea?

    var body: some View {
        Form {
            Section {
                Toggle("Snap windows when dragged to screen edges and corners", isOn: $settings.data.snapEnabled)
                if settings.data.snapEnabled && SystemTiling.isOn {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("macOS's own edge tiling is on and will fight with Panes. Turn off “Drag windows to screen edges to tile” and “Drag windows to menu bar to fill screen” in Desktop & Dock → Windows.")
                            .font(.callout)
                        Spacer()
                        Button("Open") { SystemTiling.openSettings() }
                    }
                }
                Toggle("Restore original size when dragging a snapped window away", isOn: $settings.data.restoreSizeOnDragAway)
                Toggle("Animate preview", isOn: $settings.data.previewAnimates)
                Picker("Hold to drag without snapping", selection: $settings.data.disableSnapModifier) {
                    ForEach([ModifierSet.none, .command, .option, .shift, .control]) { Text($0.label).tag($0) }
                }
                LabeledContent("Edge sensitivity") {
                    HStack { Slider(value: $settings.data.snapThreshold, in: 1...30); Text("\(Int(settings.data.snapThreshold)) px").monospacedDigit().frame(width: 44) }
                }
                LabeledContent("Corner size") {
                    HStack { Slider(value: $settings.data.cornerSize, in: 10...200); Text("\(Int(settings.data.cornerSize)) px").monospacedDigit().frame(width: 44) }
                }
            }
            Section {
                ForEach($settings.data.snapAreas) { $a in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $a.enabled).labelsHidden()
                        EdgeThumb(area: a)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        UnitThumb(rect: a.target)
                        Text(a.summary)
                        Spacer()
                        Button { editing = a } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        Button(role: .destructive) { settings.data.snapAreas.removeAll { $0.id == a.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Snap Area") {
                        let a = SnapArea(edge: .top, from: 0.4, to: 0.6, target: UnitRect(0.25, 0, 0.5, 1))
                        settings.data.snapAreas.append(a)
                        editing = a
                    }
                    Spacer()
                    Button("Restore Defaults") { settings.resetSnapAreas() }
                }
            } header: {
                Text("Snap areas")
            } footer: {
                Text("Split an edge into segments to get more targets — e.g. the default bottom edge snaps to thirds. Corners always win over edges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { a in
            SnapAreaEditor(area: a) { u in
                if let i = settings.data.snapAreas.firstIndex(where: { $0.id == u.id }) { settings.data.snapAreas[i] = u }
            }
        }
    }
}

/// Picture of a screen with the trigger edge/segment highlighted.
struct EdgeThumb: View {
    let area: SnapArea
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, t: CGFloat = 3
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.4))
                let r: CGRect = {
                    switch area.edge {
                    case .left: return CGRect(x: 0, y: h * area.from, width: t, height: h * (area.to - area.from))
                    case .right: return CGRect(x: w - t, y: h * area.from, width: t, height: h * (area.to - area.from))
                    case .top: return CGRect(x: w * area.from, y: 0, width: w * (area.to - area.from), height: t)
                    case .bottom: return CGRect(x: w * area.from, y: h - t, width: w * (area.to - area.from), height: t)
                    case .topLeft: return CGRect(x: 0, y: 0, width: 7, height: 7)
                    case .topRight: return CGRect(x: w - 7, y: 0, width: 7, height: 7)
                    case .bottomLeft: return CGRect(x: 0, y: h - 7, width: 7, height: 7)
                    case .bottomRight: return CGRect(x: w - 7, y: h - 7, width: 7, height: 7)
                    }
                }()
                Rectangle().fill(Color.orange).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            }
        }
        .frame(width: 30, height: 20)
    }
}

struct SnapAreaEditor: View {
    @State var area: SnapArea
    var onSave: (SnapArea) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Snap Area").font(.title3.bold())
            Form {
                Picker("Trigger", selection: $area.edge) {
                    ForEach(SnapEdge.allCases) { Text($0.label).tag($0) }
                }
                if !area.edge.isCorner {
                    LabeledContent("Segment start") {
                        HStack { Slider(value: $area.from, in: 0...1); Text("\(Int(area.from * 100))%").monospacedDigit().frame(width: 40) }
                    }
                    LabeledContent("Segment end") {
                        HStack { Slider(value: $area.to, in: 0...1); Text("\(Int(area.to * 100))%").monospacedDigit().frame(width: 40) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: area.edge.isCorner ? 80 : 150)
            Text("Window goes to").font(.callout).foregroundStyle(.secondary)
            UnitRectEditor(rect: $area.target)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var a = area
                    if a.from > a.to { (a.from, a.to) = (a.to, a.from) }
                    onSave(a); dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Palette & mouse

struct MouseTab: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Section {
                Toggle("Add a Panes tab beside the green-button menu", isOn: $settings.data.paletteOnHover)
                LabeledContent("Hover delay") {
                    HStack { Slider(value: $settings.data.paletteHoverDelay, in: 0.1...1.5); Text(String(format: "%.2fs", settings.data.paletteHoverDelay)).monospacedDigit().frame(width: 48) }
                }
                Stepper("Grid columns: \(settings.data.gridColumns)", value: $settings.data.gridColumns, in: 2...24)
                Stepper("Grid rows: \(settings.data.gridRows)", value: $settings.data.gridRows, in: 2...24)
            } header: {
                Text("Palette")
            } footer: {
                Text("Hovering a green button keeps macOS's own menu and adds a small grid tab next to it — point at the tab to open the palette. Clicking the green button still works as usual. Choose which presets appear in the Shortcuts tab; the “Show Palette” shortcut (⌃⌥P) opens it directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Move window under cursor", selection: $settings.data.moveModifier) {
                    ForEach(ModifierSet.allCases) { Text($0.label).tag($0) }
                }
                Picker("Resize window under cursor", selection: $settings.data.resizeModifier) {
                    ForEach(ModifierSet.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Bring window to front when moving it", isOn: $settings.data.raiseOnHoverMove)
            } header: {
                Text("Hover move & resize")
            } footer: {
                Text("Hold the keys and move the mouse — no clicking. Resize grabs the corner nearest the cursor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Layouts

struct LayoutsTab: View {
    @EnvironmentObject var settings: Settings
    @State private var expanded: UUID?

    var body: some View {
        Form {
            Section {
                if settings.data.layouts.isEmpty {
                    Text("No layouts yet. Arrange your windows, then save them here or from the menu bar.")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.data.layouts) { $l in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("", text: $l.name).textFieldStyle(.plain).font(.headline)
                            if l.displaySignature == LayoutManager.displaySignature {
                                Text("these displays").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.green.opacity(0.2), in: Capsule())
                            }
                            Spacer()
                            ShortcutRecorder(shortcut: $l.shortcut)
                            Button("Restore") { LayoutManager.shared.restore(l) }
                            Menu {
                                Button("Update to Current Windows") {
                                    let fresh = LayoutManager.shared.capture(name: l.name)
                                    l.windows = fresh.windows
                                    l.displaySignature = fresh.displaySignature
                                }
                                Button(expanded == l.id ? "Hide Windows" : "Show Windows") { expanded = expanded == l.id ? nil : l.id }
                                Divider()
                                Button("Delete", role: .destructive) { settings.data.layouts.removeAll { $0.id == l.id } }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                        Toggle("Apply automatically when this display setup is connected", isOn: $l.autoApply)
                            .font(.callout)
                        Text("\(l.windows.count) windows · \(Set(l.windows.map(\.bundleID)).count) apps")
                            .font(.caption).foregroundStyle(.secondary)
                        if expanded == l.id {
                            ForEach(Array(l.windows.enumerated()), id: \.offset) { _, w in
                                HStack {
                                    UnitThumb(rect: w.unit)
                                    Text(w.appName)
                                    Text(w.title).foregroundStyle(.secondary).lineLimit(1)
                                }.font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("Saved layouts")
                    Spacer()
                    Button("Save Current Layout…") { (NSApp.delegate as? AppDelegate)?.saveLayout() }
                }
            } footer: {
                Text("Layouts match windows by app and title. Minimized windows are left alone, and ignored apps are skipped. On a different monitor setup, windows keep their relative positions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Leave minimized windows minimized when restoring", isOn: $settings.data.skipMinimizedOnRestore)
            }
        }
        .formStyle(.grouped)
    }
}

/// macOS 15+ has built-in drag-to-edge tiling that competes with Panes' snapping.
enum SystemTiling {
    static var isOn: Bool {
        let d = UserDefaults(suiteName: "com.apple.WindowManager")
        let edge = d?.object(forKey: "EnableTilingByEdgeDrag") as? Bool ?? true
        let top = d?.object(forKey: "EnableTopTilingByEdgeDrag") as? Bool ?? true
        return edge || top
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
    }
}
