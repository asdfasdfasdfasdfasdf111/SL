//
//  CommunityNameResolver.swift
//  中文关键词 → MC 百科（mcmod.cn）定译名候选。
//
//  为什么需要它：本地目录的名称/简介是 Modrinth 英文原文，机器翻译（SearchTranslator）
//  译不出社区约定俗成的模组名 —— 例：搜「地平线」机翻给不出 "Distant Horizons"。
//  MC 百科（MCBBS 译名标准化工作的实际继承者）的搜索页标题里，词条主标题就带着
//  定译名对应的英文名。
//
//  ⚠️ 中文名只信搜索页标题的「中文 (English)」配对形态（如「高清修复 (OptiFine)」），
//  且过长度/标点校验。**不要**去抓资料页正文：页头那排 `figcaption` 是轮播图库的
//  图注、内容随刷新轮换（Distant Horizons 词条有 17 个，抓到的可能是「这张照片是
//  在渲染距离 12/512 下拍摄的」这种截图说明 —— 用户实测踩中，卡片名整个变成一句
//  话）。许多词条（如 DH）的百科主标题本身就是英文，页面上不存在稳定的中文名字段，
//  这类模组卡片保持英文名；中文**搜索**不受影响（英文名照常作为过滤候选词）。
//
//  调用约定：仅在中文查询时调用（一次搜索至多一次请求）；请求失败或无结果
//  返回空数组且**不缓存空结果**（与 SearchTranslator 同一约定，网络抽风不污染缓存）。
//

import Foundation

nonisolated enum CommunityNameResolver {

    /// 一个模组的定译名候选：`english` 是目录里能 substring 命中的英文名，
    /// `chinese` 是从「中文 (English)」标题解析出的定译中文名
    ///（校验通过才有值；nil 时该候选只用于过滤，不改卡片显示名）。
    struct ResolvedName: Sendable {
        let english: String
        let chinese: String?
    }

    /// 候选缓存（中文原词 → 定译名候选）。淘汰策略与 SearchTranslator 一致：
    /// 满 100 条砍掉字典序前一半（粗粒度、非 LRU，换取实现极简）。
    private static var cache: [String: [ResolvedName]] = [:]
    private static let cacheLock = NSLock()

    /// 中文原词 → 定译名候选（缓存命中直接返回）。
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
        // 空结果不写缓存 —— 否则一次页面改版/抽风会让这个词永远解析不出来
        guard !anchors.isEmpty else { return [] }

        var names: [ResolvedName] = []
        var seen = Set<String>()
        for anchor in anchors {
            let name = ResolvedName(english: anchor.english, chinese: anchor.chinese)
            if seen.insert(name.english.lowercased()).inserted { names.append(name) }
            for alias in anchor.aliases {
                let aliasName = ResolvedName(english: alias, chinese: nil)
                if seen.insert(aliasName.english.lowercased()).inserted { names.append(aliasName) }
            }
        }
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

    /// 搜索页的一条结果：剥好前缀的英文名 + 「中文 (English)」配对的中文名 + 括号别名。
    struct Anchor: Sendable {
        let english: String
        let chinese: String?
        let aliases: [String]
    }

    /// 从搜索页 HTML 抽取资料页锚（纯函数，供单测）。
    ///
    /// 页面结构：每条结果 `…href="https://www.mcmod.cn/class/5009.html">[DH] Distant Horizons</a>…`，
    /// 标题里可能混有 `<em>` 关键词高亮与 `&amp;` 等实体；页脚的「地址」行也是同一批
    /// class 链接（锚文本是 URL 本身），按「候选名不得长得像 URL」排除。
    static func extractAnchors(fromSearchHTML html: String) -> [Anchor] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href="(?:https?://(?:www\.)?)?mcmod\.cn/class/\d+\.html"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators]) else { return [] }

        var seenURL = Set<String>()
        var anchors: [Anchor] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let urlRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { continue }
            let url = String(html[urlRange])
            guard seenURL.insert(url).inserted else { continue }

            let title = cleanTitle(String(html[textRange]))
            // 页脚「地址」行的锚文本是 URL 本身，直接排除
            guard !title.isEmpty, !title.lowercased().contains("mcmod.cn") else { continue }

            // 「中文 (English)」配对：括号在末尾、括号前是校验通过的中文 ⇒ 括号内是
            // 目录里能命中的英文名、括号前是定译中文名。其余形态：整个标题作为
            // 英文候选，括号内容降级为纯过滤别名。
            var english = title
            var chinese: String?
            var aliases: [String] = []
            if let parenRegex = try? NSRegularExpression(pattern: #"^(.*?)\s*\(([^)]+)\)\s*$"#,
                                                         options: [.dotMatchesLineSeparators]),
               let m = parenRegex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
               let baseRange = Range(m.range(at: 1), in: title),
               let innerRange = Range(m.range(at: 2), in: title) {
                let base = String(title[baseRange]).trimmingCharacters(in: .whitespaces)
                let inner = String(title[innerRange]).trimmingCharacters(in: .whitespaces)
                if isValidChineseName(base) {
                    english = inner
                    chinese = base
                } else {
                    aliases.append(inner)
                }
            }
            anchors.append(Anchor(english: english, chinese: chinese, aliases: aliases))
            if anchors.count >= 10 { break }
        }
        return anchors
    }

    /// 定译中文名校验：必须是「短、含汉字、不带句子标点」的名词性短语。
    /// 图注/截图说明（如「这张照片是在渲染距离 12 和 512 下拍摄的」）靠长度与
    /// 句读标点挡在门外 —— 一旦放进去，卡片显示名会整句变成图注（用户实测）。
    private static func isValidChineseName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 24 else { return false }
        // 必须含汉字（纯拉丁名走不了中文显示名）
        guard text.range(of: #"[一-鿿]"#, options: .regularExpression) != nil else { return false }
        // 句读标点出现即拒绝：模组名不会是一句话
        guard text.range(of: #"[。！？…，；、]"#, options: .regularExpression) == nil else { return false }
        return true
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
}
