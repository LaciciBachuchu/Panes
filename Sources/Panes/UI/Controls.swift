import AppKit
import SwiftUI

/// Click to record a shortcut. Esc cancels, ⌫ without modifiers clears.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(recording ? "按下快捷键…" : (shortcut?.displayString ?? "录制"))
                    .frame(minWidth: 90)
                    .foregroundStyle(shortcut == nil && !recording ? .secondary : .primary)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if shortcut != nil && !recording {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("清除快捷键")
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        HotKeyManager.shared.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode == 53 { stop(); return nil }                         // Esc
            if e.keyCode == 51 && mods.isEmpty { shortcut = nil; stop(); return nil }
            let isFKey = (96...122).contains(Int(e.keyCode))
            guard !mods.isEmpty || isFKey else { NSSound.beep(); return nil }   // need a modifier
            shortcut = Shortcut(event: e)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        HotKeyManager.shared.paused = false
    }
}

/// Edits a unit rect by dragging on a grid, with numeric fields for fine-tuning.
struct UnitRectEditor: View {
    @Binding var rect: UnitRect
    var cols = 12
    var rows = 12
    @State private var drag: (Int, Int, Int, Int)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GeometryReader { g in
                let cw = g.size.width / CGFloat(cols), ch = g.size.height / CGFloat(rows)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))
                    Path { p in
                        for c in 1..<cols { p.move(to: CGPoint(x: CGFloat(c) * cw, y: 0)); p.addLine(to: CGPoint(x: CGFloat(c) * cw, y: g.size.height)) }
                        for r in 1..<rows { p.move(to: CGPoint(x: 0, y: CGFloat(r) * ch)); p.addLine(to: CGPoint(x: g.size.width, y: CGFloat(r) * ch)) }
                    }.stroke(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: g.size.width * rect.w, height: g.size.height * rect.h)
                        .offset(x: g.size.width * rect.x, y: g.size.height * rect.y)
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.3))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    func cell(_ p: CGPoint) -> (Int, Int) {
                        (min(max(Int(p.x / cw), 0), cols - 1), min(max(Int(p.y / ch), 0), rows - 1))
                    }
                    let a = cell(v.startLocation), b = cell(v.location)
                    let x0 = min(a.0, b.0), x1 = max(a.0, b.0), y0 = min(a.1, b.1), y1 = max(a.1, b.1)
                    rect = UnitRect(Double(x0) / Double(cols), Double(y0) / Double(rows),
                                    Double(x1 - x0 + 1) / Double(cols), Double(y1 - y0 + 1) / Double(rows))
                })
            }
            .frame(width: 192, height: 120)

            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                row("X", \.x); row("Y", \.y); row("宽", \.w); row("高", \.h)
            }
            .font(.callout)
        }
    }

    private func row(_ label: String, _ kp: WritableKeyPath<UnitRect, Double>) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            TextField("", value: Binding(
                get: { (rect[keyPath: kp] * 1000).rounded() / 10 },
                set: { rect[keyPath: kp] = max(0, min(1, $0 / 100)) }
            ), format: .number)
            .frame(width: 60)
            .textFieldStyle(.roundedBorder)
            Text("%").foregroundStyle(.secondary)
        }
    }
}

/// Small static picture of a unit rect.
struct UnitThumb: View {
    let rect: UnitRect?
    var symbol: String = "questionmark"

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.4))
                if let u = rect {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor)
                        .frame(width: max(2, g.size.width * u.w - 3), height: max(2, g.size.height * u.h - 3))
                        .offset(x: g.size.width * u.x + 1.5, y: g.size.height * u.y + 1.5)
                } else {
                    Image(systemName: symbol).font(.system(size: 10))
                        .frame(width: g.size.width, height: g.size.height)
                }
            }
        }
        .frame(width: 30, height: 20)
    }
}
