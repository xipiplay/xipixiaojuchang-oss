import Foundation

enum FileLocations {
    private static let videosDirKey = "videosDirectoryPath"

    static let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("XipixiaojuchangOpen", isDirectory: true)

    static var tasksFile: URL { appSupport.appendingPathComponent("tasks.json") }
    static var shotsFile: URL { appSupport.appendingPathComponent("shots.json") }
    static var libraryFile: URL { appSupport.appendingPathComponent("library.json") }
    static var imageItemsFile: URL { appSupport.appendingPathComponent("imageItems.json") }
    /// 任务中心：排队中的视频与剧本 AI 任务记录（2026-10-06 P2）
    static var jobsFile: URL { appSupport.appendingPathComponent("jobs.json") }
    static var logFile: URL { appSupport.appendingPathComponent("app.log") }

    /// 视频缓存目录：优先用户自定义，否则默认 appSupport/Videos
    static var videosDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: videosDirKey), !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return appSupport.appendingPathComponent("Videos", isDirectory: true)
    }

    static func setVideosDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: videosDirKey)
    }

    static func resetVideosDirectory() {
        UserDefaults.standard.removeObject(forKey: videosDirKey)
    }

    // MARK: 项目文件夹（2.0：<根目录>/<项目ID>/images、videos、imports）

    /// 项目文件夹的根目录：迁移时记下的路径；还没迁移过（新装）就用「缓存目录/项目」。
    /// 之后改「缓存目录」设置不会搬动它。
    static var projectsRoot: URL {
        ProjectStore.recordedRoot ?? videosDirectory.appendingPathComponent("项目", isDirectory: true)
    }

    /// 某项目的文件夹（按项目 ID，改名不动目录、重名互不干扰）
    static func projectFolder(_ projectKey: String) -> URL {
        projectsRoot.appendingPathComponent(projectKey, isDirectory: true)
    }

    /// 某项目的图片目录
    static func projectImagesDirectory(_ projectKey: String) -> URL {
        projectFolder(projectKey).appendingPathComponent(ProjectDocument.imagesFolder, isDirectory: true)
    }

    /// 某项目的视频目录
    static func projectVideosDirectory(_ projectKey: String) -> URL {
        projectFolder(projectKey).appendingPathComponent(ProjectDocument.videosFolder, isDirectory: true)
    }

    // MARK: 剧本流水线存档目录（按项目划分：appSupport/ScriptPipelines/<projectKey>.json）

    static var scriptPipelinesDirectory: URL {
        appSupport.appendingPathComponent("ScriptPipelines", isDirectory: true)
    }

    static func scriptPipelineFile(for projectKey: String) -> URL {
        scriptPipelinesDirectory.appendingPathComponent("\(projectKey).json")
    }

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scriptPipelinesDirectory, withIntermediateDirectories: true)
    }
}
