import Foundation

// MARK: - 搜索翻译（中文 → 英文，自 GameViews 拆出）
// 调用 MyMemory 翻译 API，带内存缓存（上限 100 条，超出清空一半）。

enum SearchTranslator {
    /// 译文缓存（原文 → 候选词列表）。⚠️ static var、全局、无上限增长，
    /// 靠下面「满 100 条就砍掉一半」的粗粒度策略控制体积。含锁保护，可跨线程使用。
    private static var cache: [String: [String]] = [:]
    /// 保护 `cache` 的锁。不用 actor 是因为 `translate` 虽然是 async，
    /// 但希望缓存命中时**不做任何 await 跳转**（省一次调度）。
    private static let cacheLock = NSLock()

    /// 中文 → 英文候选词列表（缓存命中直接返回）。
    /// ⚠️ 过滤规则三条：丢弃空串、丢弃与原文**完全相同**的项（大小写不敏感）、丢弃重复项。
    /// 全被过滤掉时返回空数组，且**不缓存空结果**。
    static func translate(_ text: String) async -> [String] {
        if let cached = cacheLock.withLock({ cache[text] }) {
            return cached
        }

        var components = URLComponents(string: "https://api.mymemory.translated.net/get")!
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "zh|en")
        ]
        guard let url = components.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await AppContext.shared.apiSession.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matches = json["matches"] as? [[String: Any]] else { return [] }
        // 用 Set 记「见过的小写形式」做去重，但**保留原始大小写**存进 results ——
        // 去重不敏感、展示保持原样。
        var results: [String] = []
        var seen = Set<String>()
        for m in matches {
            guard let t = m["translation"] as? String,
                  !t.isEmpty, t.lowercased() != text.lowercased(),
                  !seen.contains(t.lowercased()) else { continue }
            seen.insert(t.lowercased())
            results.append(t)
        }
        // 空结果不写缓存 —— 否则一次网络抽风会让这个词永远翻不出来（见 clearCache 的说明）。
        guard !results.isEmpty else { return [] }

        // 淘汰策略是粗粒度的：满 100 条就把**字典序前 50 个键**删掉（不是 LRU）。
        // 代价是最近常用的词也可能被误删；收益是实现极简、无需额外记账。
        cacheLock.withLock {
            if cache.count >= 100 {
                let sortedKeys = cache.keys.sorted()
                for k in sortedKeys.prefix(50) { cache.removeValue(forKey: k) }
            }
            cache[text] = results
        }
        return results
    }

    /// 清空缓存（内存警告时调用）。
    /// ⚠️ 本类型**没有失效机制**（不像 ModrinthSearchCache 有 TTL）——
    /// 一条译文会一直用到被砍掉或内存警告，长期运行下译文可能过期。
    static func clearCache() {
        cacheLock.withLock { cache.removeAll() }
    }
}
