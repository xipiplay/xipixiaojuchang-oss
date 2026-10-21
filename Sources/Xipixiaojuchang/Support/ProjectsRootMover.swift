import Foundation

/// 更换「项目文件夹」（设置 → 缓存）：把现有项目一个个搬到新位置（2026-10-10 用户：设置里只有「打开」，没法更换文件夹）。
///
/// 项目文件夹的根目录是 `<根>/<项目 ID>/project.json + images / videos / imports`（见 `ProjectStore`）。
/// 这里只管**搬文件夹**：先查好新位置能不能用，再一个个 `moveItem`（同一块盘上是改名、瞬间完成；跨盘是拷贝再删，会慢一点）；
/// 中途哪个失败，已经搬过去的搬回来，原样不动。搬完之后记下新路径、重启软件，由 AppModel 负责。
enum ProjectsRootMover {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 根目录下的项目文件夹（里面有 `project.json` 的子文件夹；点开头的、散放的文件不算）
    static func projectFolders(in root: URL) -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { name -> URL? in
            guard !name.hasPrefix(".") else { return nil }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            return fm.fileExists(atPath: folder.appendingPathComponent(ProjectDocument.fileName).path) ? folder : nil
        }
    }

    /// 新位置能不能用：不能和现在的一样、不能在现在的项目文件夹里面、要能写
    static func validate(old: URL, new: URL) throws {
        let oldPath = old.standardizedFileURL.path
        let newPath = new.standardizedFileURL.path
        guard oldPath != newPath else { throw Failure(message: "这就是现在的项目文件夹，换一个别的位置。") }
        guard !newPath.hasPrefix(oldPath + "/") else { throw Failure(message: "新位置不能在现在的项目文件夹里面，换一个别的位置。") }
        let fm = FileManager.default
        do { try fm.createDirectory(at: new, withIntermediateDirectories: true) }
        catch { throw Failure(message: "没法在这里建文件夹：\(error.localizedDescription)") }
        guard fm.isWritableFile(atPath: new.path) else { throw Failure(message: "这个位置没有写入权限，换一个别的位置。") }
    }

    /// 把 `old` 下的项目文件夹都搬进 `new`。返回搬了几个。`progress(已搬, 总数)` 每搬完一个调一次（在调用的线程上）。
    /// `moveItem` 只给测试换：模拟中途失败。
    @discardableResult
    static func move(from old: URL, to new: URL,
                     moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                     progress: (Int, Int) -> Void = { _, _ in }) throws -> Int {
        let fm = FileManager.default
        let folders = projectFolders(in: old)
        // 新位置里已经有同名项目：一个都不动，免得合并出一团乱
        let clashes = folders.filter { fm.fileExists(atPath: new.appendingPathComponent($0.lastPathComponent).path) }
        guard clashes.isEmpty else {
            throw Failure(message: "新位置里已经有同名的项目文件夹（\(clashes.prefix(3).map(\.lastPathComponent).joined(separator: "、"))\(clashes.count > 3 ? " 等 \(clashes.count) 个" : "")），没有移动。")
        }
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        var moved: [(from: URL, to: URL)] = []
        progress(0, folders.count)
        for folder in folders {
            let target = new.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            do {
                try moveItem(folder, target)
            } catch {
                // 已经搬过去的搬回来；这一个可能搬了一半，也清掉新位置里残留的
                if fm.fileExists(atPath: target.path), fm.fileExists(atPath: folder.path) {
                    try? fm.removeItem(at: target)       // 原处还在、新位置也有一份 = 搬到一半（跨盘拷贝中断），新位置那份是残片
                }
                for item in moved.reversed() { try? moveItem(item.to, item.from) }
                throw Failure(message: "移动「\(folder.lastPathComponent)」失败：\(error.localizedDescription)。已经恢复原样。")
            }
            moved.append((folder, target))
            progress(moved.count, folders.count)
        }
        return moved.count
    }
}
