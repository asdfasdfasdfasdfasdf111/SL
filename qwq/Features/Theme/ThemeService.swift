//
//  ThemeService.swift
//  模块化拆分：Theme 模块对外服务协议与默认实现
//
//  职责边界：本服务当前**只读**。
//  主题的写入（切换强调色）目前仍由 `ThemeManager.accentColor` 的 didSet 完成，
//  其收窄属设置模块职责，且 `AppSettingsStore.swift` 本轮不允许修改，
//  因此写入能力不在本阶段引入。
//

import SwiftUI

// MARK: - 服务协议

/// 主题能力的唯一入口。
protocol ThemeService: Sendable {

    /// 当前生效的主题（强调色取自 `AppSettingsStore`）。
    func currentTheme() async -> ThemeDefinition
}

// MARK: - 默认实现

/// 由仓储提供数据，本类型只做门面。
struct DefaultThemeService: ThemeService {

    private let repository: ThemeRepository

    init(repository: ThemeRepository = AppSettingsThemeRepository()) {
        self.repository = repository
    }

    func currentTheme() async -> ThemeDefinition {
        await repository.current()
    }
}
