//
//  ThemeRepository.swift
//  模块化拆分：主题数据来源协议与最小实现
//
//  颜色值复用 `AppSettingsStore.accentColor`，**不新建存储**：
//  `AppSettingsStore` 已由 `SettingsModule` 注册为能力键 `settings.store`，
//  本仓储只是把它读出来并转成主题模型。
//

import SwiftUI

// MARK: - 仓储协议

/// 主题数据的唯一出入口。
///
/// 上层不直接读 `AppSettingsStore.accentColor` / `ThemeManager.shared.accentColor`，
/// 统一经由此协议获取。
protocol ThemeRepository: Sendable {

    /// 当前生效的主题。
    func current() async -> ThemeDefinition
}

// MARK: - 最小实现

/// 从 `AppSettingsStore` 读取当前强调色。
///
/// `AppSettingsStore` 是 UI 层可变状态（`ObservableObject`），读取放在主线程执行；
/// `ThemeDefinition` 与 `Color` 均为 `Sendable`，返回值可安全跨任务传递。
struct AppSettingsThemeRepository: ThemeRepository {

    func current() async -> ThemeDefinition {
        let color = await MainActor.run { AppSettingsStore.shared.accentColor }
        return ThemeDefinition(accentColor: color)
    }
}
