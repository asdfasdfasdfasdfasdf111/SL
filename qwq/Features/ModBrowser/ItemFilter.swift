//
//  ItemFilter.swift
//  模块化拆分：搜索过滤谓词纯逻辑。
//  合并 GameViews.applyFilter 中「游戏版本页」与「本地目录」两处重复过滤谓词：
//  tags 为空时完整谓词自动退化为「标题 + 简介」匹配，行为与简化版完全等价。
//  零状态零副作用。
//

import Foundation

enum ItemFilter {
    /// 过滤谓词：标题 / 简介 / 标签（含中文标签映射表反向匹配）
    static func matches(_ item: DownloadedItem, query: String) -> Bool {
        item.name.localizedCaseInsensitiveContains(query) ||
        item.subtitle.localizedCaseInsensitiveContains(query) ||
        item.tags.contains { $0.localizedCaseInsensitiveContains(query) } ||
        ModrinthTagMap.contains { $1 == query && item.tags.contains($0) }
    }

    /// 多候选词过滤（中文搜索专用）：本地目录的名称/简介是 Modrinth 英文原文，
    /// 中文原词通常零命中，调用方先经 `SearchTranslator` 译出英文候选词后一并传入，
    /// 任一词命中正文即命中。`translatedSubtitle` 是卡片**已翻译的中文副标题**
    /// （`CardTranslationModel` 的缓存，可能为 nil），它只对 `originalQuery`（中文原词）匹配
    /// —— 中文副标题不可能命中英文候选词，反之英文原文也匹配不到中文原词。
    /// 纯逻辑零副作用，与 `matches` 同一约定。
    static func matchesAny(_ item: DownloadedItem,
                           queries: [String],
                           originalQuery: String,
                           translatedSubtitle: String?) -> Bool {
        if queries.contains(where: { matches(item, query: $0) }) { return true }
        guard let translatedSubtitle, !originalQuery.isEmpty else { return false }
        return translatedSubtitle.localizedCaseInsensitiveContains(originalQuery)
    }
}
