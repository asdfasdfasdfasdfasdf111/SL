//
//  LaunchPanelState.swift
//  模块化收口：ContentView 的启动相关界面状态（Java 提示气泡、启动失败提示）。
//
//  数据源说明：这组状态（开关 + 文案）由 `LauncherSettings` 持有，且启动流程、下载流程
//  等既有代码仍在写同一组字段。本次收口只把「根视图如何读取与驱动这组状态」搬到这里，
//  数据源保持唯一的 `LauncherSettings`，不新建第二套提示状态——否则其他模块写入后
//  根视图收不到，界面行为会变。
//
//  与 NoticeCenter 的关系：NoticeCenter 由 NoticeOverlay 渲染为窗口顶部横幅；
//  本组状态对应的是窗口内的浮动药丸（`UI/TaskPill.swift`，两套状态共用同一个组件、
//  同一锚点、同一套动画），呈现位置、样式与消失时机均不同，复用会改变可见行为，故不迁移。
//

import Foundation
import Combine

/// 根视图的启动界面状态入口。
final class LaunchPanelState: ObservableObject {

    static let shared = LaunchPanelState()

    private let settings = LauncherSettings.shared
    /// LauncherSettings 是唯一数据源，其变化需透传到本对象，否则订阅本对象的视图不重绘
    private var cancellable: AnyCancellable?

    init() {
        // ⚠️ 只转发本面板**真正暴露的这 4 个字段**，而不是 `settings.objectWillChange` 的全部变化。
        //
        // 原先的写法是 `settings.objectWillChange.sink { … objectWillChange.send() }` ——
        // 那是把 LauncherSettings 全部 19 个 `@Published` 字段的任何一次写入都转发过来。
        // 于是「在输入框里敲一个字符（写 offlineUsername）」这种与提示无关的动作，
        // 也会作废提示层（TaskPill / NoticeOverlay 一侧）的全部订阅者。
        //
        // 4 个来源字段与下面 4 个计算属性（javaPopupMessage / showJavaPopup /
        // showLaunchAlert / launchErrorMessage）一一对应，逐个订阅既不再漏、也不再多。
        // 依据：Combine 的 `@Published` 投影 `$field` 逐字段发值，可精确订阅单个字段。
        // https://developer.apple.com/documentation/combine/published
        cancellable = settings.$showLaunchAlert
            .combineLatest(settings.$showJavaPopup,
                           settings.$javaPopupMessage,
                           settings.$launchErrorMessage)
            .sink { [weak self] _, _, _, _ in
                self?.objectWillChange.send()
            }
    }

    // MARK: - Java 提示气泡

    /// 气泡文案
    var javaPopupMessage: String { settings.javaPopupMessage }

    /// 气泡开关（气泡展示结束后自身会置回 false）
    var showJavaPopup: Bool {
        get { settings.showJavaPopup }
        set { settings.showJavaPopup = newValue }
    }

    // MARK: - 启动失败提示

    /// 失败提示开关
    var showLaunchAlert: Bool {
        get { settings.showLaunchAlert }
        set { settings.showLaunchAlert = newValue }
    }

    /// 失败提示正文
    var launchErrorMessage: String? { settings.launchErrorMessage }

    /// 用户点击「确定」后清空正文（沿用既有点击即清空的行为）
    ///
    /// **只清正文、不动开关**：该语义由 `LaunchPanelStateTests` 固定（清正文不得顺带
    /// 关闭提示，否则「提示何时消失」这件事就有了两个来源）。呈现层换组件后依然成立：
    /// `TaskPill` 自己持有退场动画，动画播完才写回开关（经 `dismissError()`）。
    func clearLaunchError() {
        settings.launchErrorMessage = nil
    }

    /// 关闭失败提示：正文与开关一起复位。
    ///
    /// 与 `clearLaunchError` 的分工：后者是「清内容」，本方法是「关提示」。
    /// `TaskPill` 只负责把开关写回 false，没有系统 alert 那样的自动关闸，
    /// 故由它经 `RootOverlays` 里的 Binding 调一次本方法。
    func dismissError() {
        settings.launchErrorMessage = nil
        settings.showLaunchAlert = false
    }

    // MARK: - 投递入口（供 App 层其他协调器使用）

    /// 展示一条结果气泡提示
    func presentMessage(_ message: String) {
        settings.javaPopupMessage = message
        settings.showJavaPopup = true
    }

    /// 展示启动失败提示
    func presentError(_ message: String) {
        settings.launchErrorMessage = message
        settings.showLaunchAlert = true
    }
}
