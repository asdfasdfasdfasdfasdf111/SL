//
//  ModSearchRequest.swift
//  模块化拆分：ModBrowser 模块的检索入参
//
//  字段严格对齐既有检索入口 `ModrinthSearcher.search(type:label:query:offset:limit:)`
//  ——分类页当前走的就是这条管线，它只支持按 project_type 检索，
//  不携带 loader / 游戏版本 facets。因此本模型不提供 loader / gameVersion 过滤：
//  写了也无人实现，属"凭空发明能力"。加载器与游戏版本过滤只在版本查询
//  （`ModBrowserService.versions`）与安装用例（`ModInstallUseCase`）中生效，那里接口确实支持。
//

import Foundation

/// 一次 Modrinth 检索的输入。
struct ModSearchRequest: Sendable, Hashable {

    /// 关键词，空串表示该分类下的默认列表
    let query: String

    /// 项目类型，映射为 Modrinth 的 project_type facet
    let projectType: ModProjectType

    /// 偏移量（分页起点）
    let offset: Int

    /// 单页数量。既有分类页取 30（`ModrinthSearcher.search` 的默认值），此处显式传入。
    let limit: Int

    init(query: String = "", projectType: ModProjectType, offset: Int = 0, limit: Int = 30) {
        self.query = query
        self.projectType = projectType
        self.offset = offset
        self.limit = limit
    }
}

extension ModSearchRequest {

    /// 下一页请求：偏移量顺推一页。
    func nextPage() -> ModSearchRequest {
        ModSearchRequest(query: query, projectType: projectType, offset: offset + limit, limit: limit)
    }
}
