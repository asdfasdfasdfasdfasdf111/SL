//
//  DownloadDetailManagerTests.swift
//  qwqTests
//
//  覆盖 `Features/Download/DownloadDetailManager` 的圆按钮生命周期收口：
//  点亮与弹入动画统由 `start()` 完成，报错路径（resolve / 前置校验失败、
//  任务从未 start）绝不残留一个亮着的圆按钮。
//
//  为什么必须有这几条：
//  用户报告「出现一个报错后，圆形下载按钮就不会消失了」。根因是点亮与收起不对称：
//  点亮在 `ModDetailView` 点击后 0.28s 无条件置 `showCircleButton = true`，
//  而收起只在 `dismiss(ownerID:)`（要求任务已登记且归属匹配）——报错路径任务
//  从未 start()，要么 `ownerID` 为 nil（catch 不 dismiss），要么归属校验拒绝清理，
//  按钮于是永远挂着。修复：点亮收口到 `start()` + `retractCircleButtonIfIdle()`
//  兜底报错路径。下面两条用例把「retract 只在无任务时收起」这一安全边界钉住：
//  有任务在跑时绝不能误收按钮（误收与崩溃 #4 是同一类竞态）。
//

import XCTest
@testable import qwq

@MainActor
final class DownloadDetailManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DownloadDetailManager.shared.dismiss()
    }

    override func tearDown() {
        DownloadDetailManager.shared.dismiss()
        super.tearDown()
    }

    /// 报错路径（任务从未 start，tasks 为空）：retract 必须收起圆按钮。
    /// 修复前：点亮在视图层无条件发生、报错路径无人收起 → 「报错后圆按钮不消失」。
    func testRetractHidesCircleButtonWhenNoTaskInFlight() async {
        let manager = DownloadDetailManager.shared
        manager.showCircleButton = true           // 模拟报错前已被点亮的按钮

        manager.retractCircleButtonIfIdle()

        XCTAssertFalse(manager.showCircleButton,
                       "无任务在跑时圆按钮应被收起——报错路径不该残留亮着的按钮")
        XCTAssertEqual(manager.circleScale, 0.01)
        XCTAssertEqual(manager.circleOpacity, 0)
    }

    /// 有任务在跑（tasks 非空）时，retract 不得收起圆按钮：
    /// 按钮属于那个任务，报错的旧任务不能收掉它（误收与崩溃 #4 同类竞态）。
    func testRetractKeepsCircleButtonWhenTaskInFlight() async {
        let manager = DownloadDetailManager.shared
        manager.tasks = InstallTasks.single(InstallTask())
        manager.showCircleButton = true

        manager.retractCircleButtonIfIdle()

        XCTAssertTrue(manager.showCircleButton,
                      "有任务在跑时圆按钮必须保持显示——本次报错无关的下载不能被误收")
    }

    /// 开始任务后圆按钮可见（start 是唯一点亮入口的回归钉）。
    /// 修复前视图层也点亮；收口后必须由 start 统一负责，报错路径才可能不亮。
    func testStartLightsCircleButton() async {
        let manager = DownloadDetailManager.shared

        manager.start(InstallTasks.single(InstallTask()))

        XCTAssertTrue(manager.showCircleButton)
        XCTAssertTrue(manager.isPresented)
    }

    /// dismiss 清空任务的同时必须收起圆按钮（对称性：收起与点亮同源）。
    func testDismissHidesCircleButton() async {
        let manager = DownloadDetailManager.shared
        manager.start(InstallTasks.single(InstallTask()))

        manager.dismiss(ownerID: manager.tasks.id)

        XCTAssertFalse(manager.showCircleButton)
        XCTAssertFalse(manager.isPresented)
        XCTAssertTrue(manager.tasks.tasks.isEmpty)
    }
}