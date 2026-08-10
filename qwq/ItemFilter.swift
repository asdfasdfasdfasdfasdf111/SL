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
}
