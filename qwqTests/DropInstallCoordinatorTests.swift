//
//  DropInstallCoordinatorTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//  1. 文件分流是唯一裁决点：`.jar` 走模组安装、`.zip` / `.mrpack` 走整合包安装，
//     其余扩展名一律忽略——误收文件会弹出错误的安装弹窗；
//  2. 扩展名判定大小写不敏感（`.ZIP` / `.MrPack` 必须与全小写等价）；
//  3. 失败路径不产生半成品状态：模组版本检测失败时必须只提示错误、
//     不得同时打开模组安装弹窗（否则用户会在空列表里点确认）；
//  4. 弹窗状态与暂存数据分离：cancel 只关弹窗；无暂存文件时确认按钮不得产生
//     「安装完成」这类假成功提示（对应实现里的 guard）；
//  5. `handle(providers:)` 的返回值语义：没有可接受的 file-url 内容时返回 false，
//     不得误判为已接受拖拽；
//  6. 弹窗状态变化必须发出 objectWillChange（否则 SwiftUI 不渲染弹窗）。
//
//  被测：App/ViewModels/DropInstallCoordinator.swift
//

import XCTest
import Combine
@testable import qwq

final class DropInstallCoordinatorTests: XCTestCase {

    /// 无消息投递时的哨兵文案
    private let idlePopupMessage = "无消息"

    override func setUp() {
        super.setUp()
        let settings = LauncherSettings.shared
        settings.javaPopupMessage = idlePopupMessage
        settings.showJavaPopup = false
        settings.showLaunchAlert = false
        settings.launchErrorMessage = nil
    }

    override func tearDown() {
        let settings = LauncherSettings.shared
        settings.showJavaPopup = false
        settings.showLaunchAlert = false
        settings.launchErrorMessage = nil
        super.tearDown()
    }

    /// 构造一个稳定的临时路径（不落盘，协调器的分流只看扩展名）
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    // MARK: - 初始状态

    /// 初始态：两个弹窗关闭、暂存字段为空
    func testInitialState() {
        let coordinator = DropInstallCoordinator()

        XCTAssertFalse(coordinator.showModInstallSheet)
        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertTrue(coordinator.modInstallInstances.isEmpty)
        XCTAssertEqual(coordinator.pendingModName, "")
        XCTAssertEqual(coordinator.pendingModVersion, "")
        XCTAssertEqual(coordinator.pendingModpackName, "")
    }

    // MARK: - 整合包分流

    /// .zip 直接进入安装位置选择，展示名取去扩展名的文件名
    func testZipOpensModpackInstallSheet() {
        let coordinator = DropInstallCoordinator()

        coordinator.handle(urls: [url("我的整合包.zip")])

        XCTAssertTrue(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "我的整合包")
        XCTAssertFalse(coordinator.showModInstallSheet, "整合包不得走模组安装弹窗")
        XCTAssertNil(LauncherSettings.shared.launchErrorMessage)
    }

    /// .mrpack 与 .zip 同路径处理
    func testMrpackOpensModpackInstallSheet() {
        let coordinator = DropInstallCoordinator()

        coordinator.handle(urls: [url("BetterMC.mrpack")])

        XCTAssertTrue(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "BetterMC")
    }

    /// 扩展名判定大小写不敏感
    func testPathExtensionMatchingIsCaseInsensitive() {
        let upper = DropInstallCoordinator()
        upper.handle(urls: [url("PACK.ZIP")])
        XCTAssertTrue(upper.showModpackInstallSheet)
        XCTAssertEqual(upper.pendingModpackName, "PACK")

        let mixed = DropInstallCoordinator()
        mixed.handle(urls: [url("Mod.Pack.MrPack")])
        XCTAssertTrue(mixed.showModpackInstallSheet)
        XCTAssertEqual(mixed.pendingModpackName, "Mod.Pack")
    }

    // MARK: - 模组分流与失败路径

    /// 无法识别版本与加载器的 jar：只提示错误，不得打开模组安装弹窗
    func testJarWithoutDetectableVersionReportsErrorOnly() {
        let coordinator = DropInstallCoordinator()
        let jar = url("qwqTests-\(UUID().uuidString).jar")

        coordinator.handle(urls: [jar])

        let name = jar.deletingPathExtension().lastPathComponent
        XCTAssertEqual(LauncherSettings.shared.launchErrorMessage,
                       "无法检测模组「\(name)」的 Minecraft 版本")
        XCTAssertTrue(LauncherSettings.shared.showLaunchAlert)
        XCTAssertFalse(coordinator.showModInstallSheet,
                       "前置条件不满足时打开空弹窗会让用户对着空列表点确认")
        XCTAssertEqual(coordinator.pendingModName, "")
        XCTAssertTrue(coordinator.modInstallInstances.isEmpty)
    }

    /// 不支持的类型一律忽略：不弹窗、不提示、不产生任何暂存数据
    func testUnsupportedExtensionsAreIgnored() {
        let coordinator = DropInstallCoordinator()
        let ignored = ["notes.txt", "archive.zipx", "mod.jar.txt", "无扩展名", "数据.json", "pack.7z"]

        coordinator.handle(urls: ignored.map(url))

        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertFalse(coordinator.showModInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "")
        XCTAssertEqual(coordinator.pendingModName, "")
        XCTAssertNil(LauncherSettings.shared.launchErrorMessage)
        XCTAssertEqual(LauncherSettings.shared.javaPopupMessage, idlePopupMessage,
                       "被忽略的文件不得产生任何用户可见提示")
    }

    /// 空列表是 no-op
    func testEmptyURLListIsNoOp() {
        let coordinator = DropInstallCoordinator()

        coordinator.handle(urls: [])

        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertFalse(coordinator.showModInstallSheet)
    }

    /// 混合批次只处理可安装文件，忽略项不得干扰暂存数据
    func testBatchRouteHandlesOnlyInstallableFiles() {
        let coordinator = DropInstallCoordinator()

        coordinator.handle(urls: [url("说明.txt"), url("整合包.zip"), url("图片.png")])

        XCTAssertTrue(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "整合包")
    }

    /// 一批多个整合包时以最后一个为暂存目标（逐个分流、后写覆盖）
    func testBatchRouteKeepsLastModpackAsPendingTarget() {
        let coordinator = DropInstallCoordinator()

        coordinator.handle(urls: [url("第一个.zip"), url("第二个.mrpack")])

        XCTAssertTrue(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "第二个")
    }

    /// jar 失败与整合包成功混投：两条分支互不掩盖，均按各自语义执行
    func testJarFailureAndModpackSuccessAreBothHandled() {
        let coordinator = DropInstallCoordinator()
        let jar = url("qwqTests-\(UUID().uuidString).jar")

        coordinator.handle(urls: [jar, url("整合包.zip")])

        XCTAssertTrue(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "整合包")
        XCTAssertNotNil(LauncherSettings.shared.launchErrorMessage)
        XCTAssertFalse(coordinator.showModInstallSheet)
    }

    // MARK: - 取消与确认

    /// 取消整合包安装只关弹窗；暂存数据保留（下次确认仍指向同一文件）
    func testCancelModpackInstallClosesSheetOnly() {
        let coordinator = DropInstallCoordinator()
        coordinator.handle(urls: [url("整合包.zip")])
        XCTAssertTrue(coordinator.showModpackInstallSheet)

        coordinator.cancelModpackInstall()

        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "整合包",
                       "取消只关弹窗，不清暂存名（当前实现的既有行为）")
    }

    /// 无暂存文件时确认整合包安装是 no-op：不落盘、不提示、不崩溃
    func testConfirmModpackInstallWithoutStagedFileIsNoOp() {
        let coordinator = DropInstallCoordinator()

        coordinator.confirmModpackInstall(folderURL: url("目标目录"))

        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertEqual(LauncherSettings.shared.javaPopupMessage, idlePopupMessage,
                       "无暂存整合包时不得产生任何成功/失败提示")
        XCTAssertFalse(LauncherSettings.shared.showLaunchAlert)
    }

    /// 无暂存模组时确认模组安装不得报「已安装到 N 个实例」
    func testConfirmModInstallWithoutStagedFileReportsNothing() {
        let coordinator = DropInstallCoordinator()

        coordinator.confirmModInstall(instances: [])

        XCTAssertFalse(coordinator.showModInstallSheet)
        XCTAssertEqual(LauncherSettings.shared.javaPopupMessage, idlePopupMessage,
                       "guard 失效会让用户看到「模组已安装到 0 个实例」这类假成功文案")
        XCTAssertFalse(LauncherSettings.shared.showJavaPopup)
    }

    /// 弹窗未展示时取消模组安装是幂等 no-op
    func testCancelModInstallIsIdempotentWhenSheetHidden() {
        let coordinator = DropInstallCoordinator()

        coordinator.cancelModInstall()
        coordinator.cancelModInstall()

        XCTAssertFalse(coordinator.showModInstallSheet)
        XCTAssertTrue(coordinator.modInstallInstances.isEmpty)
        XCTAssertEqual(coordinator.pendingModName, "")
    }

    // MARK: - 拖拽入口返回值

    /// 没有 file-url 内容的 provider 一律不接受（含 Text 类型）
    func testHandleProvidersRejectsNonFileContent() {
        let coordinator = DropInstallCoordinator()

        XCTAssertFalse(coordinator.handle(providers: []), "空 provider 列表不得被视为已接受")
        XCTAssertFalse(coordinator.handle(providers: [NSItemProvider()]),
                       "空 provider 不含 public.file-url，必须返回 false")
        XCTAssertFalse(coordinator.handle(providers: [NSItemProvider(object: "纯文本" as NSString)]),
                       "文本拖拽不得被当作文件拖入接受")

        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertFalse(coordinator.showModInstallSheet)
    }

    // MARK: - 状态发布

    /// 打开整合包弹窗时两个 @Published 字段都要通知订阅方
    func testSheetStateChangesEmitObjectWillChange() {
        let coordinator = DropInstallCoordinator()
        var emissions = 0
        let cancellable = coordinator.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        coordinator.handle(urls: [url("整合包.zip")])

        XCTAssertGreaterThanOrEqual(emissions, 2,
                                    "pendingModpackName 与 showModpackInstallSheet 各需一次通知，否则弹窗不渲染")
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. 「模组成功进入安装弹窗」分支不可覆盖：`beginModInstall` 需要
//     `ModVersionDetector.detectVersion` 返回结果且 `ModDragInstaller.findInstances`
//     命中实例，二者在实现里都是硬编码的私有依赖（`versionDetector` /
//     `settings`），没有注入点。需构造真实 jar（含 fabric.mod.json 等清单）
//     与真实版本目录才能驱动，本文件只覆盖其失败分支。
//  2. `confirmModInstall(instances:)` 的成功分支不覆盖：会真实拷贝文件到
//     `versions/<v>/mods`，需要真实游戏目录，且 `ModDragInstaller.install` 无注入点。
//  3. `confirmModpackInstall(folderURL:)` 的成功分支不覆盖：会拉起
//     `ModpackInstaller().install`，依赖真实整合包与解压流程，属集成测试范畴。
//  4. `handle(providers:)` 的 true 分支不覆盖：`DragDropHandler` 通过
//     `NSItemProvider.loadItem` 异步回调 + `DispatchQueue.main.async` 派发，
//     需要宿主 App 跑 run loop，且 `item as? Data` 的形态随系统版本变化，
//     无法在不引入时序脆弱性的前提下稳定断言。
