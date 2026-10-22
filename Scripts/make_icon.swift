// Renders the app icon into an .iconset folder: swift make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle background with a blue→indigo gradient.
    let inset = s * 0.1
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                          xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 1),
                        NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.85, alpha: 1)])!.draw(in: bg, angle: -60)

    // Four panes: big left, two right, like a snapped desktop.
    let pad = s * 0.2, gap = s * 0.035
    let area = NSRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let r = s * 0.03
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect: NSRect(x: area.minX, y: area.minY, width: area.width / 2 - gap / 2, height: area.height), xRadius: r, yRadius: r).fill()
    NSColor.white.withAlphaComponent(0.7).setFill()
    NSBezierPath(roundedRect: NSRect(x: area.midX + gap / 2, y: area.midY + gap / 2, width: area.width / 2 - gap / 2, height: area.height / 2 - gap / 2), xRadius: r, yRadius: r).fill()
    NSColor.white.withAlphaComponent(0.5).setFill()
    NSBezierPath(roundedRect: NSRect(x: area.midX + gap / 2, y: area.minY, width: area.width / 2 - gap / 2, height: area.height / 2 - gap / 2), xRadius: r, yRadius: r).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
