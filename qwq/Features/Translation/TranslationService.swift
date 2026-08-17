import Foundation

// 内置翻译表 → ProjectTranslationTable.swift
// 中文字符检测 → ChineseText.swift
// 翻译源竞速获取 → TranslationSourceFetcher.swift

/// 翻译服务（重构：使用 CacheManager + 非阻塞读取）。
/// 只保留：翻译主流程（内置表 → 缓存 → 源竞速 → 兜底）、并发限制、去重、缓存读取。
final class TranslationService {
    static let shared = TranslationService()

    /// 全局翻译并发上限（最多 24 个同时翻译）
    private static let concurrencyLimit = 24
    private static let translationSemaphore = DispatchSemaphore(value: concurrencyLimit)

    private let cache = AppContext.shared.cacheManager
    private let session = AppContext.shared.translateSession
    private let lock = NSLock()
    private var inFlight: Set<String> = []

    private init() {}

    /// 翻译文本（内置表 → 缓存 → 并行[Modrinth API + 镜像翻译] → MyMemory 在线翻译）
    func translateText(text: String, projectId: String) async throws -> String {
        // 1. 若原文已是中文，直接返回
        if !text.isEmpty && ChineseText.contains(text) {
            return text
        }

        // 2. 内置翻译表快速匹配
        if let builtin = ProjectTranslationTable.match(projectId) {
            cache.setText(builtin, forKey: "tr_\(projectId)")
            return builtin
        }

        // 3. 检查缓存 — 只接受含中文的缓存
        if let cached = cache.textGet("tr_\(projectId)"), !cached.isEmpty, ChineseText.contains(cached) {
            return cached
        }

        // 4. 去重（检查 + 登记在一次持锁内完成，保持原子性）
        let isDuplicated: Bool = lock.withLockCompat {
            if inFlight.contains(projectId) {
                return true
            } else {
                inFlight.insert(projectId)
                return false
            }
        }
        if isDuplicated {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let cached = cache.textGet("tr_\(projectId)"), !cached.isEmpty, ChineseText.contains(cached) { return cached }
            return text
        }
        defer {
            lock.withLockCompat { inFlight.remove(projectId) }
        }

        // 4a. 全局并发限制（最多 24 个同时翻译）
        semaphoreWait(Self.translationSemaphore)
        defer { Self.translationSemaphore.signal() }

        // 5. 竞速拉取 Modrinth 详情与镜像翻译：谁先给出含中文的结果就采用谁，
        //    不再干等慢/超时的源（Modrinth API 在部分地区很慢/不稳定，镜像通常秒回）
        let (modrinthDesc, mirrorTranslated) = await TranslationSourceFetcher.raceSources(projectId: projectId, fallback: text, session: session)
        // 5a. Modrinth 返回了中文 → 直接用
        if let result = modrinthDesc, !result.isEmpty, ChineseText.contains(result) {
            cache.setText(result, forKey: "tr_\(projectId)")
            return result
        }

        // 5b. 镜像返回了中文 → 直接用
        if let result = mirrorTranslated, !result.isEmpty, ChineseText.contains(result) {
            cache.setText(result, forKey: "tr_\(projectId)")
            return result
        }

        // 5c. Modrinth 返回了英文原文 → 用 MyMemory 在线翻译
        if let englishText = modrinthDesc, !englishText.isEmpty, !ChineseText.contains(englishText) {
            if let translated = await TranslationSourceFetcher.fetchMyMemoryTranslation(text: englishText, session: session) {
                cache.setText(translated, forKey: "tr_\(projectId)")
                return translated
            }
        }

        // 5d. 用输入的原始 text 最后尝试 MyMemory
        if !text.isEmpty, !ChineseText.contains(text) {
            if let translated = await TranslationSourceFetcher.fetchMyMemoryTranslation(text: text, session: session) {
                cache.setText(translated, forKey: "tr_\(projectId)")
                return translated
            }
        }

        return text
    }

    /// 检查缓存（非阻塞）— 仅返回含中文的缓存
    func cachedTranslation(for projectId: String) -> String? {
        // 先查内置表再查缓存
        if let builtin = ProjectTranslationTable.match(projectId) {
            return builtin
        }
        if let cached = cache.textGet("tr_\(projectId)"), !cached.isEmpty, ChineseText.contains(cached) {
            return cached
        }
        return nil
    }

    /// 仅查内存缓存（不触碰磁盘），用于全量批量扫描场景，避免海量磁盘 IO
    func cachedTranslationInMemory(for projectId: String) -> String? {
        if let builtin = ProjectTranslationTable.match(projectId) {
            return builtin
        }
        if let cached = cache.memoryText("tr_\(projectId)"), !cached.isEmpty, ChineseText.contains(cached) {
            return cached
        }
        return nil
    }

    /// 批量预取翻译缓存（切分类/列表填充时调用，替代逐条查盘）：
    /// 内置表/内存命中直接收集；未命中的 id 交给 CacheManager 一次性枚举磁盘并批量读入内存，
    /// 返回可直接合并进 UI 的 [projectId: 中文翻译]。
    func prefetchTranslations(ids: [String]) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: String] = [:]
        var diskKeys: [String] = []
        for id in ids {
            let key = "tr_\(id)"
            if let builtin = ProjectTranslationTable.match(id) {
                result[id] = builtin
            } else if let mem = cache.memoryText(key), !mem.isEmpty, ChineseText.contains(mem) {
                result[id] = mem
            } else {
                diskKeys.append(key)
            }
        }
        // 批量磁盘预取（一次性枚举 + 只读命中文件）
        let fromDisk = cache.prefetchText(keys: diskKeys)
        for (key, text) in fromDisk where !text.isEmpty && ChineseText.contains(text) {
            result[String(key.dropFirst(3))] = text
        }
        return result
    }
}
