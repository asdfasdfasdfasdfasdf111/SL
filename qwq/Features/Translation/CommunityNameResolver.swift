//
//  CommunityNameResolver.swift
//  中文关键词 → MC 百科（mcmod.cn）资料页的定译英文名。
//
//  为什么需要它：本地目录的名称/简介是 Modrinth 英文原文，机器翻译（SearchTranslator）
//  译不出社区约定俗成的模组名 —— 例：搜「地平线」机翻给不出 "Distant Horizons"。
//  MC 百科（MCBBS 译名标准化工作的实际继承者）的搜索页里，资料页标题就带着定译名
//  对应的英文名，抽出来作为候选词交给 ItemFilter.matchesAny 过滤。
//
//  调用约定：仅在中文查询零命中时调用（一次搜索至多一次请求）；请求失败或无结果
//  返回空数组且**不缓存空结果**（与 SearchTranslator 同一约定，网络抽风不污染缓存）。
//

import Foundation

nonisolated enum CommunityNameResolver {
    /// 候选名缓存（中文原词 → 候选英文名）。淘汰策略与 SearchTranslator 一致：
    /// 满 100 条砍掉字典序前一半（粗粒度、非 LRU，换取实现极简）。
    private static var cache: [String: [String]] = [:]
    private static let cacheLock = NSLock()

    /// 检索结果页里抽出的候选英文名（缓存命中直接返回）。
    static func englishNames(for query: String) async -> [String] {
        if let cached = cacheLock.withLock({ cache[query] }) {
            return cached
        }

        var components = URLComponents(string: "https://search.mcmod.cn/s")!
        components.queryItems = [URLQueryItem(name: "key", value: query)]
        guard let url = components.url else { return [] }
        var req = URLRequest(url: url)
        req.setLaunchUserAgent()
        req.timeoutInterval = 10
        guard let (data, _) = try? await AppContext.shared.apiSession.data(for: req),
              let html = String(data: data, encoding: .utf8) else { return [] }

        let names = extractNames(fromSearchHTML: html)
        // 空结果不写缓存 —— 否则一次页面改版/抽风会让这个词永远解析不出来
        guard !names.isEmpty else { return [] }

        cacheLock.withLock {
            if cache.count >= 100 {
                let sortedKeys = cache.keys.sorted()
                for k in sortedKeys.prefix(50) { cache.removeValue(forKey: k) }
            }
            cache[query] = names
        }
        return names
    }

    /// 从搜索页 HTML 抽取候选名（纯函数，供单测）。
    ///
    /// 页面结构：每条结果 `…href="https://www.mcmod.cn/class/5009.html">[DH] Distant Horizons</a>…`，
    /// 标题里可能混有 `<em>` 关键词高亮与 `&amp;` 等实体；页脚的「地址」行也是同一批
    /// class 链接（锚文本是 URL 本身），按「候选名不得长得像 URL」排除。
    static func extractNames(fromSearchHTML html: String) -> [String] {
        // 只认指向 /class/<id>.html（模组资料页）的锚，其它板块（教程/作者/整合包分类目录）不取
        guard let regex = try? NSRegularExpression(
            pattern: #"href="(?:https?://(?:www\.)?)?mcmod\.cn/class/\d+\.html"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators]) else { return [] }

        var seen = Set<String>()
        var names: [String] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let textRange = Range(match.range(at: 1), in: html) else { continue }
            for candidate in candidates(fromTitle: String(html[textRange])) {
                let key = candidate.lowercased()
                if seen.insert(key).inserted {
                    names.append(candidate)
                }
            }
            if names.count >= 10 { break }
        }
        return names
    }

    /// 单个锚文本 → 候选名列表。剥 `<em>` 高亮标签、解 HTML 实体、去「[缩写] 」前缀；
    /// 「A (B)」形式的标题把括号里的内容单独成候选（B 往往才是 Modrinth 上的项目名）。
    private static func candidates(fromTitle raw: String) -> [String] {
        var text = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">",
                               "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 「[缩写] 本名」前缀：摘掉才 substring 匹配得上目录里的本名
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        // 页脚「地址」行的锚文本是 URL 本身（含 mcmod.cn），直接排除；
        // 其余候选一律保留 —— 纯中文标题对英文目录匹配不上，无害。
        guard !text.isEmpty, !text.lowercased().contains("mcmod.cn") else { return [] }

        var result = [text]
        // 括号别名：「A (B)」→ 把 B 也单独当候选
        if let parenRegex = try? NSRegularExpression(pattern: #"\(([^)]+)\)"#) {
            let range = NSRange(text.startIndex..., in: text)
            for match in parenRegex.matches(in: text, range: range) {
                guard let inner = Range(match.range(at: 1), in: text) else { continue }
                let alias = String(text[inner]).trimmingCharacters(in: .whitespaces)
                if !alias.isEmpty { result.append(alias) }
            }
        }
        // 至少要有一个英文字母：纯中文标题对英文目录匹配不上，不占候选位
        return result.filter { $0.rangeOfCharacter(from: .letters) != nil }
    }
}
