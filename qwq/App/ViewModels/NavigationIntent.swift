//
//  NavigationIntent.swift
//  菜单栏命令 → 主界面导航的传递通道。
//
//  为什么需要它：分类选中态 `NavigationState` 由 `ContentView` 以 `@StateObject` 持有
//  （窗口局部状态），而菜单栏命令必须声明在 `App` 的 `.commands { }` 里（Scene 级），
//  两者不在同一视图树中 —— 菜单点不到 `NavigationState`。
//  这里用「请求 → 消费」的单槽中转：菜单写入下标，`ContentView` 订阅后应用到自己的
//  `NavigationState`，不复制、不共享导航状态本身。
//
//  隔离约定与 `NoticeCenter` 一致（本工程已验证过的模式）：
//  `shared` 与写入口都是 `nonisolated`（菜单命令的 action 闭包不保证在主 actor 上），
//  内部 hop 到 MainActor 再改 `@Published`。
//

import SwiftUI
import Combine

/// 菜单栏命令 → 主界面导航的单槽请求通道。
@MainActor
final class NavigationIntent: ObservableObject {

    /// 非隔离单例：菜单命令的 action 闭包可能不在主 actor 上，需要直接拿到实例再走 `requestCategory`。
    nonisolated static let shared = NavigationIntent()

    /// 待处理的分类切换请求（分类在画布中的下标）；`nil` 表示无待处理请求。
    @Published private(set) var pendingCategoryIndex: Int?

    private nonisolated init() {}

    /// 请求切换到第 `index` 个分类。**可在任意线程调用**。
    nonisolated func requestCategory(at index: Int) {
        Task { @MainActor in self.apply(index) }
    }

    /// 请求已被处理，清空单槽。
    /// 调用方在应用完请求后必须调用，否则同一请求会在后续重绘中重复生效。
    @MainActor
    func consume() {
        pendingCategoryIndex = nil
    }

    /// 下标校验必须在主 actor 上做：`Category.all` 是 MainActor 隔离的（工程默认隔离）。
    @MainActor
    private func apply(_ index: Int) {
        guard index >= 0, index < Category.all.count else { return }
        pendingCategoryIndex = index
    }
}
