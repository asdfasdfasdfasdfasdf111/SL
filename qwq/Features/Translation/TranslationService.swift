import Foundation

// 内置翻译表 → ProjectTranslationTable.swift
// 中文字符检测 → ChineseText.swift
// 翻译源竞速获取 → TranslationSourceFetcher.swift

/// 翻译服务（重构：使用 CacheManager + 非阻塞读取）。
/// 只保留：翻译主流程（内置表 → 缓存 → 源竞速 → 兜底）、并发限制、去重、缓存读取。
///
/// 隔离约定：类本身仍由工程默认隔离推断为主 actor（`shared` 等主 actor 成员不受影响）；
/// 仅【只读缓存查询】三个方法（`cachedTranslation` / `cachedTranslationInMemory` /
/// `prefetchTranslations`）标为 `nonisolated`，使调用方在 `Task.detached` 的后台上下文里调用时
/// 不再 `await` 切回主 actor，磁盘读真正落在后台线程。
/// `cache` 因此声明为 `nonisolated let`（`CacheManager` 被主 actor 推断隔离，按官方 Sendable 规则
/// 隐式满足 Sendable，可安全地被非隔离成员读取）；其赋值放在隔离的 `init()` 内完成，
/// 避免在非隔离上下文中访问 `AppContext.shared`。
/// 依据：官方诊断《Calling an actor-isolated method from a synchronous nonisolated context》——
/// "nonisolated methods can be called from any concurrency domain. To prevent data races,
/// nonisolated methods cannot access actor isolated state in their implementation."
/// 依据：《Concurrency》Sendable Types —— 有保证可变状态安全的代码（如 `@MainActor` 类）可跨并发域共享。
/// 官方链接：
///   https://docs.swift.org/latest/documentation/diagnostics/actor-isolated-call/
///   https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
final class TranslationService {
    static let shared = TranslationService()

    /// 全局翻译并发上限（最多 24 个同时翻译）
    private static let concurrencyLimit = 24
    private static let translationSemaphore = DispatchSemaphore(value: concurrencyLimit)

    /// 非隔离只读依赖，见类型注释。
    private nonisolated let cache: CacheManager
    private let session = AppContext.shared.translateSession
    private let lock = NSLock()
    private var inFlight: Set<String> = []

    private init() {
        cache = AppContext.shared.cacheManager
    }

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

    /// 检查缓存 — 仅返回含中文的缓存
    ///
    /// `nonisolated`：本方法是翻译卡片按需查盘的入口，由 `CardTranslationModel.requestTranslation`
    /// 的 `Task.detached` 调用；标非隔离后「查内置表 → 查内存 → 读盘」整链在后台线程完成。
    nonisolated func cachedTranslation(for projectId: String) -> String? {
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
    nonisolated func cachedTranslationInMemory(for projectId: String) -> String? {
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
    ///
    /// `nonisolated`：由 `CardTranslationModel.prefetch` 的 `Task.detached` 调用，
    /// 标非隔离后整段批量查盘在后台线程完成，不再切回主 actor。
    nonisolated func prefetchTranslations(ids: [String]) -> [String: String] {
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
