// アプリアイコンを描いて Resources/AppIcon.icns を作る
// 使い方: swift scripts/make_icon.swift  （リポジトリのルートで実行）
import AppKit

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)

    // 角丸の半透明っぽい濃紺の板
    let plate = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.26, blue: 0.40, alpha: 0.96),
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.16, alpha: 0.96),
    ])!.draw(in: platePath, angle: -90)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    platePath.lineWidth = max(1, s * 0.012)
    platePath.stroke()

    // 見出しの帯
    let header = NSRect(x: s * 0.22, y: s * 0.66, width: s * 0.40, height: s * 0.07)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: header, xRadius: s * 0.035, yRadius: s * 0.035).fill()

    // 予定の行（カレンダー色のバー＋文字の代わりの線）
    let colors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange]
    for (index, color) in colors.enumerated() {
        let y = s * (0.51 - CGFloat(index) * 0.14)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: s * 0.22, y: y, width: s * 0.045, height: s * 0.09),
                     xRadius: s * 0.02, yRadius: s * 0.02).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        let width = s * (index == 1 ? 0.36 : 0.46)
        NSBezierPath(roundedRect: NSRect(x: s * 0.31, y: y + s * 0.025, width: width, height: s * 0.04),
                     xRadius: s * 0.02, yRadius: s * 0.02).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
print(iconset.appendingPathComponent("icon_256x256.png").path)
