import Foundation
import XCTest
@testable import Xipixiaojuchang

final class VideoStatusResponseTests: XCTestCase {
    /// 旧代理的 `data.output` 形状：候选键都不命中时，退到递归扫描找视频直链
    func testExtractsVideoURLByFallbackScan() throws {
        let json = #"{"data":{"output":"http://cdn.example.com/abc.mp4","extra":{"flag":true}}}"#
        let response = try VideoStatusResponse(data: Data(json.utf8))
        XCTAssertEqual(response.videoURL?.absoluteString, "http://cdn.example.com/abc.mp4")
    }

    func testParsesNestedStatus() throws {
        let json = #"{"code":0,"data":{"status":"completed","video":"http://cdn.example.com/x.mp4"}}"#
        let response = try VideoStatusResponse(data: Data(json.utf8))
        XCTAssertEqual(response.phase, .completed)
        XCTAssertEqual(response.videoURL?.absoluteString, "http://cdn.example.com/x.mp4")
    }

    func testFindsFailureReason() throws {
        let json = #"{"status":"failed","error":"生成失败：素材无效"}"#
        let response = try VideoStatusResponse(data: Data(json.utf8))
        XCTAssertEqual(response.phase, .failed)
        XCTAssertEqual(response.failureReason, "生成失败：素材无效")
    }

    func testExtractsVideoURLFromNestedData() throws {
        let json = #"{"code":"success","data":{"task_id":"vid_1","status":"SUCCESS","url":"https://cdn.example.com/v/x.mp4?Expires=1&Signature=abc","fail_reason":""}}"#
        let response = try VideoStatusResponse(data: Data(json.utf8))
        XCTAssertEqual(response.phase, .completed)
        XCTAssertEqual(response.videoURL?.absoluteString, "https://cdn.example.com/v/x.mp4?Expires=1&Signature=abc")
        XCTAssertNil(response.failureReason)
    }

    func testParsesProgress() throws {
        let json = #"{"code":"success","data":{"status":"IN_PROGRESS","progress":"30%"}}"#
        let response = try VideoStatusResponse(data: Data(json.utf8))
        XCTAssertEqual(response.phase, .inProgress)
        XCTAssertEqual(response.progress, 30)
    }

    /// 有些异步任务接口的状态在 `output.task_status`
    func testParsesOutputTaskStatus() throws {
        let json = #"{"output":{"task_status":"SUCCEEDED","video_url":"https://cdn.example.com/out.mp4"}}"#
        let response = try VideoStatusResponse(data: Data(json.utf8))
        XCTAssertEqual(response.phase, .completed)
        XCTAssertEqual(response.videoURL?.absoluteString, "https://cdn.example.com/out.mp4")
    }

    /// 完成响应：顶层 `status` + `video_url`（另有 metadata.result_urls 同链）
    func testParsesTopLevelVideoURLResponse() throws {
        let json = #"{"status":"completed","video_url":"https://cdn.example.com/x/task_1.mp4","metadata":{"result_urls":["https://cdn.example.com/x/task_1.mp4"]}}"#
        let response = try VideoStatusResponse(data: Data(json.utf8))
        XCTAssertEqual(response.phase, .completed)
        XCTAssertEqual(response.videoURL?.absoluteString, "https://cdn.example.com/x/task_1.mp4")
    }

    /// 进行中响应：只有 status
    func testParsesInProgressResponse() throws {
        let json = #"{"id":"task_1","status":"in_progress"}"#
        let response = try VideoStatusResponse(data: Data(json.utf8))
        XCTAssertEqual(response.phase, .inProgress)
        XCTAssertNil(response.videoURL)
    }
}

final class AspectRatioTests: XCTestCase {
    func testRatioValueMapping() {
        XCTAssertEqual(AspectRatio.adaptive.ratioValue, "adaptive")
        XCTAssertEqual(AspectRatio.ratio16x9.ratioValue, "16:9")
        XCTAssertEqual(AspectRatio.ratio9x16.ratioValue, "9:16")
        XCTAssertEqual(AspectRatio.ratio1x1.ratioValue, "1:1")
        // 兼容旧数据：horizontal / vertical
        XCTAssertEqual(AspectRatio.horizontal.ratioValue, "16:9")
        XCTAssertEqual(AspectRatio.vertical.ratioValue, "9:16")
    }

    func testVideoSizeMapping() {
        XCTAssertEqual(AspectRatio.ratio16x9.videoSize, "1280x720")
        XCTAssertEqual(AspectRatio.ratio9x16.videoSize, "720x1280")
        XCTAssertEqual(AspectRatio.ratio1x1.videoSize, "1024x1024")
        XCTAssertEqual(AspectRatio.adaptive.videoSize, "1280x720")
    }

    func testVideoDimensionsMapping() {
        XCTAssertEqual(AspectRatio.ratio16x9.videoDimensions.width, 1280)
        XCTAssertEqual(AspectRatio.ratio16x9.videoDimensions.height, 720)
        XCTAssertEqual(AspectRatio.ratio9x16.videoDimensions.width, 720)
        XCTAssertEqual(AspectRatio.ratio9x16.videoDimensions.height, 1280)
    }

    func testPlainLabelMapping() {
        XCTAssertEqual(AspectRatio.ratio16x9.plainLabel, "16:9")
        XCTAssertEqual(AspectRatio.horizontal.plainLabel, "16:9")
        XCTAssertEqual(AspectRatio.vertical.plainLabel, "9:16")
        XCTAssertEqual(AspectRatio.adaptive.plainLabel, "自适应")
    }
}

final class ShotScriptParserTests: XCTestCase {
    func testParsesShotsByTripleTagLine() {
        let script = """
        [堂屋通往后院的门槛处][昭宁、青棠、稳婆、雪娘][茶桌、茶盏、门槛]

        【角色初始站位与朝向】[0-0.1 秒]：昭宁站在通往后院的门槛内侧。

        [0.1-3 秒] 景别与构图：中近景，门槛侧后方构图。

        配音：（雪娘）：“郡主留步。”

        [庭院][昭宁][茶盏]

        [3-5.6 秒] 景别与构图：近景，昭宁侧面与雪娘手部同框。
        """
        let shots = ShotScriptParser.parse(script)
        XCTAssertEqual(shots.count, 2)
        XCTAssertTrue(shots[0].hasPrefix("[堂屋通往后院的门槛处]"))
        XCTAssertTrue(shots[0].contains("配音：（雪娘）：“郡主留步。”"))
        XCTAssertTrue(shots[1].hasPrefix("[庭院][昭宁][茶盏]"))
        // 分镜内的时间标签行（行首单标签+文字）不应被误判为新分镜
        XCTAssertTrue(shots[0].contains("[0.1-3 秒] 景别与构图"))
    }

    func testTextWithoutSeparatorYieldsSingleShot() {
        let text = "没有任何标签的纯文本提示词。"
        let shots = ShotScriptParser.parse(text)
        XCTAssertEqual(shots.count, 1)
    }

    func testLeadingBlankLinesIgnored() {
        let script = """

        [场景][角色][道具]

        内容。
        """
        let shots = ShotScriptParser.parse(script)
        XCTAssertEqual(shots.count, 1)
        XCTAssertTrue(shots[0].hasPrefix("[场景]"))
    }
}

final class TaskPhaseTests: XCTestCase {
    func testServerStatusMapping() {
        XCTAssertEqual(TaskPhase(serverStatus: "NOT_START"), .queued)
        XCTAssertEqual(TaskPhase(serverStatus: "QUEUED"), .queued)
        XCTAssertEqual(TaskPhase(serverStatus: "IN_PROGRESS"), .inProgress)
        XCTAssertEqual(TaskPhase(serverStatus: "processing"), .inProgress)
        XCTAssertEqual(TaskPhase(serverStatus: "SUCCESS"), .completed)
        XCTAssertEqual(TaskPhase(serverStatus: "FAILED"), .failed)
        XCTAssertNil(TaskPhase(serverStatus: "weird_status"))
    }
}

final class AtImageSyntaxTests: XCTestCase {
    /// 渠道打开 @image1 语法时把「图N / 视频N / 音频N」换成 @ 语法：
    /// 只换实际存在的槽位（N ≤ 素材数），大编号优先（避免「图1」误伤「图10」）
    func testAtImageSyntaxConversion() {
        let prompt = "[图1蕴古斋前柜][图3齐掌柜、图4沈砚]\n\n图10 和 图11"
        XCTAssertEqual(
            APIClient.atImagePrompt(prompt, imageCount: 11, videoCount: 0, audioCount: 0),
            "[@image1蕴古斋前柜][@image3齐掌柜、@image4沈砚]\n\n@image10 和 @image11"
        )
        XCTAssertEqual(
            APIClient.atImagePrompt("视频1 视频2 音频1", imageCount: 0, videoCount: 2, audioCount: 1),
            "@video1 @video2 @audio1"
        )
        // 超出槽位数的编号不动（可能真是在说"第 3 张图"）
        XCTAssertEqual(
            APIClient.atImagePrompt("图1 图2 图3", imageCount: 2, videoCount: 0, audioCount: 0),
            "@image1 @image2 图3"
        )
    }
}
