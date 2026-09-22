import Foundation

// 内置翻译表 → ProjectTranslationTable.swift
// 中文字符检测 → ChineseText.swift
// 翻译源竞速获取 → TranslationSourceFetcher.swift

/// 翻译服务（重构：使用 CacheManager + 非阻塞读取）。
/// 只保留：翻译主流程（内置表 → 缓存 → 源竞速 → 兜底）、并发限制、去重、缓存读取。
///
/// 隔离约定：类本身仍由工程默认隔离推断为主 actor（`shared` / `init()` 等主 actor 成员不受影响）。
/// 以下成员标 `nonisolated`：
/// - 【只读缓存查询】三个方法（`cachedTranslation` / `cachedTranslationInMemory` /
///   `prefetchTranslations`）：由 `CardTranslationModel` 的 `Task.detached` 调用，不再 `await`
///   切回主 actor，磁盘读真正落在后台线程。
/// - `translateText`：**本方法整体 nonisolated**，故其函数体在协作线程池上执行，而方法内唯一的
///   同步阻塞点 `acquireTranslationSlot()`（信号量等待）随之离开主线程，避免全局并发配额把主线程
///   卡住导致界面冻结。这正是本方法必须自己标 `nonisolated` 的原因——只把依赖标非隔离是无效的：
///   方法本身仍受主 actor 隔离时，调用点会先 `await` 切回主 actor 再执行整个函数体。
///   依赖的隔离标注：`session` / `lock` / `inFlight` / `translationSemaphore` 均标 nonisolated。
/// - 缓存读写 `cache.textGet` / `cache.setText` 均已非隔离，两条路径都不产生 actor 跳转。
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
    private nonisolated static let concurrencyLimit = 24
    /// `DispatchSemaphore` 在 SDK 中即 `Sendable`（内部状态自带同步），
    /// 故 `nonisolated` 足矣，不需要 `nonisolated(unsafe)`。
    private nonisolated static let translationSemaphore = DispatchSemaphore(value: concurrencyLimit)

    /// 非隔离只读依赖，见类型注释。
    private nonisolated let cache: CacheManager
    /// 非隔离依赖：`translateText` 为 nonisolated 后，方法体在协作线程池执行，
    /// 故 `session` 也须脱离主 actor 隔离，才能在该非隔离上下文读取。
    /// `URLSession` 满足 Sendable，在 `init()`（主 actor）内赋值即可安全跨域共享。
    private nonisolated let session: URLSession
    /// 普通可变状态，靠 `lock` 串行化保护；标 nonisolated 后可在 nonisolated 的
    /// `translateText` 中访问（不受 actor 保护，正是锁的职责所在）。
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var inFlight: Set<String> = []

    private init() {
        cache = AppContext.shared.cacheManager
        session = AppContext.shared.translateSession
    }

    /// 非隔离的同步中转：在 nonisolated 的 `translateText` 内等待全局并发配额。
    /// 不能直接调用 `DispatchSemaphore.wait()`（标注 `noasync`，在 async 上下文会告警）；
    /// 也不能复用 `NoasyncBridge.semaphoreWait`——它是主 actor 隔离，从 nonisolated 调用会
    /// `await` 切回主线程，反而把阻塞带回主线程。本函数自身「同步 + nonisolated」，
    /// 调用它不发生 actor 跳转，信号量等待确实落在 `translateText` 所在的协作线程池线程上。
    private nonisolated static func acquireTranslationSlot() {
        translationSemaphore.wait()
    }

    /// 翻译文本（内置表 → 缓存 → 并行[Modrinth API + 镜像翻译] → MyMemory 在线翻译）
    ///
    /// `nonisolated`：见类型注释——只为让 `acquireTranslationSlot()` 的同步阻塞不落在主线程。
    /// 方法体内其余被调用方若仍是主 actor 隔离，编译器会自动插入 `await` 跳转，行为不受影响。
    nonisolated func translateText(text: String, projectId: String) async throws -> String {
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
        let isDuplicated: Bool = lock.withLock {
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
            // 闭包单表达式 `remove` 会返回被移除元素作为 withLock 的结果；
            // 原 `withLockCompat` 带 @discardableResult，系统原生 `NSLock.withLock` 没有，
            // 故显式 `_ =`，避免 #no-usage 告警
            _ = lock.withLock { inFlight.remove(projectId) }
        }

        // 4a. 全局并发限制（最多 24 个同时翻译）
        Self.acquireTranslationSlot()
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
