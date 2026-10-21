import SwiftUI

/// 媒体页只在实际访问时绑定项目。回主页 / 看工作台时保留上次的页面身份与模式，
/// 避免隐藏的页面跟着 currentProjectKey 归零、预绑另一个项目而重建。
@MainActor
final class MediaWorkspacePresentation {
    struct State: Equatable {
        let id = UUID()
        let projectKey: String
        var mode: AppModel.WorkspaceMode
        var hasImages = false
        var hasVideo = false
    }

    private(set) var state: State?
    private var needsNewSession = false

    func didLeaveProject() { needsNewSession = true }

    func resolve(projectKey: String?, visible: Bool, mode: AppModel.WorkspaceMode) -> State? {
        guard visible, let projectKey else { return state }
        var next: State
        if let previous = state, previous.projectKey == projectKey, !needsNewSession {
            next = previous
        } else {
            next = State(projectKey: projectKey, mode: mode)
        }
        needsNewSession = false
        next.mode = mode
        if mode == .image { next.hasImages = true } else { next.hasVideo = true }
        state = next
        return next
    }
}

struct MediaWorkspaceContext: Equatable {
    let projectKey: String
    let mode: AppModel.WorkspaceMode
    let active: Bool

    func isActive(_ page: AppModel.WorkspaceMode) -> Bool { active && mode == page }
}

private struct MediaWorkspaceContextKey: EnvironmentKey {
    static let defaultValue: MediaWorkspaceContext? = nil
}

extension EnvironmentValues {
    /// nil = 独立使用的视图（测试、工作台编辑器等），照常读取实时数据。
    var mediaWorkspaceContext: MediaWorkspaceContext? {
        get { self[MediaWorkspaceContextKey.self] }
        set { self[MediaWorkspaceContextKey.self] = newValue }
    }
}

/// 与工作台 InputCache 相同：写缓存不触发观察；隐藏时连实时输入都不读，
/// 解除对项目换绑、后台任务等数据的观察。重新显示时自然补上最新值。
final class MediaWorkspaceInput<Value> {
    private var cached: Value?

    func value(active: Bool, live: () -> Value) -> Value {
        if !active, let cached { return cached }
        let value = live()
        cached = value
        return value
    }
}
