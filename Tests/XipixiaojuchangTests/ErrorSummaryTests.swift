import XCTest
@testable import Xipixiaojuchang

/// `Formatters.errorSummary` —— 把服务商返回的错误原文压成给人看的摘要。
///
/// 下面的用例全部取自 **2026-09-23 app.log 里的真实原文**（那次连着踩了四种不同的失败）。
final class ErrorSummaryTests: XCTestCase {

    /// 扁平结构：`message` 在第一层（aicost 的「系统升级中」就是这个形状）
    func testExtractsTopLevelMessage() {
        let raw = #"请求失败（HTTP 503）：{"code":"fail_to_fetch_task","message":"系统升级中，暂停任务提交","data":null}"#
        XCTAssertEqual(Formatters.errorSummary(raw), "系统升级中，暂停任务提交（HTTP 503）")
    }

    /// 嵌套结构：`error.message`（New API 的 model_not_found 是这个形状）
    func testExtractsNestedErrorMessage() {
        let raw = #"请求失败（HTTP 503）：{"error":{"code":"model_not_found","message":"分组 video-model-x 下模型 video-model-x 无可用渠道（distributor） (request id: 202609230118319236975478268d9d6pgHP3WIG)","type":"new_api_error"}}"#
        let summary = Formatters.errorSummary(raw)
        XCTAssertTrue(summary.hasPrefix("分组 video-model-x 下模型"))
        XCTAssertTrue(summary.hasSuffix("（HTTP 503）"))
        // ⚠️ request id 必须保留 —— 报给服务商时全靠它定位那一次请求
        XCTAssertTrue(summary.contains("request id: 20260923011831"), "request id 被吞了：\(summary)")
    }

    /// message 里自带冒号 / 空格也不能被截断
    func testExtractsMessageContainingColon() {
        let raw = #"请求失败（HTTP 400）：{"code":"invalid_request","message":"json: cannot unmarshal string into Go struct field .Alias.generate_audio of type bool","data":null}"#
        XCTAssertEqual(Formatters.errorSummary(raw),
                       "json: cannot unmarshal string into Go struct field .Alias.generate_audio of type bool（HTTP 400）")
    }

    /// 纯文本错误（没有 JSON）→ 原样返回，别自作聪明
    func testPlainTextReturnedAsIs() {
        let audit = "参考素材里的真人照片未通过内容审核。真人肖像的审核结果不稳定，同一张图直接重投多数仍会被拒，建议换素材后再提交"
        XCTAssertEqual(Formatters.errorSummary(audit), audit)

        // 这条自己带「（HTTP 401）」但**没有 JSON** —— 也必须原样返回（不能把尾巴拆出来重复拼）
        let download = "视频已生成，但下载转存失败：网络错误：视频下载失败（HTTP 401）"
        XCTAssertEqual(Formatters.errorSummary(download), download)
    }

    /// 有 JSON 但里面既没有 message 也没有 error → **原样返回**（宁可给原文，也不给一条空摘要）
    func testJsonWithoutMessageFallsBackToRaw() {
        let raw = #"请求失败（HTTP 500）：{"code":"unknown","data":null}"#
        XCTAssertEqual(Formatters.errorSummary(raw), raw)
    }

    /// `error` 直接是字符串（不是对象）也要认
    func testErrorAsPlainString() {
        let raw = #"请求失败（HTTP 400）：{"error":"bad request","code":1}"#
        XCTAssertEqual(Formatters.errorSummary(raw), "bad request（HTTP 400）")
    }

    /// 空串 / 只有空白
    func testEmptyInput() {
        XCTAssertEqual(Formatters.errorSummary(""), "")
        XCTAssertEqual(Formatters.errorSummary("   \n  "), "")
    }
}
