//
//  GameModule.swift
//  Game 模块注册入口
//
//  注册后，调用方从 `ModuleContext` 取 `game.versionCatalog` 即可拿到版本清单服务，
//  取 `game.versionFilter` 拿到分类过滤用例（无状态值类型，注册的是可直接复用的默认实例）。
//
//  接线状态：`AppModuleBootstrap`（Core/Module/ModuleRegistry.swift）当前只登记 `SettingsModule`，
//  本模块按「先建骨架、后接线」的阶段约定**未接线**，视图侧默认直接构造默认实现
//  （与 `ModBrowserModule` 未接线前的做法一致）。
//
//  依赖：`SLModule`、`ModuleContext`、`ModuleCapabilityKey` 由 `Core/Module/SLModule.swift` 提供。
//

import Foundation

/// Game（版本浏览与选择）模块注册入口。
final class GameModule: SLModule {

    let identifier: String = "game"

    func register(in context: ModuleContext) throws {
        context.register(DefaultVersionCatalogService(), for: ModuleCapabilityKey<VersionCatalogService>("game.versionCatalog"))
        context.register(VersionFilterUseCase(), for: ModuleCapabilityKey<VersionFilterUseCase>("game.versionFilter"))
    }
}
