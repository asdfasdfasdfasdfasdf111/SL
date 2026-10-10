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
//     链路有两段：`AppSettingsStore` →（桥接订阅）→ `LauncherSettings` →（归口）→ `LaunchPanelState`。
//     本文件两段都覆盖：`testExternalSettingsWriteIsForwardedToPanel` 走非持久化字段，
//     `testPersistedFieldWriteIsForwardedToStore` 走持久化字段的**两段**
//     （绕过兼容层直写存储点验桥接；再经兼容层写验转发）；
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

    /// 持久化字段（转发到 `AppSettingsStore`）的写入同样要冒泡。
    /// 覆盖兼容层的**两段链路**，两段各用一条断言，且每条都能被单独打破：
    ///
    /// ⚠️ **不能**只写「经 `LauncherSettings` 写字段 → 本对象发通知」就收工 —— 那条路即使桥接断开，
    /// 也可能被兼容层自己的 `@Published` 兜住，断言恒真（本项目反复出现的「假绿」）。
    /// 要隔离出**桥接订阅**这一段，必须**绕过 `LauncherSettings` 直接写存储点**：
    /// 此时兼容层自己没有任何写入路径，唯一可能的通知来源就是这条桥接。
    ///
    /// 发射次数为 **1**（2026-09-25 实测，非推测）：`store` 的 `@Published` 会先在
    /// `store.objectWillChange` 上发一次，但那是**另一个对象**的通知，不会串到本对象；
    /// 本对象只收到桥接转发来的那一次。
    ///
    /// 值转发用**哨兵值**：写回同值的话，兼容层即使各自持副本，两份值也永远相等，
    /// 断言恒真、抓不到分叉。
    ///
    /// ⚠️ 本用例会写持久化字段，因此整段跑在**一次性偏好域**里（见
    /// `qwqTests/ScratchPreferenceDomain.swift`）：过去用「哨兵 + `defer` 还原」，
    /// 而宿主 abort 会让 `defer` 不执行、把哨兵留在用户真实设置里（当时为此刻意挑
    /// `appliedSkinHash` 这种「弄脏了也自愈」的字段）。重定向后不再依赖还原动作，
    /// 也就不必再迁就字段无害性。
    func testPersistedFieldWriteIsForwardedToStore() async throws {
        try await withScratchSettingsPersistence { scratch in
            let settings = LauncherSettings.shared
            let store = AppSettingsStore.shared
            let current = settings.selectedMinecraftVersion

            // —— 第一段：桥接订阅 `AppSettingsStore.objectWillChange` → `LauncherSettings.objectWillChange`
            var relayEmissions = 0
            let relayCancellable = settings.objectWillChange.sink { _ in relayEmissions += 1 }
            defer { relayCancellable.cancel() }

            // 绕过兼容层，直接写唯一存储点：兼容层自身不参与这次写入。
            store.selectedMinecraftVersion = current

            XCTAssertEqual(relayEmissions, 1,
                           "存储点变更未冒泡到兼容层：桥接订阅断了，订阅设置的视图会静默停止重绘")
            XCTAssertEqual(scratch.string(forKey: UDK.selectedMinecraftVersion), current,
                           "存储点写入没有落到偏好域")

            // —— 第二段：兼容层的写入要发出通知（视图刷新依赖它）
            var forwardEmissions = 0
            let forwardCancellable = settings.objectWillChange.sink { _ in forwardEmissions += 1 }
            defer { forwardCancellable.cancel() }

            settings.selectedMinecraftVersion = current

            XCTAssertEqual(forwardEmissions, 1,
                           "写兼容层未触发通知：setter 没有转发到存储点（转发断掉时视图不重绘）")

            // —— 第三段：值必须真的落到存储点（兼容层不再自持副本）。
            // 用哨兵值区分「转发」与「各存一份」：写回同值的话两种实现永远相等、断言恒真。
            // 哨兵只落进这块一次性偏好域，所以不需要还原，也不必再迁就字段无害性。
            let sentinel = store.appliedSkinHash == "__SL_FORWARD_PROBE__"
                ? "SLPROBE0" : "__SL_FORWARD_PROBE__"

            settings.appliedSkinHash = sentinel

            XCTAssertEqual(store.appliedSkinHash, sentinel,
                           "写兼容层没有落到存储点：兼容层又自持了一份副本，两处会分叉")
            XCTAssertEqual(settings.appliedSkinHash, sentinel,
                           "兼容层读到的不是存储点的值")
            XCTAssertEqual(scratch.string(forKey: UDK.appliedSkinHash), sentinel,
                           "哨兵必须落进注入的偏好域（否则隔离没生效，写的是用户真实设置）")
        }
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. 气泡的实际呈现（`TaskPill` 的展示时长、开关写回时机）
//     依赖 SwiftUI 视图生命周期，无 UI 承载时不可验证。
//  2. `LaunchPanelState` 与 `NoticeCenter` 的分工（顶部横幅 vs 窗口内浮层）
//     属于视觉呈现差异，无断言入口。
