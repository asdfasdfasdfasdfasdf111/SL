//
//  GameScanGenerationTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//  1. **超时不作废结果**（本次修复的核心）：10 秒超时只负责「提前把界面从『检索中』放出来」，
//     不负责判这次扫描无效。若把「超时」当成丢弃结果的判据，慢盘（机械盘/外接盘/同时在下解压）
//     上扫到的版本会被永久丢掉 —— 界面停在「未找到游戏版本」，必须手动点一次全盘查找才恢复。
//  2. **跨代回调要丢**：定时器闭包与 `await scanTask.value` 的续体都可能跨代触发（旧扫描的回调
//     落在新扫描头上）。丢弃的判据是「这一代是否已被取代」，不是「超没超时」：
//     ① 否则上一代的超时闭包会把刚开始的新扫描判成「已超时」；
//     ② 否则上一代的结果会覆盖新一代刚扫出来的清单。
//  3. 超时退化只做一次（`shouldApplyScanTimeout` 的第二次调用必须为 false）。
//
//  被测：Features/Game/ViewModels/GameCategoryViewModel.swift
//

import XCTest
@testable import qwq

@MainActor
final class GameScanGenerationTests: XCTestCase {

    /// 代际号：每次重扫递增，且返回给视图用于核对自己那份回调是否还算数
    func testResetScanStateBumpsGenerationAndReturnsIt() async {
        let viewModel = GameCategoryViewModel()
        let first = viewModel.resetScanState()
        let second = viewModel.resetScanState()
        XCTAssertNotEqual(first, second, "重扫必须换一代，否则跨代回调无法区分")
        XCTAssertTrue(viewModel.isCurrentScan(second))
        XCTAssertFalse(viewModel.isCurrentScan(first), "上一代的回调必须被丢弃")
    }

    /// 核心回归守卫：超时发生后，当前代际**仍然有效** —— 迟到结果要照常应用
    func testTimeoutDoesNotInvalidateCurrentScan() async {
        let viewModel = GameCategoryViewModel()
        let generation = viewModel.resetScanState()

        XCTAssertTrue(viewModel.shouldApplyScanTimeout(), "首次超时判定应成立")
        viewModel.applyScanTimeoutPresentation()
        XCTAssertTrue(viewModel.scanTimedOut)
        XCTAssertFalse(viewModel.hasVersions, "超时退化后先按「无版本」展示")

        XCTAssertTrue(viewModel.isCurrentScan(generation),
                      "超时只是提前放行界面，不代表这次扫描作废；否则迟到结果会被永久丢弃")
        XCTAssertFalse(viewModel.shouldApplyScanTimeout(), "超时退化只做一次")
    }

    /// 迟到结果落地后，展示状态必须从「无版本」翻回来（界面据此显示版本清单）
    func testLateResultIsAppliedAfterTimeout() async {
        let viewModel = GameCategoryViewModel()
        let savedRoot = LauncherSettings.shared.selectedGameRoot
        let savedVersion = LauncherSettings.shared.selectedMinecraftVersion
        defer {
            LauncherSettings.shared.selectedGameRoot = savedRoot
            LauncherSettings.shared.selectedMinecraftVersion = savedVersion
        }

        let generation = viewModel.resetScanState()
        _ = viewModel.shouldApplyScanTimeout()
        viewModel.applyScanTimeoutPresentation()
        XCTAssertFalse(viewModel.hasVersions)

        guard viewModel.isCurrentScan(generation) else {
            XCTFail("超时后当前代际不应失效")
            return
        }
        let list = ["1.20.1-forge", "1.21-fabric"]
        viewModel.applyScanResult((root: NSTemporaryDirectory() + "SL-scan-gen-test", versions: list))

        XCTAssertTrue(viewModel.hasVersions, "迟到结果必须落地，界面不能停在「未找到游戏版本」")
        XCTAssertEqual(viewModel.versions, list)
        XCTAssertTrue(viewModel.showBottomButtons)
    }
}
