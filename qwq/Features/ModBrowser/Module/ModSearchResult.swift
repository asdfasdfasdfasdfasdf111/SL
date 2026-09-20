//
//  ModSearchResult.swift
//  模块化拆分：ModBrowser 模块的检索结果
//
//  `totalHits` 来自 Modrinth `search` 响应的 `total_hits`，
//  既有实现 `ModrinthSearcher.search` 已解析该字段（此前由分类页自行分页）。
//

import Foundation

/// 一页检索结果。
struct ModSearchResult: Sendable, Hashable {

    let items: [ModProject]

    /// 命中总数，用于判断是否还有后续分页
    let totalHits: Int

    /// 本次请求的偏移量
    let offset: Int

    /// 本次请求的单页数量
    let limit: Int

    /// 是否还有下一页
    var hasMore: Bool {
        offset + items.count < totalHits
    }

    static let empty = ModSearchResult(items: [], totalHits: 0, offset: 0, limit: 0)
}
