//
//  CommunityNameResolver.swift
//  中文关键词 → MC 百科（mcmod.cn）定译名（中英文对）。
//
//  为什么需要它：本地目录的名称/简介是 Modrinth 英文原文，机器翻译（SearchTranslator）
//  译不出社区约定俗成的模组名 —— 例：搜「地平线」机翻给不出 "Distant Horizons"。
//  MC 百科（MCBBS 译名标准化工作的实际继承者）的搜索页给出资料页链接（标题即英文名），
//  资料页头部还带着定译中文名（`figcaption` 元素）——两者配对后：
//  英文名交给 ItemFilter 过滤目录，中文名用于把卡片显示名换成定译名。
//
//  调用约定：仅在中文查询时调用（一次搜索至多 1 + ≤5 次请求，后者并发）；
//  请求失败或无结果返回空数组且**不缓存空结果**（与 SearchTranslator 同一约定，
//  网络抽风不污染缓存）。
//

import Foundation

nonisolated enum CommunityNameResolver {

    /// 一个模组的定译名对：`english` 是目录里能 substring 命中的英文名，
    /// `chinese` 是 MC 百科的定译中文名（资料页缺失时为 nil，仅用于过滤）。
    struct ResolvedName: Sendable {
        let english: String
        let chinese: String?
    }

    /// 候选缓存（中文原词 → 定译名对）。淘汰策略与 SearchTranslator 一致：
    /// 满 100 条砍掉字典序前一半（粗粒度、非 LRU，换取实现极简）。
    private static var cache: [String: [ResolvedName]] = [:]
    private static let cacheLock = NSLock()
    /// 资料页补取中文名的条数上限：搜索结果前 5 条已覆盖用户要找的正主，
    /// 更多只会白拉页面（每个页面一次请求）。
    private static let classPageLimit = 5

    /// 中文原词 → 定译名对（缓存命中直接返回）。
    static func names(for query: String) async -> [ResolvedName] {
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

        let anchors = extractAnchors(fromSearchHTML: html)
        guard !anchors.isEmpty else { return [] }

        // 前 N 条资料页并发补取中文名；失败的条目 chinese 记 nil（英文名仍可过滤）
        let topAnchors = Array(anchors.prefix(classPageLimit))
        let pages = await withTaskGroup(of: (Int, ResolvedName?).self) { group in
            for (index, anchor) in topAnchors.enumerated() {
                group.addTask {
                    guard let pageHTML = await fetchPage(anchor.classURL) else {
                        return (index, ResolvedName(english: anchor.english, chinese: nil))
                    }
                    let parsed = parseClassPage(pageHTML)
                    // 页面标题剥完前缀后为空（罕见改版）时退回锚文本
                    let english = parsed.english ?? anchor.english
                    return (index, ResolvedName(english: english, chinese: parsed.chinese))
                }
            }
            var byIndex: [Int: ResolvedName] = [:]
            for await (index, name) in group { byIndex[index] = name }
            return byIndex.sorted { $0.key < $1.key }.compactMap { $0.value }
        }

        // 没补到资料页的锚（超出前 N 条 / 页面失败）→ 英文名兜底候选，别名跟在后面
        var seen = Set<String>()
        var names: [ResolvedName] = []
        func append(_ name: ResolvedName) {
            let key = name.english.lowercased()
            if seen.insert(key).inserted { names.append(name) }
        }
        pages.forEach(append)
        for anchor in anchors {
            append(ResolvedName(english: anchor.english, chinese: nil))
            for alias in anchor.aliases {
                append(ResolvedName(english: alias, chinese: nil))
            }
        }

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

    // MARK: - 搜索页解析

    /// 搜索页的一条结果：剥好前缀的英文名 + 括号别名 + 资料页地址。
    struct Anchor: Sendable {
        let english: String
        let aliases: [String]
        let classURL: String
    }

    /// 从搜索页 HTML 抽取资料页锚（纯函数，供单测）。
    ///
    /// 页面结构：每条结果 `…href="https://www.mcmod.cn/class/5009.html">[DH] Distant Horizons</a>…`，
    /// 标题里可能混有 `<em>` 关键词高亮与 `&amp;` 等实体；页脚的「地址」行也是同一批
    /// class 链接（锚文本是 URL 本身），按「候选名不得长得像 URL」排除。
    static func extractAnchors(fromSearchHTML html: String) -> [Anchor] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href="((?:https?://(?:www\.)?)?mcmod\.cn/class/\d+\.html)"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators]) else { return [] }

        var seenURL = Set<String>()
        var anchors: [Anchor] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let urlRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { continue }
            var url = String(html[urlRange])
            if url.hasPrefix("//") { url = "https:" + url }
            if !url.hasPrefix("http") { url = "https://" + url }
            guard seenURL.insert(url).inserted else { continue }

            let title = cleanTitle(String(html[textRange]))
            // 页脚「地址」行的锚文本是 URL 本身，直接排除
            guard !title.isEmpty, !title.lowercased().contains("mcmod.cn") else { continue }
            // 括号别名：「A (B)」→ B 往往才是 Modrinth 上的项目名，单独成候选
            var aliases: [String] = []
            if let parenRegex = try? NSRegularExpression(pattern: #"\(([^)]+)\)"#) {
                let parenRange = NSRange(title.startIndex..., in: title)
                for parenMatch in parenRegex.matches(in: title, range: parenRange) {
                    guard let inner = Range(parenMatch.range(at: 1), in: title) else { continue }
                    let alias = String(title[inner]).trimmingCharacters(in: .whitespaces)
                    if !alias.isEmpty { aliases.append(alias) }
                }
            }
            anchors.append(Anchor(english: title, aliases: aliases, classURL: url))
            if anchors.count >= 10 { break }
        }
        return anchors
    }

    /// 锚文本 → 干净英文名：剥 `<em>` 高亮标签、解 HTML 实体、去「[缩写] 」前缀
    private static func cleanTitle(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">",
                               "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    // MARK: - 资料页解析

    /// 资料页 HTML → (英文名, 定译中文名)。纯函数，供单测。
    ///
    /// - 英文名：`<title>[DH]Distant Horizons - MC百科|…</title>` → 剥站点后缀与「[缩写]」前缀；
    /// - 中文名：头部大图后的 `<span class="figcaption">遥远的地平线</span>`（首个定译名元素）。
    static func parseClassPage(_ html: String) -> (english: String?, chinese: String?) {
        var english: String?
        if let titleRegex = try? NSRegularExpression(pattern: #"<title>(.*?)</title>"#,
                                                     options: [.dotMatchesLineSeparators]),
           let match = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            var title = String(html[range])
            if let siteMark = title.range(of: " - MC百科") { title = String(title[..<siteMark.lowerBound]) }
            english = cleanTitle(title)
            if english?.isEmpty == true { english = nil }
        }
        var chinese: String?
        if let captionRegex = try? NSRegularExpression(pattern: #"<span class="figcaption">(.*?)</span>"#,
                                                       options: [.dotMatchesLineSeparators]),
           let match = captionRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            chinese = cleanTitle(String(html[range]))
            if chinese?.isEmpty == true { chinese = nil }
        }
        return (english, chinese)
    }

    private static func fetchPage(_ url: String) async -> String? {
        guard let url = URL(string: url) else { return nil }
        var req = URLRequest(url: url)
        req.setLaunchUserAgent()
        req.timeoutInterval = 8
        guard let (data, _) = try? await AppContext.shared.apiSession.data(for: req),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return html
    }
}
