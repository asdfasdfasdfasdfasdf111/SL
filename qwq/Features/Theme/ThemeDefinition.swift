//
//  ThemeDefinition.swift
//  模块化拆分：主题模型
//
//  工程里与"主题"相关的现状：
//  - `qwq/Features/Settings/ThemeManager.swift`：`ThemeManager.accentColor`（历史兼容层，直接写 UserDefaults）
//  - `qwq/Features/Settings/AppSettingsStore.swift`：`accentColor`（当前唯一存储点，设置模块已注册为能力）
//
//  因此本模型只承载**强调色**这一项真实可配内容。
//  不虚构主题目录、明暗变体、字体、圆角等尚不存在的配置。
//
//  历史：`qwq/SLCore/Stubs.swift` 原有 `Theme` 桩类（仅 `id` 字段、`load(id:)` 只做对象构造、
//  不参与渲染），经全库普查确认零引用后，已于 2026-09 随兼容层其余死符号一并删除。
//

import SwiftUI

/// 主题定义。
///
/// 值语义、可跨任务传递。当前等于"一组强调色"：
/// 颜色值一律来自 `AppSettingsStore.accentColor`，本类型不持有任何存储。
struct ThemeDefinition: Sendable, Hashable {

    /// 强调色
    let accentColor: Color
}
