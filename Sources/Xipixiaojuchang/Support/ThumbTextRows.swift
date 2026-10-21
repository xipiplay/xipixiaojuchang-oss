import SwiftUI
import AppKit
import CoreText

/// 缩略图卡片上的文字状态（名字 / N 版 / 状态 / 参数）。
///
/// ⚠️ **2026-09-27 定稿：格子里的文字走"后台烤图"**（见 `BakedThumbText`）。
/// 实测（同项目、同滑法，逐项加回）：空壳 = 很丝滑；只缩略图 = 比较丝滑；**只文字 = 明显变差**
/// —— 文字条是网格滚动卡顿的主犯，图那条路是干净的。
/// 烤图用 **CoreText / CoreGraphics 在后台线程画**（区别于已废弃的 ImageRenderer 版——那个只能主线程、
/// 每张 ~10ms；这版每张 ~1ms、不占主线程）。
struct ThumbTextState: Hashable, Sendable {
    var title: String
    var countText: String
    var statusTitle: String
    /// 0 = 默认（排队/暂停/待生成）· 1 = orange（生成中）· 2 = green（完成）· 3 = red（失败）
    var statusColorTag: Int
    var paramsText: String
    var showsParams: Bool
    /// 改过参数还没提交（true = 参数文字用强调色）
    var paramsDirty: Bool
    var width: CGFloat

    /// 缓存键（颜色语义用 tag 编码；白字 + 黑底衬与主题无关，所以键里不带亮暗）
    var cacheKey: String {
        "sq|\(Int(width.rounded()))|\(statusColorTag)|\(showsParams ? 1 : 0)|\(paramsDirty ? 1 : 0)|\(title)|\(countText)|\(statusTitle)|\(paramsText)"
    }
}

/// 烤好的"方形内文字条"缓存（NSCache；成本按**位图字节数**算）。
@MainActor
enum ThumbTextImageCache {
    private static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 600
        c.totalCostLimit = 96 * 1024 * 1024   // 2x 条 ≈ 0.2MB/张 → 约 430 张
        return c
    }()

    /// `plain`：浅色界面用深色字（见 `ThumbTextThemeStore.plainLight`），和深色界面的白字分开缓存
    private static func key(_ state: ThumbTextState, plain: Bool) -> NSString {
        // 配色主题也进键：换主题后，缓存里带着旧主色 / 旧渐变底的图不会被拿来用
        (state.cacheKey + (plain ? "|plain" : "") + "|" + ColorThemeStore.shared.current.rawValue) as NSString
    }

    static func cached(for state: ThumbTextState, plain: Bool = false) -> CGImage? {
        cache.object(forKey: key(state, plain: plain))
    }

    static func store(_ image: CGImage, for state: ThumbTextState, plain: Bool = false) {
        cache.setObject(image, forKey: key(state, plain: plain),
                        cost: image.width * image.height * 4)
    }
}

/// 烤图要用的字体/颜色 —— 在主线程解析一次，之后传给后台渲染（NSFont/NSColor 不可变、可跨线程读）。
struct ThumbTextTheme: @unchecked Sendable {
    let titleFont: NSFont
    let smallFont: NSFont
    let titleColor: NSColor
    let countColor: NSColor
    let statusColor: NSColor
    let paramsColor: NSColor
    let paramsDirtyColor: NSColor
    /// statusColorTag 0..3 对应的圆点色
    let dotColors: [NSColor]
}

@MainActor
enum ThumbTextThemeStore {
    private static var titleFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
    }
    private static var smallFont: NSFont { NSFont.preferredFont(forTextStyle: .caption2) }

    private static let sage = NSColor(hex: 0x6FBF8E)
    private static let brick = NSColor(hex: 0xE5645A)
    private static let sageDeep = NSColor(hex: 0x3E8F62)
    private static let brickDeep = NSColor(hex: 0xC94A40)

    /// 深色界面的文字：和软件里别处的主文字同色（暖白），没有渐变底衬、没有阴影——**就是普通文字**
    /// （2026-10-08 用户："黑色渐变总感觉脏脏的"、"文字不需要补阴影，就正常化，像普通文字跟随系统变化"）。
    /// 「改了参数还没提交」的参数字和「生成中」的点用主色（原来是系统亮黄 / 橙），和软件里「需要你动手」是同一个颜色。
    static var shared: ThumbTextTheme {
        let dark = ColorThemeStore.shared.current.mode(dark: true)
        let accent = NSColor(hex: dark.accent)
        let ink = NSColor(hex: dark.textPrimary)
        return ThumbTextTheme(
            titleFont: titleFont,
            smallFont: smallFont,
            titleColor: ink,
            countColor: ink.withAlphaComponent(0.6),
            statusColor: ink.withAlphaComponent(0.75),
            paramsColor: ink.withAlphaComponent(0.6),
            paramsDirtyColor: accent,
            dotColors: [ink.withAlphaComponent(0.45), accent, sage, brick]
        )
    }

    /// 浅色界面的文字：深色字（同样没有渐变、没有阴影）。**所有格子**浅色界面下都用它，不再区分有没有图。
    static var plainLight: ThumbTextTheme {
        let light = ColorThemeStore.shared.current.mode(dark: false)
        let ink = NSColor(hex: light.textPrimary)
        return ThumbTextTheme(
            titleFont: titleFont,
            smallFont: smallFont,
            titleColor: ink,
            countColor: ink.withAlphaComponent(0.6),
            statusColor: ink.withAlphaComponent(0.75),
            paramsColor: ink.withAlphaComponent(0.6),
            paramsDirtyColor: NSColor(hex: light.controlTint),
            dotColors: [ink.withAlphaComponent(0.45), NSColor(hex: light.accent), sageDeep, brickDeep]
        )
    }

    /// 按界面深 / 浅取文字主题
    static func theme(light: Bool) -> ThumbTextTheme { light ? plainLight : shared }
}

/// **后台烤图**（CoreText/CoreGraphics 画一张普通文字的小图：颜色跟随界面深 / 浅，没有底衬也没有阴影；原来有底部渐变底衬，2026-10-08 撤了）。
/// 版式与实时版 `ThumbTextRows` 对齐：左右 padding 8 / 顶部 22（原来是渐变过渡区，现在只是留白，保持文字位置不变）/ 底部 8 / 两行间距 6。
nonisolated enum ThumbTextRaster {
    static func render(_ s: ThumbTextState, theme: ThumbTextTheme, scale: CGFloat = 2) -> CGImage? {
        let padH: CGFloat = 8
        let padTop: CGFloat = 22
        let padBottom: CGFloat = 8
        let spacing: CGFloat = 6
        let dotSize: CGFloat = 6
        let dotGap: CGFloat = 5
        let width = max(60, s.width)

        func lineHeight(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) }
        let row1H = max(lineHeight(theme.titleFont), lineHeight(theme.smallFont))
        let row2H = max(dotSize, lineHeight(theme.smallFont))
        let height = padTop + row1H + spacing + row2H + padBottom

        let pxW = Int((width * scale).rounded())
        let pxH = Int((height * scale).rounded())
        guard pxW > 1, pxH > 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // 翻成"左上角原点、y 向下"（和 SwiftUI 排版直觉一致）
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: scale, y: -scale)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        defer { NSGraphicsContext.restoreGraphicsState() }


        // 第一行：名称（左，超长中间省略）+ N 版（右）
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingMiddle
        let countStyle = NSMutableParagraphStyle()
        countStyle.alignment = .right
        let countAttr = NSAttributedString(string: s.countText, attributes: [
            .font: theme.smallFont, .foregroundColor: theme.countColor, .paragraphStyle: countStyle,
        ])
        let countW = ceil(countAttr.size().width)
        let titleRect = CGRect(x: padH, y: padTop,
                               width: max(10, width - padH * 2 - countW - 6), height: row1H)
        NSAttributedString(string: s.title, attributes: [
            .font: theme.titleFont, .foregroundColor: theme.titleColor, .paragraphStyle: titleStyle,
        ]).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        countAttr.draw(with: CGRect(x: width - padH - countW, y: padTop, width: countW, height: row1H),
                       options: [.usesLineFragmentOrigin])

        // 第二行：圆点 + 状态 +（可选）参数
        let row2Y = padTop + row1H + spacing
        theme.dotColors[min(max(s.statusColorTag, 0), theme.dotColors.count - 1)].setFill()
        NSBezierPath(ovalIn: CGRect(x: padH, y: row2Y + (row2H - dotSize) / 2,
                                    width: dotSize, height: dotSize)).fill()

        var x = padH + dotSize + dotGap
        let statusAttr = NSAttributedString(string: s.statusTitle, attributes: [
            .font: theme.smallFont, .foregroundColor: theme.statusColor,
        ])
        let statusW = ceil(statusAttr.size().width)
        statusAttr.draw(with: CGRect(x: x, y: row2Y, width: statusW, height: row2H),
                        options: [.usesLineFragmentOrigin])
        x += statusW + dotGap

        if s.showsParams, !s.paramsText.isEmpty {
            let avail = width - padH - x
            if avail > 12 {
                let attr = NSAttributedString(string: s.paramsText, attributes: [
                    .font: theme.smallFont,
                    .foregroundColor: s.paramsDirty ? theme.paramsDirtyColor : theme.paramsColor,
                ])
                let natural = ceil(attr.size().width)
                if natural > avail {
                    // 先按 minimumScaleFactor 0.75 缩小（对齐 SwiftUI 版式），再不够就尾部省略
                    let fit = avail / natural
                    if fit >= 0.75 {
                        ctx.saveGState()
                        ctx.translateBy(x: x, y: row2Y)
                        ctx.scaleBy(x: fit, y: 1)
                        attr.draw(with: CGRect(x: 0, y: 0, width: avail / fit, height: row2H),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                        ctx.restoreGState()
                    } else {
                        let style = NSMutableParagraphStyle()
                        style.lineBreakMode = .byTruncatingTail
                        let trunc = NSAttributedString(string: s.paramsText, attributes: [
                            .font: theme.smallFont,
                            .foregroundColor: s.paramsDirty ? theme.paramsDirtyColor : theme.paramsColor,
                            .paragraphStyle: style,
                        ])
                        trunc.draw(with: CGRect(x: x, y: row2Y, width: avail, height: row2H),
                                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                    }
                } else {
                    attr.draw(with: CGRect(x: x, y: row2Y, width: natural, height: row2H),
                              options: [.usesLineFragmentOrigin])
                }
            }
        }

        return ctx.makeImage()
    }
}

/// 格子里的文字条：**贴一张后台烤好的小图**。
/// - 缓存命中 → 第一帧直接出图；
/// - 没命中 → 先空着（几毫秒），后台烤好写进本视图 `@State` → 自己重画。
/// ⚠️ 上屏只靠本视图 `@State`（别走任何"通知"——2026-09-27 的教训：格子收不到重算）。
struct BakedThumbText: View {
    let state: ThumbTextState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorTheme) private var colorTheme
    @State private var image: CGImage?

    /// 浅色界面用深色字，深色界面用浅色字（跟随系统，和别处的文字一样）
    private var plain: Bool { colorScheme == .light }

    private struct BakeKey: Hashable { let state: ThumbTextState; let plain: Bool; let theme: ColorTheme }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: state.width, alignment: .leading)
            } else {
                Color.clear
            }
        }
        .task(id: BakeKey(state: state, plain: plain, theme: colorTheme)) {
            let plain = plain
            image = nil
            if let hit = ThumbTextImageCache.cached(for: state, plain: plain) {
                image = hit
                return
            }
            let theme = ThumbTextThemeStore.theme(light: plain)
            let baked = await Task.detached(priority: .userInitiated) {
                ThumbTextRaster.render(state, theme: theme)
            }.value
            guard !Task.isCancelled, let baked else { return }
            ThumbTextImageCache.store(baked, for: state, plain: plain)
            image = baked
        }
    }
}

/// 方形底部的文字条（**实时 Text 版**，仅供诊断 A/B 用——正常路径走 `BakedThumbText`）。
/// 普通文字（颜色跟随界面深 / 浅）；版式与烤图版一致。
struct ThumbTextRows: View {
    let state: ThumbTextState

    private var statusColor: Color {
        switch state.statusColorTag {
        case 1: return Theme.accent
        case 2: return Theme.success
        case 3: return Theme.danger
        default: return Color.secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 名称 + N 版（名字在左、版数在右）
            HStack(spacing: 6) {
                Text(state.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(state.countText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // 状态行（圆点 + 文案 + 参数）
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(state.statusTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if state.showsParams {
                    Text(state.paramsText)
                        .font(.caption2)
                        .foregroundStyle(state.paramsDirty
                                         ? Color(nsColor: ThumbTextThemeStore.shared.paramsDirtyColor)
                                         : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 22)      // 顶部留白（原来是渐变过渡区；保持文字位置和烤图版一致）
        .padding(.bottom, 8)
        .frame(width: state.width, alignment: .leading)
    }
}
