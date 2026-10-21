import Foundation

// MARK: - 制作页的写操作（2026-10-07 P3-2 第 1 步：改提示词 / 选版本 / 提交视频）
//
// 数据仍然只有一份（AppModel 里的旧数组 + 剧本存档），这里只是把旧「推理分镜」页那几个私有方法
// （`savePrompt` / `submit` / `setCurrentVersion`）做成制作页也能调的版本，做法保持一致：
// - 改提示词：剧本段同时改存档里的段（并清掉承接站位的指纹，下次推理重算）和分镜卡；自由集只改分镜卡。
// - 提交：没有分镜卡就按段建一张（编号 = 集号-段号），把本段用到的素材图挂成参考图，再走 `submitShot`。
// - 选版本：只把「当前版本」指过去，不动提示词和参数（旧「显示当前」的语义）。
// 页面靠 `AppModel.dataRevision` 自动刷新。

@MainActor
enum WorkbenchActions {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: 参数

    /// 还没有分镜卡的段，提交时用的默认参数（设置里配的默认模型 / 分辨率 / 画幅；时长 30 秒，和旧推理分镜页一致）
    static func defaultParams(_ app: AppModel) -> VideoParams {
        VideoParams(model: app.defaultVideoModel ?? app.videoModelNames.first ?? "", providerID: "", duration: 30,
                    aspectRatio: app.defaultVideoAspect.flatMap(AspectRatio.init(rawValue:)) ?? .ratio16x9,
                    resolution: app.defaultVideoResolution.flatMap(Resolution.init(rawValue:)) ?? .p720,
                    generateAudio: app.generateAudioDefault, watermark: app.watermarkDefault)
    }

    /// 这一段现在生效的参数：有分镜卡用卡上的，没有就用默认
    static func effectiveParams(for segment: SegmentRecord, app: AppModel) -> VideoParams {
        segment.legacy?.shotID != nil ? segment.params : defaultParams(app)
    }

    // MARK: 改提示词

    static func savePrompt(_ text: String, segment: SegmentRecord, episode: EpisodeRecord, app: AppModel) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("提示词不能为空") }
        guard let key = app.currentProjectKey else { throw Failure("没有打开项目") }
        let shotID = segment.legacy?.shotID
        if !episode.isFree {
            guard var archive = app.pipelineArchive(for: key),
                  let e = archive.episodes.firstIndex(where: { $0.id == episode.id }) else { throw Failure("找不到这一集") }
            var work = SimplePipeline.work(in: archive, index: e)
            guard let i = work.segments.firstIndex(where: { $0.id == segment.id }) else { throw Failure("找不到这一段") }
            work.segments[i].prompt = text
            work.segments[i].continuityKey = ""
            if let shotID { work.segments[i].shotID = shotID }
            SimplePipeline.save(work, to: &archive)
            app.savePipelineArchive(archive, for: key)
        }
        if let shotID { app.updateShotPrompt(shotID, prompt: text) }
    }

    // MARK: 选版本

    /// 让某一版进成片。只对成功的版本有意义（调用方已限制）
    static func selectVersion(taskID: String, segment: SegmentRecord, app: AppModel) {
        guard let shotID = segment.legacy?.shotID else { return }
        app.setCurrentVersion(shotID: shotID, taskID: taskID)
    }

    // MARK: 提交视频

    /// 按段落现在的内容准备要提交的分镜卡（纯函数）。
    /// 素材引用不在这里挂：引用和提示词里的「图N」是一起的，由 `WorkbenchMatching` 负责。
    static func preparedShot(existing: ShotDraft?, projectKey: String, episodeNumber: Int, segmentNumber: Int,
                             prompt: String, params: VideoParams, generateAudio: Bool, watermark: Bool) -> ShotDraft {
        var shot = existing ?? ShotDraft(projectKey: projectKey, prompt: prompt, duration: params.duration,
                                         generateAudio: generateAudio, watermark: watermark,
                                         numbering: ShotNumbering(a: episodeNumber, b: segmentNumber))
        shot.prompt = prompt
        shot.model = params.model
        if let resolution = params.resolution { shot.resolution = resolution }
        shot.aspectRatio = params.aspectRatio
        shot.duration = params.duration
        return shot
    }

    static func submit(segment: SegmentRecord, episode: EpisodeRecord, params: VideoParams, app: AppModel) throws {
        guard let key = app.currentProjectKey else { throw Failure("没有打开项目") }
        guard WorkbenchRules.hasPrompt(segment) else { throw Failure("请先填写分镜提示词") }
        guard app.videoModelNames.contains(params.model) else {
            throw Failure("请先选择可用的视频模型（到设置里添加渠道与模型）")
        }

        var segmentIndex = 0
        var episodeNumber = 1
        if !episode.isFree {
            guard let loaded = app.pipelineArchive(for: key),
                  let e = loaded.episodes.firstIndex(where: { $0.id == episode.id }) else { throw Failure("找不到这一集") }
            let w = SimplePipeline.work(in: loaded, index: e)
            guard let i = w.segments.firstIndex(where: { $0.id == segment.id }) else { throw Failure("找不到这一段") }
            segmentIndex = i; episodeNumber = e + 1
            // 提交前把素材和提示词里的「图N」对上（已经对过的是空操作）；提示词以对完的为准
            try WorkbenchMatching.prepare(segmentID: segment.id, episodeID: episode.id, doc: nil, app: app)
        }

        let existing = segment.legacy?.shotID.flatMap { id in app.shots.first { $0.id == id && $0.projectKey == key } }
            ?? (episode.isFree ? nil : pipelineShot(episodeID: episode.id, segmentID: segment.id, project: key, app: app))
        let shot = preparedShot(
            existing: existing, projectKey: key, episodeNumber: episodeNumber, segmentNumber: segmentIndex + 1,
            prompt: existing?.prompt ?? segment.prompt, params: params,
            generateAudio: app.generateAudioDefault, watermark: app.watermarkDefault)
        let issues = ShotValidator.validate(shot)
        guard issues.isEmpty else { throw Failure(issues.joined(separator: "\n")) }

        if let i = app.shots.firstIndex(where: { $0.id == shot.id }) { app.shots[i] = shot } else { app.shots.append(shot) }
        app.persistShots()
        if !episode.isFree, var archive = app.pipelineArchive(for: key),
           let e = archive.episodes.firstIndex(where: { $0.id == episode.id }) {
            var work = SimplePipeline.work(in: archive, index: e)
            if let i = work.segments.firstIndex(where: { $0.id == segment.id }) {
                work.segments[i].shotID = shot.id
                work.segments[i].prompt = shot.prompt
                SimplePipeline.save(work, to: &archive)
                app.savePipelineArchive(archive, for: key)
            }
        }
        app.submitShot(shot.id)
    }

    /// 剧本段在剧本存档里记的分镜卡（制作页的段落记录里没有时的兜底）
    private static func pipelineShot(episodeID: UUID, segmentID: UUID, project key: String, app: AppModel) -> ShotDraft? {
        guard let archive = app.pipelineArchive(for: key), let e = archive.episodes.firstIndex(where: { $0.id == episodeID }),
              let id = SimplePipeline.work(in: archive, index: e).segments.first(where: { $0.id == segmentID })?.shotID else { return nil }
        return app.shots.first { $0.id == id && $0.projectKey == key }
    }
}
