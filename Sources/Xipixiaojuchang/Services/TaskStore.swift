import Foundation
import Observation

@MainActor
@Observable
final class TaskStore {
    private(set) var tasks: [LocalTask] = []

    /// 任务有变化（新增 / 状态 / 路径）时通知 AppModel：P2 起任务记录存在各项目的视频版本里，
    /// 由 AppModel 存项目文件、并让任务中心放行排队中的视频。不再写 tasks.json。
    @ObservationIgnored var onChange: (() -> Void)?

    /// 启动时用项目文件还原出来的任务替换整个列表
    func replaceAll(_ tasks: [LocalTask]) {
        self.tasks = tasks
    }

    func add(_ task: LocalTask) {
        tasks.insert(task, at: 0)
        schedulePersist()
    }

    func task(id: String) -> LocalTask? {
        tasks.first { $0.id == id }
    }

    /// 同组任务（含自身），按创建时间升序
    func tasks(inGroupOf id: String) -> [LocalTask] {
        guard let anchor = task(id: id) else { return [] }
        return tasks.filter { $0.groupKey == anchor.groupKey }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func update(id: String, phase: TaskPhase, error: String? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        // 状态不变且无错误时跳过，避免轮询每 4 秒触发无谓刷新和写盘
        if tasks[index].phase == phase && error == nil { return }
        tasks[index].phase = phase
        tasks[index].updatedAt = Date()
        if let error { tasks[index].errorMessage = error }
        schedulePersist()
    }

    /// 更新进度（瞬态，不落盘，避免每 4 秒写一次磁盘）；进度不变则跳过
    func updateProgress(id: String, progress: Double?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].progressPercent != progress else { return }
        tasks[index].progressPercent = progress
        // 🎯 2026-10-01：进度变化也算"有活动" —— 否则 80 分钟超时兜底会把**长时间但一直在推进**的
        // 生成任务误判成超时（超时判的是 `updatedAt`）。
        tasks[index].updatedAt = Date()
    }

    /// 存住结果直链（下载失败后的自动重试 / 断点续传要用；不改变 phase）
    func updateResultURL(id: String, url: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].resultURL != url else { return }
        tasks[index].resultURL = url
        tasks[index].updatedAt = Date()
        schedulePersist()
    }

    /// 更新即梦排队位置（瞬态，不落盘）；位置不变则跳过
    func updateQueuePosition(id: String, position: Int?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].queuePosition != position else { return }
        tasks[index].queuePosition = position
    }

    func attachVideo(id: String, localPath: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].localVideoPath = localPath
        tasks[index].errorMessage = nil
        tasks[index].updatedAt = Date()
        schedulePersist()
    }

    /// 视频文件搬进项目文件夹后只改路径（不动时间和错误信息）
    func relocateVideos(_ paths: [String: String]) {
        var changed = false
        for i in tasks.indices {
            if let old = tasks[i].localVideoPath, let new = paths[old], new != old {
                tasks[i].localVideoPath = new
                changed = true
            }
        }
        if changed { schedulePersist() }
    }

    func remove(id: String) {
        tasks.removeAll { $0.id == id }
        schedulePersist()
    }

    func removeAll() {
        tasks.removeAll()
        schedulePersist()
    }

    /// 删除整组分镜（项目）的所有任务
    func removeGroup(groupKey: String) {
        tasks.removeAll { $0.groupKey == groupKey }
        schedulePersist()
    }

    /// 兼容旧调用点：任务记录已随项目文件保存（见 `onChange`），这里不用再做什么。
    func flush() {}

    private func schedulePersist() {
        onChange?()
    }
}
