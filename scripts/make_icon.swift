import Foundation
import AppKit

// 用法: swift make_icon.swift <源图> <iconset目录>
// 用 AppKit 生成带 alpha 的各尺寸 PNG（iconutil 需要 RGBA）

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: swift make_icon.swift <源图> <iconset目录>")
    exit(1)
}
let src = args[1]
let iconset = args[2]

guard let image = NSImage(contentsOfFile: src) else {
    print("无法读取图片: \(src)")
    exit(1)
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (size, name) in sizes {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { continue }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    }
}
print("done")
