import Foundation

// MARK: - 搜索翻译（中文 → 英文，自 GameViews 拆出）
// 调用 MyMemory 翻译 API，带内存缓存（上限 100 条，超出清空一半）。

enum SearchTranslator {
    private static var cache: [String: [String]] = [:]
    private static let cacheLock = NSLock()

    /// 中文 → 英文候选词列表（缓存命中直接返回）
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
        var results: [String] = []
        var seen = Set<String>()
        for m in matches {
            guard let t = m["translation"] as? String,
                  !t.isEmpty, t.lowercased() != text.lowercased(),
                  !seen.contains(t.lowercased()) else { continue }
            seen.insert(t.lowercased())
            results.append(t)
        }
        guard !results.isEmpty else { return [] }

        cacheLock.withLock {
            if cache.count >= 100 {
                let sortedKeys = cache.keys.sorted()
                for k in sortedKeys.prefix(50) { cache.removeValue(forKey: k) }
            }
            cache[text] = results
        }
        return results
    }

    /// 清空缓存（内存警告时调用）
    static func clearCache() {
        cacheLock.withLock { cache.removeAll() }
    }
}
