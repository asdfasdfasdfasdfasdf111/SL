//
//  ItemFilter.swift
//  模块化拆分：搜索过滤谓词纯逻辑。
//  合并 GameViews.applyFilter 中「游戏版本页」与「本地目录」两处重复过滤谓词：
//  tags 为空时完整谓词自动退化为「标题 + 简介」匹配，行为与简化版完全等价。
//  零状态零副作用。
//
//  ⚠️ 标注 `nonisolated`：批量过滤（filterItems）设计在**后台线程**跑——上一版
//  在主线程过滤 12 万条目录，中文搜索一次命中多个候选词就把整个 App 卡出
//  风火轮（用户实测）。本类型是纯函数集合，无任何共享状态，脱离主 actor 语义正确。
//

import Foundation

nonisolated enum ItemFilter {
    /// 单查询谓词：标题 / 简介 / 标签（含中文标签映射表反向匹配）
    static func matches(_ item: DownloadedItem, query: String) -> Bool {
        matchesText(item, query: query) ||
        ModrinthTagMap.contains { $1 == query && item.tags.contains($0) }
    }

    /// 多候选词谓词（中文搜索）：任一候选词命中即命中；已翻译的中文副标题
    /// 只对 `originalQuery`（中文原词）匹配。小数据量场景用；12 万条的本地目录
    /// 请走 `filterItems`（它把反查预计算提到循环外）。
    static func matchesAny(_ item: DownloadedItem,
                           queries: [String],
                           originalQuery: String,
                           translatedSubtitle: String?) -> Bool {
        if queries.contains(where: { matches(item, query: $0) }) { return true }
        guard let translatedSubtitle, !originalQuery.isEmpty else { return false }
        return translatedSubtitle.localizedCaseInsensitiveContains(originalQuery)
    }

    /// 「中文译名 → 英文键」的反查预计算：对候选词集合**一次**遍历映射表，
    /// 得到需要反查的英文键集合。逐条目扫描映射表是 12 万条过滤的主要开销。
    static func precomputedTagKeys(for queries: [String]) -> Set<String> {
        Set(queries.flatMap { query in
            ModrinthTagMap.filter { $1 == query }.map { $0.key }
        })
    }

    /// 批量过滤：本地目录（12 万条）的后台过滤入口。
    /// 与 `matchesAny` 同语义，但反查键只预计算一次、逐条目只做纯 contains。
    /// `translatedSubtitles` 是卡片已翻译副标题缓存（中文），参与对原词的匹配。
    static func filterItems(in items: [DownloadedItem],
                            queries: [String],
                            originalQuery: String,
                            translatedSubtitles: [String: String]) -> [DownloadedItem] {
        let tagKeys = precomputedTagKeys(for: queries)
        return items.filter { item in
            if queries.contains(where: { matchesText(item, query: $0) }) { return true }
            if !tagKeys.isEmpty, item.tags.contains(where: { tagKeys.contains($0) }) { return true }
            if !originalQuery.isEmpty,
               let translated = translatedSubtitles[item.id],
               translated.localizedCaseInsensitiveContains(originalQuery) { return true }
            return false
        }
    }

    /// 纯文本匹配（标题 / 简介 / 标签字面量），不含映射表反查 —— 供批量路径复用
    private static func matchesText(_ item: DownloadedItem, query: String) -> Bool {
        item.name.localizedCaseInsensitiveContains(query) ||
        item.subtitle.localizedCaseInsensitiveContains(query) ||
        item.tags.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
