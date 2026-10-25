import AppKit
import SwiftUI

/// Settings for roll-up, title-bar gestures, pinning and magic tiling.
struct FeaturesTab: View {
    @EnvironmentObject var settings: Settings
    @State private var canCapture = WindowCapture.hasPermission

    var body: some View {
        Form {
            rollUpSection
            gestureSection
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
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle("看一眼：指针停在卷起的窗口上时显示里面的内容", isOn: $settings.data.glanceEnabled)
                if settings.data.glanceEnabled {
                    permissionRow
                }
            }
        } header: {
            Text("卷起")
        } footer: {
            Text("窗口的高度缩到只剩标题栏，留在原处，不隐藏、不最小化；再双击（或按快捷键）恢复原来的高度。卷起时照常拖标题栏移动，展开时窗口从标题栏所在的位置往下展开。个别 App 规定了最小高度、缩不到标题栏那么矮，这时不卷起，双击照系统原来的行为处理。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var doubleClickNote: String {
        let raw = (UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize").lowercased()
        let system = raw.contains("mini") ? "最小化" : (raw.contains("none") ? "不做事" : "缩放")
        return "系统设置里双击标题栏是“\(system)”。打开这一项后，标题栏上的双击改为卷起；按钮、输入框、内容区域和按住修饰键的双击仍按原样。"
    }

    // MARK: 标题栏手势

    private var gestureSection: some View {
        Section {
            Toggle("触控板：两指滑动、张开、捏合", isOn: $settings.data.trackpadGesturesEnabled)
            Toggle("鼠标滚轮：在标题栏上滚 3 格算一次滑动", isOn: $settings.data.scrollWheelGesturesEnabled)
            Toggle("甩动：拖着标题栏快速甩出去再松手", isOn: $settings.data.flingEnabled)
        } header: {
            Text("标题栏手势")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("指针停在标题栏上再做手势，松手才执行，滑到一半退回去就是取消。")
                Text("往上推：卷起（刚用手势铺满的窗口先还原）。往下拉：铺满。往左 / 往右：半屏，继续往同一方向依次是 ⅔、⅓，再一次移到那一侧的显示器。左右滑到底再往上或往下拐：占那一侧的上角或下角。张开：铺满。捏合：撤销上一次摆放。")
                Text("甩动：松手时在吸附区域里按吸附处理；不在吸附区域、但甩得够快，就按甩的方向摆放（上 = 卷起，下 = 铺满，左右 = 半屏，斜着 = 那个角）。")
                Text("浏览器标签页、地址栏这类自己会用横向滑动的地方，横向手势留给 App。")
            }
            .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var permissionRow: some View {
        HStack {
            Image(systemName: canCapture ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(canCapture ? .green : .orange)
            Text(canCapture ? "已允许屏幕录制"
                            : "还没有屏幕录制权限：看一眼只能显示提示文字")
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
