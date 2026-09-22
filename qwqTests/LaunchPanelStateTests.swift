//
//  LaunchPanelStateTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//  1. 单一数据源：`LaunchPanelState` 只是 `LauncherSettings` 的视图侧归口，自身不持有第二套状态。
//     因此「两个实例读写同一组字段」必须成立——若改成各自存储，其他模块（启动流程、下载流程）
//     写 `LauncherSettings` 后根视图将收不到，界面行为会变；
//  2. 透传：`LauncherSettings` 的任何变化必须冒泡到 `LaunchPanelState.objectWillChange`，
//     否则订阅它的视图不重绘（外部模块直接写设置字段的场景同样要生效）；
//  3. 文案与开关语义：`presentMessage` 展示气泡、`presentError` 展示失败提示；
//     `clearLaunchError` 只清正文不清开关（沿用「点击确定即清空」的既有行为）；
//  4. `showJavaPopup` / `showLaunchAlert` 开关可读可写，气泡自我关闭依赖写回 false。
//
//  被测：App/ViewModels/LaunchPanelState.swift
//

import XCTest
import Combine
@testable import qwq

final class LaunchPanelStateTests: XCTestCase {

    /// 本文件用到的占位文案，避免与真实默认值耦合
    private let placeholder = "占位文案"

    override func setUp() {
        super.setUp()
        resetSettings()
    }

    override func tearDown() {
        resetSettings()
        super.tearDown()
    }

    private func resetSettings() {
        let settings = LauncherSettings.shared
        settings.javaPopupMessage = placeholder
        settings.showJavaPopup = false
        settings.showLaunchAlert = false
        settings.launchErrorMessage = nil
    }

    // MARK: - 单例与数据源

    /// shared 是稳定单例
    func testSharedIsSingleton() async {
        XCTAssertTrue(LaunchPanelState.shared === LaunchPanelState.shared)
    }

    /// 两个实例必须共享同一份底层设置（唯一数据源契约）
    func testTwoInstancesShareSingleSettingsSource() async {
        let first = LaunchPanelState()
        let second = LaunchPanelState()

        first.presentMessage("已切换到 Java 21")

        XCTAssertEqual(second.javaPopupMessage, "已切换到 Java 21",
                       "两个实例若各自持有状态，其他模块写入后根视图将收不到")
        XCTAssertTrue(second.showJavaPopup)

        second.presentError("启动失败：无法定位 java")
        XCTAssertEqual(first.launchErrorMessage, "启动失败：无法定位 java")
        XCTAssertTrue(first.showLaunchAlert)
    }

    // MARK: - 投递入口

    /// presentMessage 设置气泡文案并打开气泡
    func testPresentMessageSetsTextAndOpensPopup() async {
        let panel = LaunchPanelState()

        panel.presentMessage("正在下载 Java 21")

        XCTAssertEqual(panel.javaPopupMessage, "正在下载 Java 21")
        XCTAssertTrue(panel.showJavaPopup)
        XCTAssertEqual(LauncherSettings.shared.javaPopupMessage, "正在下载 Java 21")
        // 展示结果气泡不应顺带打开失败提示
        XCTAssertFalse(panel.showLaunchAlert)
    }

    /// presentError 设置失败正文并打开失败提示
    func testPresentErrorSetsTextAndOpensAlert() async {
        let panel = LaunchPanelState()

        panel.presentError("整合包安装失败: 磁盘空间不足")

        XCTAssertEqual(panel.launchErrorMessage, "整合包安装失败: 磁盘空间不足")
        XCTAssertTrue(panel.showLaunchAlert)
        XCTAssertEqual(LauncherSettings.shared.launchErrorMessage, "整合包安装失败: 磁盘空间不足")
        // 错误提示走固定弹窗，不占气泡
        XCTAssertFalse(panel.showJavaPopup)
    }

    /// 连续投递以最后一次为准
    func testLaterMessageReplacesEarlierOne() async {
        let panel = LaunchPanelState()

        panel.presentMessage("第一条")
        panel.presentMessage("第二条")

        XCTAssertEqual(panel.javaPopupMessage, "第二条")

        panel.presentError("错误一")
        panel.presentError("错误二")
        XCTAssertEqual(panel.launchErrorMessage, "错误二")
    }

    // MARK: - 开关读写的回写

    /// showJavaPopup 可读可写（气泡展示结束后由视图写回 false）
    func testShowJavaPopupRoundTrip() async {
        let panel = LaunchPanelState()

        panel.showJavaPopup = true
        XCTAssertTrue(panel.showJavaPopup)
        XCTAssertTrue(LauncherSettings.shared.showJavaPopup)

        panel.showJavaPopup = false
        XCTAssertFalse(panel.showJavaPopup)
        XCTAssertFalse(LauncherSettings.shared.showJavaPopup)
    }

    /// showLaunchAlert 可读可写
    func testShowLaunchAlertRoundTrip() async {
        let panel = LaunchPanelState()

        panel.showLaunchAlert = true
        XCTAssertTrue(panel.showLaunchAlert)
        XCTAssertTrue(LauncherSettings.shared.showLaunchAlert)

        panel.showLaunchAlert = false
        XCTAssertFalse(panel.showLaunchAlert)
        XCTAssertFalse(LauncherSettings.shared.showLaunchAlert)
    }

    // MARK: - 清空语义

    /// clearLaunchError 只清正文，不动开关（点击确定后由调用方/绑定关闭 alert）
    func testClearLaunchErrorClearsTextOnly() async {
        let panel = LaunchPanelState()
        panel.presentError("启动失败")

        panel.clearLaunchError()

        XCTAssertNil(panel.launchErrorMessage)
        XCTAssertNil(LauncherSettings.shared.launchErrorMessage)
        XCTAssertTrue(panel.showLaunchAlert, "清正文不得顺带关闭 alert，否则弹窗消失时机改变")
    }

    /// 无错误时清空是幂等的 no-op
    func testClearLaunchErrorWithoutErrorIsIdempotent() async {
        let panel = LaunchPanelState()
        XCTAssertNil(panel.launchErrorMessage)

        panel.clearLaunchError()
        panel.clearLaunchError()

        XCTAssertNil(panel.launchErrorMessage)
        XCTAssertFalse(panel.showLaunchAlert)
    }

    // MARK: - 变化透传

    /// 通过本对象投递会触发自身 objectWillChange
    func testOwnMutationsEmitObjectWillChange() async {
        let panel = LaunchPanelState()
        var emissions = 0
        let cancellable = panel.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        panel.presentMessage("文案")

        XCTAssertGreaterThanOrEqual(emissions, 1, "投递后订阅方必须收到重绘信号")
    }

    /// 外部直接写 LauncherSettings（其他模块的既有调用方式）同样要透传
    func testExternalSettingsWriteIsForwardedToPanel() async {
        let panel = LaunchPanelState()
        var emissions = 0
        let cancellable = panel.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        LauncherSettings.shared.launchErrorMessage = "外部模块写入"

        XCTAssertEqual(emissions, 1,
                       "外部写 LauncherSettings 未透传时，根视图的失败提示不会刷新")
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. 气泡的实际呈现（`TaskPill` 的展示时长、开关写回时机）
//     依赖 SwiftUI 视图生命周期，无 UI 承载时不可验证。
//  2. `LaunchPanelState` 与 `NoticeCenter` 的分工（顶部横幅 vs 窗口内浮层）
//     属于视觉呈现差异，无断言入口。
