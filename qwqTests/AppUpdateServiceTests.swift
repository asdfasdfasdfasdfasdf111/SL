//
//  AppUpdateServiceTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Update/AppUpdateService` 的两个纯函数：
//  `isNewer(_:than:)`（版本比较，自动更新要不要提示的判据）与
//  `parseLatestRelease(_:)`（releases/latest 响应 → AppRelease）。
//
//  **为什么值得测**：比较错了会出现两种事故——该提示不提示（用户永远停在旧版）、
//  不该提示乱提示（本地 Debug 包天天弹窗）；解析错一个字段（zip 资产挑错/漏挑）
//  自动更新整条链路哑火。
//

import XCTest
@testable import qwq

final class AppUpdateServiceTests: XCTestCase {

    // MARK: - 版本比较

    func testNewerPatchVersion() async {
        XCTAssertTrue(AppUpdateService.isNewer("v1.6.1", than: "1.6.0"))
    }

    func testNewerMinorBeatsOlderPatch() async {
        XCTAssertTrue(AppUpdateService.isNewer("v1.10.0", than: "v1.9.9"),
                      "逐段数值比较：10 > 9，不是字符串比较（否则 '10' < '9'）")
    }

    func testSameVersionIsNotNewer() async {
        XCTAssertFalse(AppUpdateService.isNewer("v1.6.0", than: "1.6.0"))
    }

    func testMissingSegmentPaddedWithZero() async {
        XCTAssertFalse(AppUpdateService.isNewer("v1.6", than: "1.6.0"),
                       "段数不齐按 0 补齐：1.6 == 1.6.0")
        XCTAssertTrue(AppUpdateService.isNewer("v1.7", than: "v1.6.9"))
    }

    func testOlderVersionIsNotNewer() async {
        XCTAssertFalse(AppUpdateService.isNewer("v1.5.2", than: "v1.6.0"))
    }

    /// 非数字后缀（如 1.6.0-beta1 的段）取前导数字，不崩也不整段当 0
    func testNonNumericSuffixIsTolerated() async {
        XCTAssertTrue(AppUpdateService.isNewer("v1.6.1-beta1", than: "v1.6.0"))
    }

    // MARK: - Release 解析

    /// releases/latest 响应的最小 fixture：tag + 说明 + 一个 zip 资产（自动更新的下载源）
    private let fixture = """
    {
      "tag_name": "v1.6.0",
      "body": "更新说明正文",
      "assets": [
        {"name": "Source code (zip)", "browser_download_url": "https://github.com/x/s.zip"},
        {"name": "qwq-v1.6.0.zip", "browser_download_url": "https://github.com/x/app.zip"}
      ]
    }
    """.data(using: .utf8)!

    func testParsesTagAndZipAsset() async {
        let release = AppUpdateService.parseLatestRelease(fixture)
        XCTAssertEqual(release?.tagName, "v1.6.0")
        XCTAssertEqual(release?.downloadURL.absoluteString, "https://github.com/x/app.zip",
                       "必须挑 .zip 资产，GitHub 自动的 Source code 资产不能当更新包")
        XCTAssertEqual(release?.notes, "更新说明正文")
    }

    /// 没有 zip 资产 ⇒ 视为「没有可用更新」（发版必须带 zip，见 release.yml 头注释）
    func testReturnsNilWithoutZipAsset() async {
        let data = """
        {"tag_name": "v1.6.0", "assets": [{"name": "s.txt", "browser_download_url": "https://github.com/x/s.txt"}]}
        """.data(using: .utf8)!
        XCTAssertNil(AppUpdateService.parseLatestRelease(data))
    }

    func testReturnsNilOnMalformedJSON() async {
        XCTAssertNil(AppUpdateService.parseLatestRelease(Data("not json".utf8)))
    }

    // MARK: - 更新提示的安全属性

    /// 更新提示的**隐式应答**（兜底超时 / 点右上角 × / 被新提示顶替 / 无 UI 承载）必须落在
    /// 「下次再说」上，绝不能落在「立即更新」。
    ///
    /// 为什么这是硬约束：这条提示是**启动时自动弹**的，用户完全可能在忙别的（或直接点 ×）。
    /// 隐式应答一旦是「立即更新」，就等于「没理会弹窗 → 自动下载、替换 App 并重启」，
    /// 无人值守时会真的把 App 换掉。所以这里把「首按钮是主操作、隐式按钮是安全项」钉死。
    @MainActor
    func testUpdateNoticeImplicitChoiceNeverInstalls() async throws {
        let release = AppUpdateService.AppRelease(
            tagName: "v9.9.9",
            notes: "",
            downloadURL: try XCTUnwrap(URL(string: "https://example.com/qwq.dmg")))
        let notice = AppUpdateCoordinator.makeUpdateNotice(release: release, current: "1.7.0")

        XCTAssertEqual(notice.buttons.first?.label, "立即更新", "首个按钮仍是主操作（视觉强调）")
        XCTAssertEqual(notice.safeFallbackChoiceIndex, 1,
                       "隐式应答必须是下标 1；一旦回到 0，「不理会弹窗」＝「自动换装」")
        XCTAssertEqual(notice.buttons[notice.safeFallbackChoiceIndex].label, "下次再说",
                       "隐式应答指向的按钮必须确实是「下次再说」")
        XCTAssertTrue(notice.title.contains("v9.9.9"), "标题必须写明新版本号")
        XCTAssertTrue(notice.title.contains("1.7.0"), "标题必须写明当前版本号")
    }
}
