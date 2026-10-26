import AppKit
import SwiftUI

/// Settings for roll-up, title-bar gestures, pinning and magic tiling.
struct FeaturesTab: View {
    @EnvironmentObject var settings: Settings
    @State private var canCapture = WindowCapture.hasPermission

    var body: some View {
        Form {
            gestureSection
            dividerSection
            stripSection
            carrySection
            slideOverSection
        }
        .formStyle(.grouped)
        .onAppear { canCapture = WindowCapture.hasPermission }
    }

    // MARK: 标题栏手势

    private var gestureSection: some View {
        Section {
            Toggle("触控板：两指滑动、张开、捏合", isOn: $settings.data.trackpadGesturesEnabled)
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

    // MARK: 卷轴

    private var stripSection: some View {
        Section {
            Toggle("卷轴", isOn: $settings.data.scrollStripEnabled)
            if settings.data.scrollStripEnabled {
                LabeledContent("快捷键") { ShortcutRecorder(shortcut: shortcut(for: .scrollStrip)) }
                Toggle("反转滚动方向", isOn: $settings.data.stripReverseScroll)
                LabeledContent("滚动灵敏度") {
                    HStack {
                        Slider(value: $settings.data.stripScrollSpeed, in: 0.25...4)
                        Text(String(format: "%.2f×", settings.data.stripScrollSpeed)).monospacedDigit().frame(width: 50)
                    }
                }
                Toggle("停下时对齐到列", isOn: $settings.data.stripSnapToColumns)
                LabeledContent("这一列左移") { ShortcutRecorder(shortcut: shortcut(for: .stripMoveLeft)) }
                LabeledContent("这一列右移") { ShortcutRecorder(shortcut: shortcut(for: .stripMoveRight)) }
            }
        } header: {
            Text("卷轴")
        } footer: {
            Text("点菜单栏图标里的“卷轴”（或按快捷键），当前屏幕上的窗口排成一条横着的卷轴：每列整屏高，宽度取三分之一、一半、三分之二或整屏；放不下的列停在屏幕外，只在边上露一条。卷轴开着时，指针停在任意一列的标题栏上滚动滚轮（或两指滑动），整条卷轴平滑地跟着走，方向和灵敏度在上面调；左下角那块和 Dock 一样高的滚动条也可以拖或滚。默认滚到哪停在哪，打开“停下时对齐到列”就会停到最近一列的边上。拖着某一列的标题栏左右移动，松手就把它插到预览写着“放到这里”的位置；快捷键也能把当前窗口那一列左移或右移（只在卷轴开着时生效）。指针停在露出来的那条上看一眼那扇窗口，点那条就滑过去；两指张开、双击左下角滚动条或按 ⌃↑ 进概览（卷轴开着时 ⌃↑ 打开概览而不是调度中心），点哪扇就滑到哪一列。再点一次“卷轴”（或再按快捷键），窗口回到原处。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 分屏分隔线

    private var dividerSection: some View {
        Section {
            Toggle("窗口拼满屏幕时，在缝上显示分隔线", isOn: $settings.data.splitDividersEnabled)
        } header: {
            Text("分屏分隔线")
        } footer: {
            Text("两扇窗口左右或上下拼满一块屏时（不管是快捷键、吸附还是手动摆的），中间出现一根小竖条；四角、三等分、网格排好的窗口，每条缝都有一根。拖它，缝两边的窗口一起变；松手吸到三分之一、一半或三分之二。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 侧拉

    private var slideOverSection: some View {
        Section {
            Toggle("侧拉（实验，未完成）", isOn: $settings.data.slideOverEnabled)
            if settings.data.slideOverEnabled {
                LabeledContent("快捷键") { ShortcutRecorder(shortcut: shortcut(for: .slideOver)) }
                LabeledContent("在边缘中段停多久进侧拉") {
                    HStack {
                        Slider(value: $settings.data.slideOverDwell, in: 0.2...1.5)
                        Text(String(format: "%.1f 秒", settings.data.slideOverDwell)).monospacedDigit().frame(width: 50)
                    }
                }
            }
        } header: {
            Text("侧拉")
        } footer: {
            Text("拖着标题栏到屏幕左边或右边的中段停一下，预览变成紫色、写着“侧拉”时松手，窗口就靠在那一边、浮在其他窗口前面；直接松手照旧是吸附半屏。拖玻璃边框挪位置，拖下面两个角改大小。往屏幕边一甩就收起，边上留一个小把手，点一下或往里拉就回来；把窗口拖离边缘就退出侧拉。同一时间只有一扇侧拉窗口。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 带到每张桌面

    private var carrySection: some View {
        Section {
            Toggle("带到每张桌面", isOn: $settings.data.carryEnabled)
            if settings.data.carryEnabled {
                LabeledContent("快捷键") { ShortcutRecorder(shortcut: shortcut(for: .carry)) }
                permissionRow
            }
        } header: {
            Text("带到每张桌面")
        } footer: {
            Text("按快捷键，当前窗口留在原处；切到别的桌面时，右上角出现它的细条。指针停在细条上看它现在的样子，单击回到那扇窗口，点细条右边的叉或再按一次快捷键就不再带着。看实时画面需要屏幕录制权限。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var permissionRow: some View {
        HStack {
            Image(systemName: canCapture ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(canCapture ? .green : .orange)
            Text(canCapture ? "已允许屏幕录制" : "还没有屏幕录制权限：只能显示文字，看不到画面")
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
