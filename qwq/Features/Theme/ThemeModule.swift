//
//  ThemeModule.swift
//  模块化拆分：Theme 模块注册入口
//
//  注册的能力键：
//  - `theme.service`：对外服务（当前只读）
//  - `theme.repository`：数据来源，便于其他模块只取颜色而不引入服务层
//
//  依赖：`SLModule`、`ModuleContext`、`ModuleCapabilityKey` 由 `Core/Module/SLModule.swift` 提供。
//

import Foundation

final class ThemeModule: SLModule {

    let identifier: String = "theme"

    func register(in context: ModuleContext) throws {
        let repository = AppSettingsThemeRepository()
        context.register(repository, for: ModuleCapabilityKey<ThemeRepository>("theme.repository"))
        context.register(DefaultThemeService(repository: repository), for: ModuleCapabilityKey<ThemeService>("theme.service"))
    }
}
