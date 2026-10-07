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
}
