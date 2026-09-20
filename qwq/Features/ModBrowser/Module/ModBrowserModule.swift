//
//  ModBrowserModule.swift
//  模块化拆分：ModBrowser 模块注册入口
//
//  注册后，调用方从 `ModuleContext` 取 `modbrowser.service` 即可拿到 `ModBrowserService`，
//  用例层（`ModSearchUseCase` / `ModInstallUseCase`）由调用方用该服务构造，
//  与 `JavaModule` 只注册 resolver、不注册用例的做法一致。
//
//  依赖：`SLModule`、`ModuleContext`、`ModuleCapabilityKey` 由 `Core/Module/SLModule.swift` 提供。
//

import Foundation

final class ModBrowserModule: SLModule {

    let identifier: String = "modbrowser"

    func register(in context: ModuleContext) throws {
        context.register(DefaultModBrowserService(), for: ModuleCapabilityKey<ModBrowserService>("modbrowser.service"))
    }
}
