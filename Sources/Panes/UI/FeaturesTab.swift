import AppKit
import SwiftUI

/// Settings for roll-up, title-bar gestures, pinning and magic tiling.
struct FeaturesTab: View {
    @EnvironmentObject var settings: Settings
    @State private var canCapture = WindowCapture.hasPermission

    var body: some View {
        Form {
            rollUpSection
        }
        .formStyle(.grouped)
        .onAppear { canCapture = WindowCapture.hasPermission }
    }

    // MARK: 卷起

    private var rollUpSection: some View {
        Section {
            Toggle("卷起窗口", isOn: $settings.data.rollUpEnabled)
            if settings.data.rollUpEnabled {
                LabeledContent("快捷键") { ShortcutRecorder(shortcut: shortcut(for: .rollUp)) }
                Toggle("双击标题栏卷起", isOn: $settings.data.rollUpOnDoubleClick)
                if settings.data.rollUpOnDoubleClick {
                    Text(doubleClickNote).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("看一眼：指针停在卷帘条上时显示窗口内容", isOn: $settings.data.glanceEnabled)
                if settings.data.glanceEnabled {
                    permissionRow
                }
            }
        } header: {
            Text("卷起")
        } footer: {
            Text("窗口收成一条和标题栏一样高的细条，留在原处；双击细条展开，细条可以拖动，展开时窗口出现在细条的位置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var doubleClickNote: String {
        let raw = (UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize").lowercased()
        let system = raw.contains("mini") ? "最小化" : (raw.contains("none") ? "不做事" : "缩放")
        return "系统设置里双击标题栏是“\(system)”。打开这一项后，标题栏上的双击改为卷起；按钮、输入框、内容区域和按住修饰键的双击仍按原样。"
    }

    @ViewBuilder private var permissionRow: some View {
        HStack {
            Image(systemName: canCapture ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(canCapture ? .green : .orange)
            Text(canCapture ? "已允许屏幕录制，卷帘条和看一眼能显示窗口画面"
                            : "没有屏幕录制权限时，看一眼只能显示提示文字")
                .font(.callout)
            Spacer()
            if !canCapture {
                Button("去允许") {
                    WindowCapture.requestPermission()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
    }

    /// Binding to the shortcut of the (first) action of a kind.
    func shortcut(for kind: ActionKind) -> Binding<Shortcut?> {
        Binding(
            get: { settings.data.actions.first { $0.kind == kind }?.shortcut },
            set: { new in
                if let i = settings.data.actions.firstIndex(where: { $0.kind == kind }) {
                    settings.data.actions[i].shortcut = new
                }
            }
        )
    }
}
