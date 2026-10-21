import XCTest
import AppKit
@testable import Xipixiaojuchang

/// 缩略图底部文字条：2026-10-08 起**就是普通文字**——没有渐变底衬、没有阴影（用户："黑色渐变脏脏的"、"加了阴影反而看得不明显"），
/// 颜色跟随界面深 / 浅，和软件里别处的文字一样。
@MainActor
final class ThumbTextThemeTests: XCTestCase {
    private let state = ThumbTextState(title: "沈砚", countText: "3 版", statusTitle: "待生成", statusColorTag: 0,
                                       paramsText: "gpt-image · 2K", showsParams: true, paramsDirty: true, width: 160)

    /// 取图左下角那一个像素的 RGBA（把整张图缩进 1×1 太糊，所以只让左下角的 1×1 落进画布）
    private func cornerPixel(_ image: CGImage) -> (r: Int, g: Int, b: Int, a: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]), Int(data[3]))
    }

    func testNeitherThemeHasAScrimGradientOrAShadow() throws {
        for light in [false, true] {
            let image = try XCTUnwrap(ThumbTextRaster.render(state, theme: ThumbTextThemeStore.theme(light: light)))
            XCTAssertEqual(cornerPixel(image).a, 0, "light=\(light)：底部没有渐变底衬，角落（没有字的地方）是全透明的")
        }
    }

    /// 文字像别处的普通文字一样跟随界面：深色界面用浅色字、浅色界面用深色字
    func testTheTextFollowsTheInterfaceLikeAnyOtherText() {
        let dark = ThumbTextThemeStore.theme(light: false), light = ThumbTextThemeStore.theme(light: true)
        XCTAssertNotEqual(dark.titleColor, light.titleColor)
        func brightness(_ c: NSColor) -> CGFloat {
            let rgb = c.usingColorSpace(.sRGB) ?? c
            return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
        }
        XCTAssertGreaterThan(brightness(dark.titleColor), 0.8, "深色界面：浅色字")
        XCTAssertLessThan(brightness(light.titleColor), 0.3, "浅色界面：深色字")
        XCTAssertNotEqual(dark.titleColor, NSColor.white, "不是硬编码的纯白，是软件的主文字色")
        let primary = NSColor(hex: ColorThemeStore.shared.current.mode(dark: true).textPrimary)
        XCTAssertEqual(dark.titleColor, primary, "和软件里别处的主文字同一个颜色")
    }

    func testLightThemeHasNoScrimEither() throws {
        let image = try XCTUnwrap(ThumbTextRaster.render(state, theme: ThumbTextThemeStore.plainLight))
        XCTAssertEqual(cornerPixel(image).a, 0, "没有渐变，角落是全透明")
    }

    func testPlainTextIsDarkAndTheDirtyParamsUseAmber() {
        let plain = ThumbTextThemeStore.plainLight, normal = ThumbTextThemeStore.shared
        XCTAssertNotEqual(plain.titleColor, normal.titleColor)
        XCTAssertEqual(normal.paramsDirtyColor, NSColor(hex: 0xE9A23B), "改了参数没提交 = 琥珀，不再是系统亮黄")
        XCTAssertEqual(normal.dotColors.count, 4)
    }

    func testPlainAndNormalAreCachedSeparately() throws {
        let a = try XCTUnwrap(ThumbTextRaster.render(state, theme: ThumbTextThemeStore.shared))
        let b = try XCTUnwrap(ThumbTextRaster.render(state, theme: ThumbTextThemeStore.plainLight))
        var s = state; s.title = "缓存测试-\(UUID().uuidString)"
        ThumbTextImageCache.store(a, for: s, plain: false)
        XCTAssertNotNil(ThumbTextImageCache.cached(for: s, plain: false))
        XCTAssertNil(ThumbTextImageCache.cached(for: s, plain: true), "深色界面的缓存不会被浅色界面误用")
        ThumbTextImageCache.store(b, for: s, plain: true)
        XCTAssertNotNil(ThumbTextImageCache.cached(for: s, plain: true))
    }
}
