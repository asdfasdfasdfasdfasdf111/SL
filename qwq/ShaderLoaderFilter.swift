//
//  ShaderLoaderFilter.swift
//  模块化拆分：从 ModDetailView.swift 拆出（原 detailPageContent 内联 shader 加载器过滤逻辑）
//  纯逻辑：光影页只展示 Iris/OptiFine 等光影加载器，过滤 Fabric/Forge 等模组加载器；
//  项目未声明任何加载器时回退到默认光影加载器列表。
//

import Foundation

/// 光影详情页的加载器展示过滤规则（纯逻辑，无状态）
enum ShaderLoaderFilter {
    /// 光影加载器白名单（其余加载器在光影页被过滤）
    static let shaderOnlyLoaders: Set<String> = ["iris", "optifine"]

    /// 计算某详情页实际展示的加载器列表：
    /// - 非光影页：返回项目声明的加载器（小写去重后）
    /// - 光影页：只保留白名单内的加载器；若项目未声明任何光影加载器则回退到默认列表
    static func filtered(projectLoaders: [String], pageType: DetailPageType) -> [String] {
        let rawLoaders: [String] = projectLoaders.isEmpty
            ? []
            : Array(Set(projectLoaders.map { $0.lowercased() }))
        guard pageType == .shader else { return rawLoaders }
        let fromProject = rawLoaders.filter { shaderOnlyLoaders.contains($0.lowercased()) }
        return fromProject.isEmpty ? ["iris", "optifine"] : fromProject
    }
}
