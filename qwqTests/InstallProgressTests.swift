//
//  InstallProgressTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/Download/InstallProgress.swift`（`InstallStage` / `InstallState`）。
//
//  **为什么值得测**：`InstallStage` 的 `rawValue` **不是序号而是排序键** ——
// 下载详情页的清单顺序是 `states.sorted { $0.key.rawValue < $1.key.rawValue }` 得出的。
//  源码注释原话：「新增阶段时选错数值，界面上就会跳到别处（例如把新阶段写成 3，
//  它会插到「原版 jar」和「资源索引」之间）」。这条不变量没有任何编译期保护，
//  只能靠测试守住。`getDisplayName()` 的中文文案是**用户可见界面的一部分**，同样钉住。
//
//  另有一条已登记的死代码：`InstallState.getImageName()` **零调用方**
//  （界面实际走 `DownloadDetailView.iconName(for:)`，返回 SF Symbol）。本文件照样覆盖它，
//  因为「零调用方」不等于「可以随便改」—— 真要用时行为得是对的。
//

import XCTest
@testable import qwq

final class InstallProgressTests: XCTestCase {

    // MARK: - rawValue 分段（核心不变量）

    /// 原版流水线：`0...7`，**升序且连续**，顺序即真实执行顺序
    func testVanillaPipelineIsZeroThroughSevenContiguous() async {
        let vanilla: [InstallStage] = [
            .before, .clientJson, .clientIndex, .clientJar,
            .clientResources, .clientLibraries, .natives, .end,
        ]
        XCTAssertEqual(vanilla.map(\.rawValue), Array(0...7),
                       "原版 8 个阶段必须是 0...7 且连续 —— UI 顺序完全由这些 Int 决定")
    }

    /// 按 rawValue 排序即真实执行顺序（注释点名：不是 case 的书写顺序）
    func testSortingByRawValueYieldsExecutionOrder() async {
        let shuffled: [InstallStage] = [.end, .clientJar, .before, .natives, .clientJson]
        XCTAssertEqual(shuffled.sorted { $0.rawValue < $1.rawValue },
                       [.before, .clientJson, .clientJar, .natives, .end])
    }

    /// 加载器段从 1000 起，**刻意跳开** 0…7，以免将来往原版流水线插阶段时要挪数值
    func testLoaderStagesLiveInTheirOwnSegment() async {
        XCTAssertGreaterThanOrEqual(InstallStage.installFabric.rawValue, 1000)
        XCTAssertEqual(InstallStage.installFabric.rawValue, 1000)
        XCTAssertEqual(InstallStage.installForge.rawValue, 1001)
        XCTAssertEqual(InstallStage.installNeoforge.rawValue, 1002)
    }

    /// 自定义文件段从 2000 起
    func testCustomFileStagesLiveInTheirOwnSegment() async {
        XCTAssertEqual(InstallStage.customFile.rawValue, 2000)
        XCTAssertEqual(InstallStage.modDownload.rawValue, 2001)
    }

    /// **分段的意义**：任何加载器阶段都排在**所有**原版阶段之后；
    /// 任何自定义文件阶段都排在加载器阶段之后
    func testSegmentOrderingIsPreserved() async {
        let all: [InstallStage] = [
            .before, .clientJson, .clientIndex, .clientJar, .clientResources,
            .clientLibraries, .natives, .end,
            .installFabric, .installForge, .installNeoforge,
            .customFile, .modDownload,
        ]
        XCTAssertEqual(all.count, 13, "阶段总数变化时必须一并复核本文件与 UI 排序")

        let sorted = all.sorted { $0.rawValue < $1.rawValue }
        let endIdx = sorted.firstIndex(of: .end)!
        let fabricIdx = sorted.firstIndex(of: .installFabric)!
        let customIdx = sorted.firstIndex(of: .customFile)!

        XCTAssertLessThan(endIdx, fabricIdx, "加载器段必须整体排在原版段之后")
        XCTAssertLessThan(fabricIdx, customIdx, "自定义文件段必须整体排在加载器段之后")
    }

    /// 所有 rawValue 互不相同（重复会让 UI 顺序不稳定）
    func testRawValuesAreUnique() async {
        let all = [
            InstallStage.before, .clientJson, .clientIndex, .clientJar, .clientResources,
            .clientLibraries, .natives, .end,
            .installFabric, .installForge, .installNeoforge, .customFile, .modDownload,
        ]
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
    }

    // MARK: - 显示名（用户可见文案）

    func testDisplayNames() async {
        XCTAssertEqual(InstallStage.before.getDisplayName(), "未启动")
        XCTAssertEqual(InstallStage.clientJson.getDisplayName(), "下载原版 json 文件")
        XCTAssertEqual(InstallStage.clientIndex.getDisplayName(), "下载资源索引文件")
        XCTAssertEqual(InstallStage.clientJar.getDisplayName(), "下载原版 jar 文件")
        XCTAssertEqual(InstallStage.clientResources.getDisplayName(), "下载散列资源文件")
        XCTAssertEqual(InstallStage.clientLibraries.getDisplayName(), "下载依赖项文件")
        XCTAssertEqual(InstallStage.natives.getDisplayName(), "下载本地库文件")
        XCTAssertEqual(InstallStage.end.getDisplayName(), "结束")
        XCTAssertEqual(InstallStage.installFabric.getDisplayName(), "安装 Fabric")
        XCTAssertEqual(InstallStage.installForge.getDisplayName(), "安装 Forge")
        XCTAssertEqual(InstallStage.installNeoforge.getDisplayName(), "安装 NeoForge")
        XCTAssertEqual(InstallStage.customFile.getDisplayName(), "下载自定义文件")
        XCTAssertEqual(InstallStage.modDownload.getDisplayName(), "下载文件")
    }

    /// 每个阶段都有非空显示名（漏一个界面上就是空白行）
    func testEveryStageHasNonEmptyDisplayName() async {
        let all = [
            InstallStage.before, .clientJson, .clientIndex, .clientJar, .clientResources,
            .clientLibraries, .natives, .end,
            .installFabric, .installForge, .installNeoforge, .customFile, .modDownload,
        ]
        for stage in all {
            XCTAssertFalse(stage.getDisplayName().isEmpty, "\(stage) 缺少显示名")
        }
    }

    // MARK: - InstallState.getImageName（已登记为零调用方）

    func testImageNames() async {
        XCTAssertEqual(InstallState.waiting.getImageName(), "InstallWaiting")
        XCTAssertEqual(InstallState.finished.getImageName(), "InstallFinished")
    }

    /// `inprogress` 与 `failed` 走 `default` ⇒ 占位串 `"Missingno"`
    /// （源码注释自认：这两枚自绘资源不存在，界面实际用 SF Symbol）
    func testInProgressAndFailedFallBackToPlaceholder() async {
        XCTAssertEqual(InstallState.inprogress.getImageName(), "Missingno")
        XCTAssertEqual(InstallState.failed.getImageName(), "Missingno")
    }
}
