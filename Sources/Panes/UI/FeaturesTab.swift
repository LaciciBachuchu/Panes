import AppKit
import SwiftUI

/// Settings for roll-up, title-bar gestures, pinning and magic tiling.
struct FeaturesTab: View {
    @EnvironmentObject var settings: Settings
    @State private var canCapture = WindowCapture.hasPermission

    var body: some View {
        Form {
            gestureSection
        }
        .formStyle(.grouped)
        .onAppear { canCapture = WindowCapture.hasPermission }
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
                Text("往下拉：铺满；往上推：还原刚用手势铺满的窗口。往左 / 往右：半屏，继续往同一方向依次是 ⅔、⅓，再一次移到那一侧的显示器。左右滑到底再往上或往下拐：占那一侧的上角或下角。张开：铺满。捏合：撤销上一次摆放。")
                Text("甩动：松手时在吸附区域里按吸附处理；不在吸附区域、但甩得够快，就按甩的方向摆放（上 = 还原刚铺满的窗口，下 = 铺满，左右 = 半屏，斜着 = 那个角）。")
                Text("浏览器标签页、地址栏这类自己会用横向滑动的地方，横向手势留给 App。")
            }
            .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
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
