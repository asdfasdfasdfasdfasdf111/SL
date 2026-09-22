//
//  MinecraftModule.swift
//  模块化拆分：Minecraft 模块注册入口
//
//  注册后，调用方从 `ModuleContext` 取 `minecraft.repository` 即可拿到实例快照，
//  无需再遍历 `MinecraftDirectory` 或调用 `loadInnerInstances`（后者有副作用）。
//
//  本模块当前只覆盖**只读查询**：实例的创建、启动、资源补全仍由
//  `qwq/SLCore/Minecraft/` 的既有实现承担，不在本阶段改造。
//
//  依赖：`SLModule`、`ModuleContext`、`ModuleCapabilityKey` 由 `Core/Module/SLModule.swift` 提供。
//

import Foundation

final class MinecraftModule: SLModule {

    let identifier: String = "minecraft"

    func register(in context: ModuleContext) throws {
        context.register(
            DirectoryScanningMinecraftRepository(),
            for: ModuleCapabilityKey<MinecraftRepository>("minecraft.repository")
        )
    }
}
