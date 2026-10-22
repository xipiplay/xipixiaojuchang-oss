import AppKit
import AVFoundation

/// 提示词里「视频N / 音频N」的小图（2026-10-16 用户：音视频在提示词里只是文字，不像图片有缩略图）。
/// 做成一张图文件交给原来那套缩略图流程（编辑器内嵌附件、卡片上的提示词、@ 弹窗都按 `SlotItem.thumbnailURL` 取图）：
/// - 视频：本地文件的第一帧（没有本地文件 = 胶片图标 + 名字的小标签）；
/// - 音频：波形图标 + 名字的小标签。
/// 生成一次存在缓存目录里，按内容算文件名，之后直接用。
@MainActor
enum MediaTokenThumbnail {
    /// 小标签的高度（和图片缩略图同高，见 `SlotAttachment`）
    static let chipHeight: CGFloat = 18
    /// 小标签最宽多少（名字长的截断）
    static let chipMaxWidth: CGFloat = 104

    nonisolated static let directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("XipixiaojuchangOpen/media-token", isDirectory: true)

    /// 生成失败过的（坏文件之类）：本次运行不再试
    private static var failed: Set<String> = []

    /// 这张图是小标签（宽扁，按原比例贴、不按 16:9 裁）：音频、没有本地文件的视频
    nonisolated static func isChip(_ image: NSImage) -> Bool {
        image.size.height > 0 && image.size.width / image.size.height > 2.2
    }

    /// 这个素材在提示词里显示的图（文件 URL）；nil = 只能显示文字
    static func url(for item: LibraryItem?, token: String) -> URL? {
        let name = item?.matchName ?? token
        switch item?.kind {
        case .video:
            if let path = item?.localPath, FileManager.default.fileExists(atPath: path), let frame = videoFrame(path: path) { return frame }
            return chip(symbol: "film", text: name)
        case .audio:
            return chip(symbol: "waveform", text: name)
        default:
            return token.hasPrefix("音频") ? chip(symbol: "waveform", text: name) : nil
        }
    }

    // MARK: 视频首帧

    static func videoFrame(path: String) -> URL? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let file = directory.appendingPathComponent("frame-\(stableHash("\(path)|\(modified)")).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard !failed.contains(file.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        // 同步取一帧（本地文件、只取一次，之后读缓存）：等回调最多 2 秒
        let box = FrameBox()
        let done = DispatchSemaphore(value: 0)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0.1, preferredTimescale: 600))]) { _, image, _, _, _ in
            box.image = image
            done.signal()
        }
        guard done.wait(timeout: .now() + 2) == .success, let cg = box.image,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            failed.insert(file.path)
            return nil
        }
        return write(data, to: file)
    }

    private final class FrameBox: @unchecked Sendable { var image: CGImage? }

    // MARK: 小标签

    /// 圆角小标签：SF 图标 + 名字。颜色取深浅底上都看得清的中性灰（图里的颜色跟不了明暗切换）
    static func chip(symbol: String, text: String) -> URL? {
        let file = directory.appendingPathComponent("chip-\(stableHash("v2|\(symbol)|\(text)")).png")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard !failed.contains(file.path) else { return nil }
        let scale: CGFloat = 2
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let ink = NSColor(srgbRed: 0.55, green: 0.53, blue: 0.50, alpha: 1)
        let icon: CGFloat = 11, padding: CGFloat = 6, gap: CGFloat = 3
        var label = text
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: attributes).width) }
        // 太长就截断加「…」
        while padding * 2 + icon + gap + width(label) > chipMaxWidth, label.count > 1 {
            label = String(label.dropLast(label.hasSuffix("…") ? 2 : 1)) + "…"
        }
        let size = NSSize(width: padding * 2 + icon + gap + width(label), height: chipHeight)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { failed.insert(file.path); return nil }
        // ⚠️ 先定点尺寸再建上下文：反过来的话画布按像素坐标算，内容只占左下四分之一
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { failed.insert(file.path); return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(origin: .zero, size: size)
        NSColor(srgbRed: 0.5, green: 0.48, blue: 0.45, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        NSColor(srgbRed: 0.5, green: 0.48, blue: 0.45, alpha: 0.35).setStroke()
        let stroke = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
        stroke.lineWidth = 0.5
        stroke.stroke()
        if let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: icon, weight: .medium)) {
            let tinted = NSImage(size: symbolImage.size, flipped: false) { rect in
                symbolImage.draw(in: rect)
                ink.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let s = tinted.size
            let target = NSRect(x: padding + (icon - s.width) / 2, y: (size.height - s.height) / 2, width: s.width, height: s.height)
            tinted.draw(in: target)
        }
        let textHeight = (label as NSString).size(withAttributes: attributes).height
        (label as NSString).draw(at: NSPoint(x: padding + icon + gap, y: (size.height - textHeight) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { failed.insert(file.path); return nil }
        return write(data, to: file)
    }

    private static func write(_ data: Data, to file: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            failed.insert(file.path)
            return nil
        }
    }

    /// 跨次运行不变的哈希（`hashValue` 每次启动都不一样，不能拿来起文件名）
    nonisolated static func stableHash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }
}
