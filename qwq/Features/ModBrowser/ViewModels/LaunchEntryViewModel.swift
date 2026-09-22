//
//  LaunchEntryViewModel.swift
//  模块化收口：「启动」分类页（CategoryContentView）启动按钮入口决策的唯一持有者。
//
//  收口范围：
//  - 启动前置校验：未选择游戏版本 → 提示「请先在「游戏」分类中选择一个版本」并终止；
//  - 重复启动拦截：启动中再次点击不动（与收口前同一守卫条件）；
//  - 校验通过后转交 `LaunchCoordinator.start`（版本/用户名再校验 → 皮肤资源包准备 →
//    构造 LaunchRequest → 订阅启动事件 → 会话登记，全部已在 LaunchCoordinator 内完成）。
//
//  刻意留在视图层的部分：
//  - `isUsernameFocused = false`（@FocusState 只能在视图内写）；
//  - 头像皮肤相关的一切（归 LaunchAvatarSkinViewModel）；
//  - 皮肤文件变更 / 版本变更 / 版本选中通知的订阅点与转发；
//  - 关闭按钮、「关闭会话」通知的转发（均为对 LaunchCoordinator 的意图转发，不含决策）。
//
//  为什么单独成文件而不并入 LaunchAvatarSkinViewModel：后者职责是头像皮肤数据管道，
//  与启动入口校验无交集；并入会让「皮肤」类承担启动门禁语义，名称与职责不再对应。
//
//  依赖来源说明：收口前视图分别经 @EnvironmentObject（settings）与注入（sessionManager）读取，
//  注入点即 `LauncherSettings.shared` / `LaunchSessionManager.shared`（见 ContentView），
//  故本类型内直接引用同一单例对象，取值语义不变。
//
//  隔离标注依据：SwiftUI《View》——被全局 actor 标注的协议，其遵循类型推断为该 actor 隔离。
//  收口前上述决策位于 CategoryContentView（View）内，标注 @MainActor 后隔离语义与收口前相同。
//  官方链接：https://developer.apple.com/documentation/swiftui/view
//  官方链接：https://developer.apple.com/documentation/swiftui/stateobject
//

import Foundation
import Combine

@MainActor
final class LaunchEntryViewModel: ObservableObject {

    private let settings = LauncherSettings.shared
    private let sessionManager = LaunchSessionManager.shared
    /// 提示统一走启动界面状态的投递入口（与 DropInstallCoordinator 做法一致）
    private let launchPanel = LaunchPanelState.shared

    /// 启动按钮的入口决策（语句顺序与收口前逐字一致：版本校验 → 启动中拦截 → 转交编排）。
    ///
    /// 未选择版本时提示后**终止**，不进入启动中判定；启动中重复点击静默返回（不重复提示）。
    func requestLaunch() {
        guard !settings.selectedMinecraftVersion.isEmpty else {
            launchPanel.presentError("请先在「游戏」分类中选择一个版本")
            return
        }
        guard !sessionManager.isLaunching else { return }
        LaunchCoordinator.start(settings: settings, sessionManager: sessionManager)
    }
}
