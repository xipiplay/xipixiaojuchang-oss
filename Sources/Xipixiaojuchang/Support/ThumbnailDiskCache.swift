import Foundation

/// 缩略图的磁盘缓存（`appSupport/Thumbs`）只增不减：用户机器上已经 600MB / 近 3000 个文件（2026-10-10 查出来的）。
/// 缩略图丢了会按需重新生成，所以超过上限就从最旧的开始删，删到目标大小。启动后在后台跑一次。
enum ThumbnailDiskCache {
    static let limitBytes: Int64 = 400 * 1024 * 1024
    static let targetBytes: Int64 = 300 * 1024 * 1024

    static var directory: URL { FileLocations.appSupport.appendingPathComponent("Thumbs", isDirectory: true) }

    /// 返回删了几个文件。文件不是缩略图（子文件夹、点开头的）不碰
    @discardableResult
    static func trim(directory: URL = directory, limit: Int64 = limitBytes, target: Int64 = targetBytes) -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return 0 }
        var files: [(url: URL, size: Int64, date: Date)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return 0 }
        var removed = 0
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > target else { break }
            if (try? fm.removeItem(at: file.url)) != nil {
                total -= file.size
                removed += 1
            }
        }
        AppLog.write("thumbs", "缩略图缓存超过上限，删掉最旧的 \(removed) 个，现在约 \(total / 1024 / 1024) MB")
        return removed
    }

    /// 启动后过一会儿在后台跑一次（别和启动抢磁盘）
    static func trimInBackground() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { trim() }
    }
}
