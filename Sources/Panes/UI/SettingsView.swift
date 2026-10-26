import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("通用", systemImage: "gearshape") }
            ActionsTab().tabItem { Label("快捷键", systemImage: "keyboard") }
            SnapTab().tabItem { Label("吸附", systemImage: "rectangle.split.2x2") }
            MouseTab().tabItem { Label("面板与鼠标", systemImage: "cursorarrow.motionlines") }
            LayoutsTab().tabItem { Label("布局", systemImage: "square.on.square") }
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
                    Text(trusted ? "已获得辅助功能权限" : "需要辅助功能权限")
                    Spacer()
                    if !trusted {
                        Button("打开系统设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                Toggle("登录时启动", isOn: $loginItem)
                    .onChange(of: loginItem) { _, v in LoginItem.set(v) }
                Toggle("在菜单栏显示图标", isOn: $settings.data.showMenuBarIcon)
                if !settings.data.showMenuBarIcon {
                    Text("之后要回到设置，从访达或聚焦搜索再打开一次 Panes 就行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("窗口摆放") {
                LabeledContent("窗口间距") {
                    HStack {
                        Slider(value: $settings.data.gap, in: 0...40)
                        Text("\(Int(settings.data.gap)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("几乎最大化的大小") {
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
                    Menu("添加正在运行的 App") {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                                if let b = app.bundleIdentifier, !settings.data.excludedBundleIDs.contains(b) {
                                    settings.data.excludedBundleIDs.append(b)
                                }
                            }
                        }
                    }
                    .fixedSize()
                    Button("选择 App…") { chooseApp() }
                }
            } header: {
                Text("忽略的 App")
            } footer: {
                Text("Panes 不会吸附、移动或调整这些 App 的窗口；它们在最前面时，Panes 的快捷键也直接交给它们——适合远程桌面、虚拟机和游戏。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("备份") {
                HStack {
                    Button("导出设置…", action: exportSettings)
                    Button("导入设置…", action: importSettings)
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
        p.nameFieldStringValue = "Panes 设置.json"
        guard p.runModal() == .OK, let url = p.url, let data = settings.exportJSON() else { return }
        try? data.write(to: url)
    }

    private func importSettings() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return }
        if !settings.importJSON(data) {
            let a = NSAlert(); a.messageText = "这个文件不是 Panes 导出的设置。"; a.runModal()
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
            Text("每个动作按快捷键就直接生效，不用先进入什么模式。有几种尺寸的动作，再按一次快捷键会切到下一种（比如 ½ → ⅔ → ⅓）。")
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
                        Toggle("面板", isOn: $a.inPalette).toggleStyle(.checkbox).help("显示在绿色按钮旁的面板里")
                        Toggle("菜单", isOn: $a.inMenu).toggleStyle(.checkbox).help("显示在菜单栏菜单里")
                        ShortcutRecorder(shortcut: $a.shortcut)
                        Button { editing = a } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("编辑…") { editing = a }
                        Button("复制一份") {
                            var c = a; c.id = UUID(); c.name += " 副本"; c.shortcut = nil
                            settings.data.actions.append(c)
                        }
                        Button("删除", role: .destructive) { settings.data.actions.removeAll { $0.id == a.id } }
                    }
                }
                .onMove { settings.data.actions.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { settings.data.actions.remove(atOffsets: $0) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Button("添加动作") {
                    let a = WindowAction(name: "新动作", kind: .unitRect, rects: [UnitRect(0.25, 0, 0.5, 1)], inPalette: true)
                    settings.data.actions.append(a)
                    editing = a
                }
                Spacer()
                if let dup = duplicateShortcut {
                    Label("\(dup) 被用了两次", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
                Button("恢复默认") { settings.resetActions() }
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
            Text("编辑动作").font(.title3.bold())
            Form {
                TextField("名称", text: $action.name)
                Picker("做什么", selection: $action.kind) {
                    ForEach(ActionKind.allCases) { Text($0.label).tag($0) }
                }
                if action.kind == .unitRect {
                    Picker("在哪个显示器", selection: $action.display) {
                        ForEach(DisplayTarget.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: action.kind == .unitRect ? 150 : 110)

            if action.kind == .unitRect {
                Text("位置——再按一次快捷键就换到下一个").font(.callout).foregroundStyle(.secondary)
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
                Button("添加一个循环位置") { action.rects.append(action.rects.last ?? .leftHalf) }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
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
                Toggle("拖到屏幕边缘和角落时吸附窗口", isOn: $settings.data.snapEnabled)
                if settings.data.snapEnabled && SystemTiling.isOn {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("macOS 自带的边缘平铺开着，会和 Panes 抢。到“桌面与程序坞 → 窗口”里关掉“将窗口拖到屏幕边缘以平铺”和“将窗口拖到菜单栏以填充屏幕”。")
                            .font(.callout)
                        Spacer()
                        Button("打开") { SystemTiling.openSettings() }
                    }
                }
                Toggle("把吸附过的窗口拖开时恢复原来的大小", isOn: $settings.data.restoreSizeOnDragAway)
                Toggle("预览带动画", isOn: $settings.data.previewAnimates)
                Picker("按住这个键拖动就不吸附", selection: $settings.data.disableSnapModifier) {
                    ForEach([ModifierSet.none, .command, .option, .shift, .control]) { Text($0.label).tag($0) }
                }
                LabeledContent("边缘灵敏度") {
                    HStack { Slider(value: $settings.data.snapThreshold, in: 1...30); Text("\(Int(settings.data.snapThreshold)) px").monospacedDigit().frame(width: 44) }
                }
                LabeledContent("角落大小") {
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
                    Button("添加吸附区域") {
                        let a = SnapArea(edge: .top, from: 0.4, to: 0.6, target: UnitRect(0.25, 0, 0.5, 1))
                        settings.data.snapAreas.append(a)
                        editing = a
                    }
                    Spacer()
                    Button("恢复默认") { settings.resetSnapAreas() }
                }
            } header: {
                Text("吸附区域")
            } footer: {
                Text("把一条边分成几段就能有更多目标——比如默认的底边分成三段，各吸附到三分之一。角落总是优先于边。")
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
            Text("编辑吸附区域").font(.title3.bold())
            Form {
                Picker("触发位置", selection: $area.edge) {
                    ForEach(SnapEdge.allCases) { Text($0.label).tag($0) }
                }
                if !area.edge.isCorner {
                    LabeledContent("这一段的起点") {
                        HStack { Slider(value: $area.from, in: 0...1); Text("\(Int(area.from * 100))%").monospacedDigit().frame(width: 40) }
                    }
                    LabeledContent("这一段的终点") {
                        HStack { Slider(value: $area.to, in: 0...1); Text("\(Int(area.to * 100))%").monospacedDigit().frame(width: 40) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: area.edge.isCorner ? 80 : 150)
            Text("窗口放到").font(.callout).foregroundStyle(.secondary)
            UnitRectEditor(rect: $area.target)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
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
                Toggle("在绿色按钮的菜单旁加一个 Panes 小标签", isOn: $settings.data.paletteOnHover)
                LabeledContent("悬停延迟") {
                    HStack { Slider(value: $settings.data.paletteHoverDelay, in: 0.1...1.5); Text(String(format: "%.2fs", settings.data.paletteHoverDelay)).monospacedDigit().frame(width: 48) }
                }
                Stepper("网格列数：\(settings.data.gridColumns)", value: $settings.data.gridColumns, in: 2...24)
                Stepper("网格行数：\(settings.data.gridRows)", value: $settings.data.gridRows, in: 2...24)
            } header: {
                Text("面板")
            } footer: {
                Text("指针停在绿色按钮上时，macOS 自己的菜单照常出现，旁边多一个小网格标签——指向它就打开面板。点绿色按钮还是原来的行为。面板里显示哪些预设，在“快捷键”页里选；“显示面板”的快捷键（⌃⌥P）可以直接打开它。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("移动指针下的窗口", selection: $settings.data.moveModifier) {
                    ForEach(ModifierSet.allCases) { Text($0.label).tag($0) }
                }
                Picker("调整指针下窗口的大小", selection: $settings.data.resizeModifier) {
                    ForEach(ModifierSet.allCases) { Text($0.label).tag($0) }
                }
                Toggle("移动时把窗口提到最前", isOn: $settings.data.raiseOnHoverMove)
            } header: {
                Text("悬停移动与调整大小")
            } footer: {
                Text("按住这些键移动鼠标就行，不用点击。调整大小时抓的是离指针最近的那个角。")
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
                    Text("还没有布局。先把窗口摆好，再在这里或菜单栏里保存。")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.data.layouts) { $l in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("", text: $l.name).textFieldStyle(.plain).font(.headline)
                            if l.displaySignature == LayoutManager.displaySignature {
                                Text("当前显示器").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.green.opacity(0.2), in: Capsule())
                            }
                            Spacer()
                            ShortcutRecorder(shortcut: $l.shortcut)
                            Button("恢复") { LayoutManager.shared.restore(l) }
                            Menu {
                                Button("更新为当前窗口") {
                                    let fresh = LayoutManager.shared.capture(name: l.name)
                                    l.windows = fresh.windows
                                    l.displaySignature = fresh.displaySignature
                                }
                                Button(expanded == l.id ? "收起窗口列表" : "显示窗口列表") { expanded = expanded == l.id ? nil : l.id }
                                Divider()
                                Button("删除", role: .destructive) { settings.data.layouts.removeAll { $0.id == l.id } }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                        Toggle("连上这组显示器时自动应用", isOn: $l.autoApply)
                            .font(.callout)
                        Text("\(l.windows.count) 个窗口 · \(Set(l.windows.map(\.bundleID)).count) 个 App")
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
                    Text("保存的布局")
                    Spacer()
                    Button("保存当前布局…") { (NSApp.delegate as? AppDelegate)?.saveLayout() }
                }
            } footer: {
                Text("布局按 App 和窗口标题对应窗口。最小化的窗口不动，忽略的 App 会跳过。换了一组显示器时，窗口保持相对位置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("恢复布局时，最小化的窗口保持最小化", isOn: $settings.data.skipMinimizedOnRestore)
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
