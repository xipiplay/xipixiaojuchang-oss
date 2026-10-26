import Foundation

/// 角色音色跟着角色图进分镜（2026-10-26 用户：音色和参考图绑在一起，第 2 步）。
///
/// 分镜挂着某张角色卡的图、这张卡有音色（`CardVoice.resolve`）时：
/// - 音频音色：把那段音频挂进分镜的音频素材，提示词里写「音频N是周承山的音色」；
/// - 文本音色：不挂文件，写「周承山的音色：低沉沙哑……」。
/// 这些写在头行下面单独一行「【音色】…」，每次整行重写（幂等；用户删了这行字，下次匹配补回来，同「图N」的规矩）。
/// 不再需要的音色音频（换了版本 / 解绑了）从素材区摘掉，提示词里的「音频N」跟着重新编号。
/// 挂不上的（渠道不收参考音频、分镜关了「生成音频」、音频已经 3 段）不挂，记下原因给段落详情显示，不悄悄丢。
@MainActor
enum ShotVoiceSync {
    static let tag = "【音色】"
    /// 一条分镜最多带几段参考音频（Seedance 系上限 3 段）
    static let maxAudios = 3

    struct Voice: Equatable {
        /// 头行里的名字（卡的基础名）
        let name: String
        let resolved: CardVoice.Resolved
    }

    struct Plan: Equatable {
        var prompt: String
        var audioRefs: [MaterialRef]
        /// 没挂上的：「周承山：渠道不收参考音频」
        var skipped: [String]
    }

    /// 为什么挂不了新的音色音频；nil = 能挂
    static func audioBlocker(generateAudio: Bool, channelFormat: ChannelProtocol?) -> String? {
        if !generateAudio { return "这一段关了「生成音频」" }
        // 开源版只有 OpenAI / New API 两种渠道，都不收参考音频：音频音色挂不上（文本音色照写）
        if let format = channelFormat, [ChannelProtocol.openAI, .newAPI].contains(format) { return "这个模型的渠道不收参考音频" }
        return nil
    }

    /// 算出同步后的提示词和音频素材。`voiceAudioIDs`：本项目所有卡绑着的音色音频（判断哪些已挂的音频是「音色」，不需要了要摘掉）
    static func plan(prompt original: String, audioRefs refs: [MaterialRef], voices: [Voice],
                     voiceAudioIDs: Set<UUID>, blocker: String?) -> Plan {
        var prompt = removingTagLine(original)
        var audioRefs = refs
        var skipped: [String] = []

        // 需要挂的音频（按角色顺序，同一段音频只挂一次）
        var needed: [UUID] = []
        for voice in voices {
            if case .audio(let item) = voice.resolved, !needed.contains(item.id) { needed.append(item.id) }
        }
        // 不再需要的音色音频：摘掉，后面的「音频N」前移
        for index in audioRefs.indices.reversed() {
            let id = audioRefs[index].libraryItemID
            guard voiceAudioIDs.contains(id), !needed.contains(id) else { continue }
            audioRefs.remove(at: index)
            prompt = AppModel.removeTokenAndRenumber(prompt, prefix: "音频", removedIndex: index + 1)
        }

        var parts: [String] = []
        for voice in voices {
            switch voice.resolved {
            case .text(let text):
                parts.append("\(voice.name)的音色：\(text.components(separatedBy: .newlines).joined(separator: " "))")
            case .audio(let item):
                if audioRefs.firstIndex(where: { $0.libraryItemID == item.id }) == nil {
                    if let blocker {
                        skipped.append("\(voice.name)：\(blocker)")
                        continue
                    }
                    guard audioRefs.count < maxAudios else {
                        skipped.append("\(voice.name)：参考音频已经 \(maxAudios) 段")
                        continue
                    }
                    audioRefs.append(MaterialRef(libraryItemID: item.id))
                }
                let n = audioRefs.firstIndex { $0.libraryItemID == item.id }! + 1
                if !parts.contains(where: { $0.hasPrefix("音频\(n)是") }) {
                    parts.append("音频\(n)是\(voice.name)的音色")
                }
            }
        }
        if !parts.isEmpty { prompt = insertingTagLine(tag + parts.joined(separator: "；"), into: prompt) }
        return Plan(prompt: prompt, audioRefs: audioRefs, skipped: skipped)
    }

    /// 去掉「【音色】」开头的行
    static func removingTagLine(_ prompt: String) -> String {
        let lines = prompt.components(separatedBy: "\n")
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(tag) }
        return kept.count == lines.count ? prompt : kept.joined(separator: "\n")
    }

    /// 放在头行（第一行有字的）下面
    static func insertingTagLine(_ line: String, into prompt: String) -> String {
        var lines = prompt.components(separatedBy: "\n")
        guard let head = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return line }
        lines.insert(line, at: head + 1)
        return lines.joined(separator: "\n")
    }
}

extension AppModel {
    /// 这条分镜挂着的角色图带上它们的音色（见 `ShotVoiceSync`）。`autoMatchMaterials` 每次都会调；没变化就什么都不写
    func syncShotVoices(_ shotID: UUID) {
        guard let shot = shots.first(where: { $0.id == shotID }) else { return }
        let context = VoiceSyncContext(app: self, projectKey: shot.projectKey)
        if syncShotVoices(shotID, context: context) {
            touchProject(shot.projectKey)
            persistShots()
        }
    }

    /// 一批分镜共用的查表（卡片、素材库、音色音频）：卡上改音色时要同步上百条分镜，别每条都重新整理一遍（2026-10-26 用户：切音色卡）
    struct VoiceSyncContext {
        let cardsByID: [UUID: ImageGenItem]
        let library: [UUID: LibraryItem]
        let voiceAudioIDs: Set<UUID>

        @MainActor
        init(app: AppModel, projectKey: String) {
            let projectCards = app.imageItems.filter { $0.projectKey == projectKey }
            cardsByID = Dictionary(projectCards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            library = Dictionary(app.library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            voiceAudioIDs = Set(projectCards.compactMap(\.voiceAudioID))
        }
    }

    /// 同步一条分镜；改了返回 true（调用方负责存盘）
    @discardableResult
    func syncShotVoices(_ shotID: UUID, context: VoiceSyncContext) -> Bool {
        guard let idx = shots.firstIndex(where: { $0.id == shotID }) else { return false }
        let shot = shots[idx]
        let lookup = { (id: UUID) in context.library[id] }
        var voices: [ShotVoiceSync.Voice] = []
        var seenCards = Set<UUID>()
        for ref in shot.imageRefs {
            guard let cardID = context.library[ref.libraryItemID]?.imageGenItemID, let card = context.cardsByID[cardID],
                  !seenCards.contains(cardID), let resolved = CardVoice.resolve(card, library: lookup) else { continue }
            seenCards.insert(cardID)
            voices.append(.init(name: card.baseName, resolved: resolved))
        }
        let blocker = ShotVoiceSync.audioBlocker(generateAudio: shot.generateAudio,
                                                 channelFormat: channel(forModel: shot.model)?.0.apiFormat)
        let plan = ShotVoiceSync.plan(prompt: shot.prompt, audioRefs: shot.audioRefs, voices: voices,
                                      voiceAudioIDs: context.voiceAudioIDs, blocker: blocker)
        let skips = plan.skipped.isEmpty ? nil : plan.skipped
        if voiceSyncSkips[shotID] != skips { voiceSyncSkips[shotID] = skips }
        guard plan.prompt != shot.prompt || plan.audioRefs != shot.audioRefs else { return false }
        shots[idx].prompt = plan.prompt
        shots[idx].audioRefs = plan.audioRefs
        if !plan.skipped.isEmpty { AppLog.write("voice", "音色没挂上：\(plan.skipped.joined(separator: "；"))") }
        return true
    }
}
