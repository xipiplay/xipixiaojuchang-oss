import Foundation

/// 连接测试的结果：成功 / 失败 + 一句给人看的话
struct ProbeResult: Equatable, Sendable {
    var ok: Bool
    var message: String
}

/// 左栏「AI」「上传」两个图标的状态：默认暗（没测过）→ 测试中 → 亮（成功）/ 红（失败）。仅本次运行有效。
enum ProbeState: Equatable, Sendable { case unknown, testing, ok, failed }

/// 连接测试（2026-10-07）：左栏的 AI / 上传图标点一下就测，设置页里的测试按钮也走这里，测的是同一条链路、说的是同一句话。
@MainActor
enum ConnectionProbe {
    static let aiSystem = "这是一次连接测试，用来确认通道可用。"
    static let aiUser = "请只回复两个字：可用"

    /// 剧本流水线 AI：发一次最小请求，有回复就算通。
    static func ai(config: PipelineAISettings) async -> ProbeResult {
        // 外部智能体接力：不调 API，没有「连接」可测；只看接力有没有真的开起来
        if config.usesAgent {
            return AgentBridge.shared.isRunning
                ? ProbeResult(ok: true, message: "外部智能体接力已开启（请求放进收件目录，不调用 API）")
                : ProbeResult(ok: false, message: "外部智能体接力还没启动：点保存后生效")
        }
        let started = Date()
        do {
            // 只是测连接：最多等 90 秒（原来跟着文字接口的 5 分钟，慢模型时左栏图标一直转，2026-10-12）
            let reply = try await PipelineAIService.chat(config: config, system: aiSystem, user: aiUser, timeout: probeTimeout)
            guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ProbeResult(ok: false, message: "连接失败：模型没有返回内容")
            }
            return ProbeResult(ok: true, message: "连接成功")
        } catch {
            if Date().timeIntervalSince(started) >= probeTimeout - 1 {
                return ProbeResult(ok: false, message: "连接失败：模型 \(Int(probeTimeout)) 秒没回复（可能是模型太慢，或服务商那边卡住了）")
            }
            return ProbeResult(ok: false, message: "连接失败：\(error.localizedDescription)")
        }
    }

    /// AI 连接测试最多等多久
    static let probeTimeout: TimeInterval = 90

    /// 用**已保存**的设置测 AI（左栏图标用；设置页里测的是正在编辑、还没保存的那份）
    static func savedAI() async -> ProbeResult {
        let loaded = PipelineAISettingsStore.load()
        if let error = loaded.error { return ProbeResult(ok: false, message: "连接失败：\(error)") }
        do {
            return await ai(config: try loaded.config.validated())
        } catch {
            return ProbeResult(ok: false, message: "还没配好：\(error.localizedDescription)到 设置 → 剧本流水线 里填。")
        }
    }

    /// 测**实际链路**（和提交时同一条）：配了 catbox userhash → catbox 主站（校验失败先原地重试一次），再失败切 litterbox；
    /// 没配 → 只有 litterbox。上传成功 ≠ 文件真的在：链路里自带「Range GET 校验远端字节数」。
    /// `progress`：中间步骤的说明（「主站失败 → 试 litterbox…」），设置页拿它一步步刷新文字。
    static func freeHostUpload(progress: (String) -> Void = { _ in }) async -> ProbeResult {
        let data = Data("嬉皮小剧场上传测试".utf8)
        let bytes = data.count
        let name = "xipi-upload-test.txt"
        do {
            if CatboxConfigStore.load() != nil {
                do {
                    let url = try await CatboxMainUploadService.uploadFile(data: data, filename: name)
                    return ProbeResult(ok: true, message: "catbox 主站（永久）成功：\(url)（已校验远端 \(bytes) 字节）")
                } catch let error as UploadError where error.isVerifyFailure {
                    progress("catbox 主站校验失败（\(error.localizedDescription)）→ 原地重试一次…")
                    do {
                        let url = try await CatboxMainUploadService.uploadFile(data: data, filename: name)
                        return ProbeResult(ok: true, message: "catbox 主站重试成功：\(url)（已校验远端 \(bytes) 字节）")
                    } catch {
                        progress("catbox 主站重试仍失败（\(error.localizedDescription)）→ 试 litterbox…")
                    }
                } catch {
                    progress("catbox 主站失败（\(error.localizedDescription)）→ 试 litterbox…")
                }
            }
            let url = try await LitterboxUploadService.uploadFile(data: data, filename: name)
            return ProbeResult(ok: true, message: "litterbox（72h 临时）成功：\(url)（已校验远端 \(bytes) 字节）")
        } catch {
            return ProbeResult(ok: false, message: "测试失败：\(error.localizedDescription)")
        }
    }

    static func oss(config: OSSConfig) async -> ProbeResult {
        do {
            let url = try await OSSUploader.upload(
                data: Data("嬉皮小剧场 OSS 测试".utf8),
                key: "zizi-test-\(UUID().uuidString.lowercased()).txt",
                contentType: "text/plain",
                config: config
            )
            return ProbeResult(ok: true, message: "上传成功：\(url.absoluteString)")
        } catch {
            return ProbeResult(ok: false, message: error.localizedDescription)
        }
    }

    /// 测「素材上传到哪里」现在选的那一条（设置 → 素材上传）：选免费图床测图床，选 OSS 测 OSS（用已保存的配置）。
    static func upload(host: MaterialUploadHost, progress: (String) -> Void = { _ in }) async -> ProbeResult {
        switch host {
        case .freeHost:
            return await freeHostUpload(progress: progress)
        case .oss:
            guard let config = OSSConfigStore.load(), config.isValid else {
                return ProbeResult(ok: false, message: "还没配好阿里云 OSS：到 设置 → 素材上传 里填完整并保存。")
            }
            return await oss(config: config)
        }
    }

    static func hostName(_ host: MaterialUploadHost) -> String {
        host == .oss ? "阿里云 OSS" : "免费图床"
    }
}
