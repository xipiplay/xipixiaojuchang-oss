import SwiftUI
import AppKit

/// 工作台段落卡下半块的字（时间、角色名、道具、两行剧情摘要、四步进度）**在后台画成一张图**（2026-10-15 用户：换回段落卡后滑动好卡）。
/// 实测（真实 297 段项目、同一种滑法）：把下半块换成空白，超过 8ms 的帧从几十个降到 0——卡顿就是这一块的一堆 Text。
/// 做法照生视频缩略图卡的文字条（`BakedThumbText` / `ThumbTextRaster`）：CoreText 在后台线程画、按内容缓存，滑动时只贴图。
/// 角色头像不在图里（是图片），叠在上面。版式和原来的实时 Text 一样：
/// 上下内边距 12、左右 14；第一行 26 高（左边头像、右边时间）、角色名 15、道具 14（间距 5）；隔 9 是两行剧情（34）；隔 9 是四步（28）
struct SegmentTextState: Hashable, Sendable {
    // 封面上的：左上段号、右上状态（0 平常 1 进行中 2 完成 3 有问题）、左下场景名；没有场景图时整块画成主色淡底 + 场景图标 + 名字
    var number: Int
    var status: String
    var statusTone: Int
    var sceneName: String?
    var hasPicture: Bool
    var time: String
    var names: String
    /// 这一段没有列出角色：第一行左边写一句（没有头像）
    var noPeople: Bool
    var props: String
    var excerpt: String
    var excerptEmpty: Bool
    /// 四步的状态：0 待做、1 完成、2 有问题、3 正在做
    var steps: [Int]
    var width: CGFloat

    /// 整张卡的高（= `WorkbenchSegmentGrid.cardHeight`）：封面 118 + 下半块 169
    static let height: CGFloat = 287
    static let coverHeight: CGFloat = 118

    static func stepCode(_ state: WorkbenchStatus.ShotStatus.StepState) -> Int {
        switch state {
        case .pending: 0
        case .done: 1
        case .problem: 2
        case .running: 3
        }
    }
}

/// 画图要用的颜色（主线程按当前深 / 浅解析成固定颜色，再交给后台）
struct SegmentTextColors: @unchecked Sendable {
    let secondary: NSColor
    let tertiary: NSColor
    let pendingDot: NSColor
    let success: NSColor
    let danger: NSColor
    let accent: NSColor
    /// 没有场景图时封面的淡底
    let coverTint: NSColor
    let dark: Bool

    @MainActor
    static func resolve(dark: Bool) -> SegmentTextColors {
        var result: SegmentTextColors!
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            func fixed(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB) ?? color }
            result = SegmentTextColors(
                secondary: fixed(.secondaryLabelColor),
                tertiary: fixed(.tertiaryLabelColor),
                pendingDot: fixed(NSColor.labelColor.withAlphaComponent(0.22)),
                success: fixed(NSColor(Theme.success)),
                danger: fixed(NSColor(Theme.danger)),
                accent: fixed(NSColor(Theme.accent)),
                coverTint: fixed(NSColor(Theme.accent).withAlphaComponent(dark ? 0.16 : 0.10)),
                dark: dark)
        }
        return result
    }
}

@MainActor
enum SegmentTextImageCache {
    private static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 600
        c.totalCostLimit = 128 * 1024 * 1024
        return c
    }()

    static func key(_ state: SegmentTextState, dark: Bool) -> NSString {
        "\(state.hashValue)|\(dark)|\(ColorThemeStore.shared.current.rawValue)" as NSString
    }
    static func cached(_ key: NSString) -> CGImage? { cache.object(forKey: key) }
    static func store(_ image: CGImage, _ key: NSString) { cache.setObject(image, forKey: key, cost: image.width * image.height * 4) }
}

enum SegmentTextRaster {
    static func render(_ s: SegmentTextState, colors: SegmentTextColors, scale: CGFloat = 2) -> CGImage? {
        let width = max(120, s.width)
        let height = SegmentTextState.height
        let pxW = Int((width * scale).rounded()), pxH = Int((height * scale).rounded())
        guard pxW > 1, pxH > 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: scale, y: -scale)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        defer { NSGraphicsContext.restoreGraphicsState() }

        drawCover(s, colors: colors, ctx: ctx, width: width)
        // 下半块从封面下沿开始
        ctx.translateBy(x: 0, y: SegmentTextState.coverHeight)
        let left: CGFloat = 14, inner = width - 28
        func para(_ mode: NSLineBreakMode, align: NSTextAlignment = .left) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle(); p.lineBreakMode = mode; p.alignment = align; return p
        }
        /// 一行字在 [y, y+h) 里竖着居中
        func line(_ text: String, font: NSFont, color: NSColor, y: CGFloat, h: CGFloat, align: NSTextAlignment = .left) {
            let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para(.byTruncatingTail, align: align)])
            let lineH = ceil(font.ascender - font.descender)
            attr.draw(with: CGRect(x: left, y: y + (h - lineH) / 2, width: inner, height: lineH), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        // 第一行：右边时间；没有角色时左边写一句
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        if !s.time.isEmpty { line(s.time, font: digits, color: colors.secondary, y: 12, h: 26, align: .right) }
        if s.noPeople { line("（这一段没有列出角色）", font: .systemFont(ofSize: 12), color: colors.tertiary, y: 12, h: 26) }
        line(s.names, font: .systemFont(ofSize: 12), color: colors.secondary, y: 43, h: 15)
        if !s.props.isEmpty { line(s.props, font: .systemFont(ofSize: 11.5), color: colors.tertiary, y: 63, h: 14) }

        // 两行剧情
        let excerpt = NSAttributedString(string: s.excerpt, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: s.excerptEmpty ? colors.tertiary : colors.secondary,
            .paragraphStyle: para(.byWordWrapping)])
        excerpt.draw(with: CGRect(x: left, y: 86, width: inner, height: 34), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        // 四步
        let titles = ["提取", "出图", "匹配", "视频"]
        let stepsLine = NSMutableAttributedString()
        for (i, code) in s.steps.enumerated() where i < titles.count {
            if i > 0 { stepsLine.append(NSAttributedString(string: "   ", attributes: [.font: NSFont.systemFont(ofSize: 11)])) }
            let dotColor: NSColor = [colors.pendingDot, colors.success, colors.danger, colors.accent][min(max(code, 0), 3)]
            let dotFont: NSFont = code == 3 ? .systemFont(ofSize: 9, weight: .heavy) : .systemFont(ofSize: 9)
            stepsLine.append(NSAttributedString(string: code == 3 ? "○" : "●", attributes: [.font: dotFont, .foregroundColor: dotColor]))
            stepsLine.append(NSAttributedString(string: " " + titles[i], attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: code == 2 ? colors.danger : colors.secondary]))
        }
        let stepsH: CGFloat = ceil(NSFont.systemFont(ofSize: 11).ascender - NSFont.systemFont(ofSize: 11).descender)
        stepsLine.draw(with: CGRect(x: left, y: 129 + (28 - stepsH) / 2, width: inner, height: stepsH), options: [.usesLineFragmentOrigin])

        return ctx.makeImage()
    }

    /// 封面上的字和底：没图 = 主色淡底 + 场景图标 + 场景名居中；有图 = 下半截压暗渐变 + 左下场景名。左上段号、右上状态各一个小黑底
    private static func drawCover(_ s: SegmentTextState, colors: SegmentTextColors, ctx: CGContext, width: CGFloat) {
        let coverH = SegmentTextState.coverHeight
        let white = NSColor.white
        if s.hasPicture {
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let gradient = CGGradient(colorsSpace: space, colors: [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.55).cgColor] as CFArray,
                                         locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: coverH / 2, width: width, height: coverH / 2))
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: coverH / 2), end: CGPoint(x: 0, y: coverH), options: [])
                ctx.restoreGState()
            }
            if let name = s.sceneName {
                let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
                let attr = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: white, .paragraphStyle: p])
                attr.draw(with: CGRect(x: 12, y: coverH - 9 - 17, width: width - 24, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        } else {
            colors.coverTint.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: coverH)).fill()
            let iconSize: CGFloat = 22
            var y = coverH / 2 - (s.sceneName == nil ? iconSize / 2 : 20)
            if let symbol = NSImage(systemSymbolName: PipelineFlow.ExtractionKind.scene.icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular).applying(.init(paletteColors: [colors.accent.withAlphaComponent(0.55)]))) {
                let size = symbol.size
                symbol.draw(in: CGRect(x: (width - size.width) / 2, y: y, width: size.width, height: size.height))
                y += size.height + 6
            }
            if let name = s.sceneName {
                let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byTruncatingTail
                let attr = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: colors.secondary, .paragraphStyle: p])
                attr.draw(with: CGRect(x: 14, y: y, width: width - 28, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
        // 小黑底标签（段号 / 状态）
        func plate(_ text: String, font: NSFont, dot: NSColor?, alignRight: Bool) {
            let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: white])
            let textW = ceil(attr.size().width), textH = ceil(font.ascender - font.descender)
            let dotW: CGFloat = dot == nil ? 0 : 12
            let w = textW + dotW + 18, h = textH + 6
            let x = alignRight ? width - 10 - w : 10
            let rect = CGRect(x: x, y: 10, width: w, height: h)
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
            if let dot {
                dot.setFill()
                NSBezierPath(ovalIn: CGRect(x: x + 9, y: 10 + (h - 7) / 2, width: 7, height: 7)).fill()
            }
            attr.draw(at: CGPoint(x: x + 9 + dotW, y: 13))
        }
        plate(String(format: "%02d", s.number), font: .monospacedDigitSystemFont(ofSize: 14, weight: .semibold), dot: nil, alignRight: false)
        let dotColor: NSColor = [white.withAlphaComponent(0.6), colors.accent, colors.success, colors.danger][min(max(s.statusTone, 0), 3)]
        plate(s.status, font: .systemFont(ofSize: 11.5, weight: .medium), dot: dotColor, alignRight: true)
    }
}

/// 烤好的下半块字：有缓存直接贴，没有就后台画（画好之前是空白）
struct BakedSegmentText: View {
    let state: SegmentTextState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorTheme) private var colorTheme
    @State private var image: CGImage?

    private struct BakeKey: Hashable { let state: SegmentTextState; let dark: Bool; let theme: ColorTheme }

    var body: some View {
        // 缓存里有就当场贴上（不等 .task 下一拍，新滑进来的卡不闪一下空白）
        let shown = image ?? SegmentTextImageCache.cached(SegmentTextImageCache.key(state, dark: colorScheme == .dark))
        Group {
            if let shown {
                Image(decorative: shown, scale: 2).resizable().interpolation(.medium)
            } else {
                Color.clear
            }
        }
        .frame(width: state.width, height: SegmentTextState.height)
        .task(id: BakeKey(state: state, dark: colorScheme == .dark, theme: colorTheme)) {
            let dark = colorScheme == .dark
            let key = SegmentTextImageCache.key(state, dark: dark)
            if let hit = SegmentTextImageCache.cached(key) { image = hit; return }
            image = nil
            let colors = SegmentTextColors.resolve(dark: dark)
            let state = state
            let baked = await Task.detached(priority: .userInitiated) { SegmentTextRaster.render(state, colors: colors) }.value
            guard !Task.isCancelled, let baked else { return }
            SegmentTextImageCache.store(baked, key)
            image = baked
        }
    }
}
