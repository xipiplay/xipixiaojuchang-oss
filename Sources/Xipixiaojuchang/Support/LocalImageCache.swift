import Foundation
import AppKit
import ImageIO
import CryptoKit

extension NSImage {
    /// 从压缩数据**立即解码成位图**（请在后台线程调用）。
    ///
    /// ⚠️ **为什么必须有它** —— 这是个很隐蔽的性能坑：
    /// `NSImage(data:)` / `NSImage(contentsOfFile:)` 都是**懒解码** ✗：它们只把压缩数据包起来，
    /// 真正的解码拖到**第一次画到屏幕上**那一刻。对滚动列表的后果是：// 卡片滚进视野、
    /// 第一次绘制缩略图时**在主线程解码** ✗✓
    ///
    /// **用户 2026-09-12 的描述正是这个现象**："刚切到这个页面后，第一次滑到下一张卡片
    ///（有缩略图）要出来的时候会卡一下；这个页面滑完一遍后，再来回滑就几乎不卡了" ✓
    /// —— 一次性成本 + 之后被缓存，这就是懒解码的指纹。
    ///
    /// 更坑的是：懒图一旦被存进内存缓存（`LocalImageCache.thumbs`）✗，之后每次查找都"命中" ✓、
    /// 却始终没解码 ✓ —— 直到绘制那一刻才在**主线程**付这笔账 ✗。
    ///
    /// `kCGImageSourceShouldCacheImmediately` 让它**当场解掉** ✓，缓存里存的就是解码好的位图，
    /// 绘制时只剩一次拷贝 ✓
    nonisolated static func decoded(from data: Data) -> NSImage? {
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, opts),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, opts) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// 图片内存缓存（**NSCache**：自动响应系统内存压力 + 内部线程安全）——2026-09-27 从普通字典升级。
/// 成本按**解码后字节数**（像素宽高 × 4）算，`totalCostLimit` 才有意义（不能按文件大小）。
/// 下标读写与字典一致（`cache[path] = img` / `cache[path] = nil` 清一项），调用点不用改。
final class ImageMemoryCache: @unchecked Sendable {
    private let cache: NSCache<NSString, NSImage>

    init(countLimit: Int, totalCostLimit: Int) {
        cache = NSCache<NSString, NSImage>()
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    /// 解码后字节数：取最大的一层表示（原图/预览用得上）
    static func cost(of image: NSImage) -> Int {
        let rep = image.representations.max { a, b in
            a.pixelsWide * a.pixelsHigh < b.pixelsWide * b.pixelsHigh
        }
        let w = rep?.pixelsWide ?? Int(image.size.width)
        let h = rep?.pixelsHigh ?? Int(image.size.height)
        return max(1, w * h * 4)
    }

    subscript(key: String) -> NSImage? {
        get { cache.object(forKey: key as NSString) }
        set {
            if let newValue {
                cache.setObject(newValue, forKey: key as NSString, cost: Self.cost(of: newValue))
            } else {
                cache.removeObject(forKey: key as NSString)
            }
        }
    }

    func removeAll() { cache.removeAllObjects() }
}

/// 本地图片缩略图缓存：
/// 滚动重建卡片时会反复加载素材/结果大图，主线程 `NSImage(contentsOfFile:)` 全量解码会卡；
/// 一律用 CGImageSource 降采样成小缩略图（ImageIO 边解码边缩放，快且省内存），后台生成、主线程只读缓存。
@MainActor
enum LocalImageCache {
    /// 小缩略图内存缓存（path → 降采样后的 NSImage）
    /// 上限：600 张 / 256MB（解码后字节，640px 缩略图 ≈ 0.9~1.6MB/张）。
    /// 🧪 实验 4（2026-09-27）：192→256MB，让 300 张压测的工作集全放得下 —— 缓存一旦被挤爆，
    /// 每次滚回来都要重新读盘+解码（"闪一下"的来源）。
    /// NSCache 会在系统内存吃紧时自动驱逐（2026-09-27）。⚠️ 与视频首帧缓存**各自独立设限额**
    ///（`VideoThumbnailCache.images` 也是自己的实例）——两边的"单位成本"不一样，别共用一个数。
    private static let thumbs = ImageMemoryCache(countLimit: 600, totalCostLimit: 256 * 1024 * 1024)
    /// 全尺寸原图内存缓存（仅预览大图用）：张数少、单张可能很大 → 靠字节上限（2026-09-27）
    private static let imagesFull = ImageMemoryCache(countLimit: 16, totalCostLimit: 160 * 1024 * 1024)
    /// 加载任务去重（同一 path 只跑一个后台任务）
    private static var loading: Set<String> = []
    /// **同一 path 的等待队列**：已有加载在跑时，后来的调用方挂这里，加载完**一起回调**。
    ///
    /// ⚠️ 2026-09-19 修：原来"已在加载"直接 `return`（**不回调**）—— 而卡片视图和详情视图是
    /// **常驻**的（靠 opacity 切换，两棵树的 `.task` 都在跑），两边会为同一张图同时请求缩略图；
    /// 抢输的那个**永远收不到回调** ✗ —— 用户实测："生图详情视图里的缩略图没图，刚生成完也没有"。
    private static var waiters: [String: [@MainActor (NSImage?) -> Void]] = [:]

    /// 缩略图最大像素（512 → **640**，2026-09-27 实验 2）：格子 2x 下约 600px，
    /// 512 会在滚动时每帧做放大重采样 ✗；对齐显示尺寸后由绘制管线直接 1:1 贴。
    private nonisolated static let maxThumbPixel = 640

    /// 磁盘缩略图目录（含降采样小图，后台写入）。
    /// 文件名用完整路径的 SHA256：不同项目里可能有同名文件，用文件名做 key 会跨项目撞车、互相覆盖缩略图。
    private nonisolated static func thumbURL(for path: String) -> URL {
        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ".thumb.png"
        return FileLocations.appSupport.appendingPathComponent("Thumbs", isDirectory: true).appendingPathComponent(name)
    }

    /// **只查内存**（纯字典查表，主线程可放心调）。
    ///
    /// ⚠️ 视图的"快速路径"必须用它，**不要用 `image(atPath:)`** ✗ —— 那个会同步读盘 + 解码，
    /// 而它是在主线程调的 ✗（卡片第一次滚进视野时，这几十毫秒就卡在帧里 ——
    /// 用户 2026-09-12 的原话："第一次滑到下一张卡片（有缩略图）要出来的时候，会卡一下"）
    static func memoryThumb(atPath path: String) -> NSImage? { thumbs[path] }

    /// 同步取小缩略图：先查内存，再查磁盘缓存；都没有返回 nil（由视图端异步补齐）。
    /// 这里绝不 `NSImage(contentsOfFile:)` 解码原图，避免主线程卡顿。
    ///
    /// ⚠️ **这条路上有同步读盘 + 解码，只适合在后台或非热点路径调** ✗
    ///（视图里的热点路径请用 `memoryThumb` + `loadThumbnail` ✓）
    ///
    /// ⚠️ 磁盘那一路必须用 `NSImage.decoded(from:)`（**当场解码**），不能用 `NSImage(data:)` ✗ ——
    /// 后者是懒解码，会把这个"没解码的图"存进内存缓存 ✗，于是**每一次查找都命中、却始终没解码** ✓，
    /// 直到第一次绘制时才在**主线程**解 ✗
    static func image(atPath path: String) -> NSImage? {
        if let thumb = thumbs[path] { return thumb }
        if let data = try? Data(contentsOf: thumbURL(for: path)),
           let img = NSImage.decoded(from: data) {
            thumbs[path] = img
            return img
        }
        return nil
    }

    static func image(at url: URL) -> NSImage? {
        image(atPath: url.path)
    }

    /// 限流信号量：同一时刻最多 4 个缩略图在后台生成（ImageIO 解码大图很吃 CPU，无限并发会让快速滚动时 CPU 飙升）
    private nonisolated static let thumbSemaphore = DispatchSemaphore(value: 4)

    /// 异步加载小缩略图：命中缓存立即回调；未命中在后台降采样生成（主线程回调）。
    /// 提示词「图N」附件、素材 chip、生图缩略图、素材库都用它，滚动重建不再解码大图。
    static func loadThumbnail(atPath path: String, completion: @escaping @MainActor (NSImage?) -> Void) {
        // ⚠️ 这里只查**内存** ✗ 不能调 `image(atPath:)` —— 那会在主线程同步读盘 + 解码 ✗
        //（这条函数是从视图的 `onAppear` 调过来的，跑在主线程 ✓）
        if let cached = thumbs[path] {
            completion(cached)
            return
        }
        if loading.contains(path) {
            // 已有同一 path 在加载 → **排队等它**（不能直接 return：调用方会永远收不到回调，
            // 详见 `waiters` 的注释）
            waiters[path, default: []].append(completion)
            return
        }
        loading.insert(path)
        DispatchQueue.global(qos: .userInitiated).async {
            thumbSemaphore.wait()
            defer { thumbSemaphore.signal() }
            // ① 先试**磁盘缩略图缓存**（后台读盘 + 当场解码 ✓ —— 这一步以前在主线程做 ✗）
            var thumb: NSImage? = nil
            if let data = try? Data(contentsOf: Self.thumbURL(for: path)) {
                thumb = NSImage.decoded(from: data)
            }
            // ② 磁盘也没有，才降采样生成（同样在后台 ✓）
            if thumb == nil {
                thumb = Self.generateThumbnail(path: path, maxPixel: maxThumbPixel)
            }
            DispatchQueue.main.async {
                loading.remove(path)
                if let thumb {
                    thumbs[path] = thumb
                    completion(thumb)
                } else {
                    completion(nil)
                }
                // 等这一张图的其它调用方（常驻的另一个视图）也回调一次
                let queued = waiters.removeValue(forKey: path) ?? []
                for waiter in queued { waiter(thumb) }
            }
        }
    }

    /// 🧪 实验 10 同款（生图侧同步）：async + **取消感知**的缩略图加载。
    /// 与 `loadThumbnail` 的差异：不走 `waiters`（每个格子只要自己的结果）、可取消（滚走就不白干）、
    /// **不限流**（与视频侧一致——用户实测不限流更顺；⚠️ `DispatchSemaphore` 在 async 里被禁，
    /// 真要限流得换 async 闸门）。
    nonisolated static func loadThumbImage(atPath path: String) async -> NSImage? {
        if Task.isCancelled { return nil }
        // ① 磁盘缩略图缓存（后台读盘 + 当场解码）
        if let data = try? Data(contentsOf: Self.thumbURL(for: path)) {
            return NSImage.decoded(from: data)
        }
        // ② 磁盘没有 → 降采样生成（同样在后台）
        return Self.generateThumbnail(path: path, maxPixel: maxThumbPixel)
    }

    /// 收下 `loadThumbImage` 的结果，存回内存缓存（调用方在主线程）
    static func storeThumb(_ img: NSImage, atPath path: String) {
        thumbs[path] = img
    }

    static func loadThumbnail(at url: URL, completion: @escaping @MainActor (NSImage?) -> Void) {
        loadThumbnail(atPath: url.path, completion: completion)
    }

    /// 同步入口兼容：接收 Completion 的异步调用（旧签名），内部转发到 loadThumbnail
    static func image(at url: URL, completion: @escaping @MainActor (NSImage?) -> Void) {
        loadThumbnail(at: url, completion: completion)
    }

    /// 异步加载全尺寸原图（预览大图用）：命中缓存立即回调，未命中后台解码原图（主线程回调）。
    /// 注意：仅在「查看大图」等明确需要全尺寸的地方用，缩略图场景不要用它。
    static func loadFull(atPath path: String, completion: @escaping @MainActor (NSImage?) -> Void) {
        if let cached = imagesFull[path] {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // ⚠️ 这里是**唯一**故意保留懒解码的地方：全尺寸原图当场解码会多占一份内存 ✗，
            // 而它只服务"查看大图"（一次性、不在滚动路径上）✓ 所以让它按需解码即可 ✓
            // 缩略图路径**不要**照抄这里 —— 那边必须用 `NSImage.decoded(from:)` ✗
            let img = NSImage(contentsOfFile: path)
            DispatchQueue.main.async {
                if let img { imagesFull[path] = img }
                completion(img)
            }
        }
    }

    static func loadFull(at url: URL, completion: @escaping @MainActor (NSImage?) -> Void) {
        loadFull(atPath: url.path, completion: completion)
    }

    /// 后台降采样：CGImageSource 边解码边缩到 maxPixel，返回 NSImage；失败返回 nil
    nonisolated private static func generateThumbnail(path: String, maxPixel: Int) -> NSImage? {
        // 本地路径一律用 fileURLWithPath（URL(string:) 对绝对路径解析出的不是本地文件）
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        // 写磁盘缓存（后台线程，避免主线程编码 PNG）
        let scaledURL = thumbURL(for: path)
        try? FileManager.default.createDirectory(at: scaledURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let dest = CGImageDestinationCreateWithURL(scaledURL as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cgImage, nil)
            CGImageDestinationFinalize(dest)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// 预热：某个素材文件生成缩略图并进缓存（后台），供滚动时直接命中
    static func warm(path: String) {
        loadThumbnail(atPath: path) { _ in }
    }

    // MARK: - 远程缩略图（本地文件已丢失时的兜底）

    /// 远程缩略图内存缓存（URL → 图）
    /// 远程缩略图缓存（URL key）：上限 200 张 / 48MB（2026-09-27 NSCache）
    private static let remoteThumbs = ImageMemoryCache(countLimit: 200, totalCostLimit: 48 * 1024 * 1024)
    /// 远程加载去重（同一 URL 只跑一个请求）
    private static var remoteLoading: Set<String> = []

    /// 异步加载**远程**缩略图（素材直链）。
    ///
    /// ⚠️ 为什么必须有它：`SlotItem.thumbnailURL` 现在**只在本地文件真的存在时才非空**
    ///（见 `LibraryItem.existingLocalImageURL`），而实测素材库 131 张图里 **48 张**的本地文件
    /// 已被移走/删除。只走本地缓存的话，这些素材**永远拿不到缩略图** ——
    /// 表现为"提示词区 @ 了素材、保存后鼠标移过去不弹放大预览"（用户 2026-09-12 实测，
    /// 而且因为有的素材本地还在、有的不在，看着像"个例"）。
    ///
    /// 与 `loadThumbnail(atPath:)` 的区别：这是网络请求，失败静默返回 nil
    ///（调用方只是不弹浮窗，不报错）。缩略图场景用它，别用 `loadFull`。
    static func loadRemoteThumbnail(at url: URL, completion: @escaping @MainActor (NSImage?) -> Void) {
        let key = url.absoluteString
        if let cached = remoteThumbs[key] {
            completion(cached)
            return
        }
        guard !remoteLoading.contains(key) else { return }
        remoteLoading.insert(key)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            // ⚠️ **解码在后台线程**（URLSession callback）：`NSImage.decoded` 内部走
            // `CGImageSourceCreateImageAtIndexEx` → PNGReadPlugin 解码，耗时 200~400ms。
            // 原来放在 `DispatchQueue.main.async` 里，直接阻塞主线程 → 卡顿（stall sample 实锤）。
            // 解码好的位图是 Sendable（CGImage 底层是 Core Foundation 对象），传到主线程安全。
            let img = data.flatMap { NSImage.decoded(from: $0) }
            DispatchQueue.main.async {
                remoteLoading.remove(key)
                guard let img else {
                    completion(nil)
                    return
                }
                remoteThumbs[key] = img
                completion(img)
            }
        }.resume()
    }
}
