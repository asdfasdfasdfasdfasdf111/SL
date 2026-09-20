//
//  SkinModule.swift
//  模块化拆分：Skin 模块注册入口
//
//  注册的能力键：
//  - `skin.service`：对外服务（校验 / 落盘 / 资源包）
//  - `skin.decoder`：图像解码与尺寸校验（供其他模块单独复用，例如皮肤预览）
//
//  依赖：`SLModule`、`ModuleContext`、`ModuleCapabilityKey` 由 `Core/Module/SLModule.swift` 提供。
//

import Foundation

final class SkinModule: SLModule {

    let identifier: String = "skin"

    func register(in context: ModuleContext) throws {
        let decoder = DefaultSkinDecoder()
        context.register(decoder, for: ModuleCapabilityKey<SkinDecoder>("skin.decoder"))
        context.register(
            DefaultSkinService(decoder: decoder, packBuilder: DefaultSkinResourcePackBuilder()),
            for: ModuleCapabilityKey<SkinService>("skin.service")
        )
    }
}
