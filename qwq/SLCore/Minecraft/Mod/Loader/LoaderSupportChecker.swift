//
//  LoaderSupportChecker.swift
//  SL启动器
//
//  Created on 2026/8/9.
//
//  加载器支持检测服务（后端核心，UI 层只消费结果，不直接联网 / 不直接读写缓存）。
//  本文件只保留类型声明、候选排序常量、对外异步入口、缓存清理入口与 in-flight 任务合并：
//  - loaderOrder：显示名排序（Fabric → Forge → NeoForged → Quilt）
//  - streamLoaderStates / checkLoaderStates / prefetchForVersion：流式 / 聚合 / 预加载入口
//  - clearMemoryCache / clearCache：内存与磁盘缓存清理
//  - in-flight 合并（原子创建 + ownerID 归属保护 + 多订阅者广播）
//  其余实现按职责拆分在同目录，逻辑、常量与文案均与原实现逐字一致（仅物理搬移）：
//  - LoaderSupportState.swift         结果模型（LoaderState / LoaderSupportResult）
//  - LoaderSupportCache.swift         内存 + 磁盘缓存读写、TTL 过滤与对外同步查询
//  - LoaderSupportVersionRules.swift  版本比较与候选加载器规则表
//  - LoaderSupportProbe.swift         端点规则表、并发探测与单请求结论语义
//
//  跨文件访问级别说明（依据 references/swift-language/access-control.md 与 extensions.md，
//  官方链接 https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/
//  与 .../extensions/）：`private` 仅对「同一封闭声明及其同文件扩展」可见，且扩展不能声明存储属性，
//  故拆分后仅有下列成员的访问级别由 private 提升为 internal，其余成员一律保持 private：
//  detectAndMergeStates、publishInflight、writeEntry、isSnapshotVersion、versionAtLeast、orderIndex。
//

import Foundation

/// 加载器支持检测服务（后端核心，UI 层只消费结果，不直接联网 / 不直接读写缓存）。
///
/// 检测策略（Beta 0.1.10 重构，解决「未缓存版本的加载器列表加载过慢」）：
/// 1. 内存缓存：同会话内命中直接返回，秒级
/// 2. 磁盘缓存（`SL启动器/LoaderSupportCache.json`）：**按「版本 × 单个加载器」粒度**缓存，
///    supported 14 天 / notSupported 7 天（快照与最新大版本 24h），unavailable 不缓存——
///    部分加载器网络失败不再拖累整版结果无法缓存，下次只重查未定论项
/// 3. 联网并发检测（仅未定论项）：每加载器单请求（4s 请求 / 6s 资源超时直连），
///    双源加载器 700ms 延迟并发备用源，不再串行等待主源完整超时
/// 4. 同版本 in-flight 合并 + 预加载：同一版本并发请求复用同一个检测任务（不重复联网）；
///    检测响应数组存入内存缓存，供 LoaderVersionResolver 复用（下载解析免二次请求）
public enum LoaderSupportChecker {

    /// 显示名排序（Fabric → Forge → NeoForged → Quilt）
    public static let loaderOrder = ["Fabric", "Forge", "NeoForged", "Quilt"]

    // MARK: - 对外异步查询（流式 / 聚合 / 预加载）

    /// 流式检测：先 yield 缓存已定论项（秒回），随后 TaskGroup 每完成一个加载器就立刻广播一个结果。
    /// 同版本的前台/预加载调用共享一个 in-flight 任务；每个流订阅者单独登记、终止时单独移除。
    public static func streamLoaderStates(for version: String) -> AsyncStream<(loader: String, state: LoaderState)> {
        AsyncStream { continuation in
            if let cached = cachedLoaderStates(for: version) {
                for (loader, state) in cached { continuation.yield((loader, state)) }
            }

            let subscriberID = UUID()
            let snapshot = subscribeInflight(version: version, subscriberID: subscriberID, continuation: continuation)
            continuation.onTermination = { _ in
                unsubscribeInflight(version: version, ownerID: snapshot.id, subscriberID: subscriberID)
            }
            Task {
                let finalStates = await snapshot.task.value
                // 覆盖「读取缓存 → 登记订阅」之间极小窗口内可能漏掉的广播；重复 yield 幂等。
                for (loader, state) in finalStates { continuation.yield((loader, state)) }
                continuation.finish()
                unsubscribeInflight(version: version, ownerID: snapshot.id, subscriberID: subscriberID)
                dismissInflight(version: version, ownerID: snapshot.id)
            }
        }
    }

    /// 检测某版本全部候选加载器（已定论项直接取缓存；仅未定论项联网并发检测，单请求 4s 超时）。
    /// 同版本 in-flight 合并：查询/创建/登记均在同一锁区间内，杜绝两个调用同时创建两组请求。
    public static func checkLoaderStates(for version: String) async -> [String: LoaderState] {
        let snapshot = getOrCreateInflight(for: version)
        let result = await snapshot.task.value
        // 归属校验：只有创建本任务的 ownerID 仍属于该版本时才清理，旧任务绝不清掉新任务。
        dismissInflight(version: version, ownerID: snapshot.id)
        return result
    }

    /// 静默预加载：无候选或已全部定论则 no-op；否则后台触发检测（in-flight 合并，详情页/列表悬停可放心调用）
    ///
    /// 「无候选」（`candidateDisplayNames` 为空，如远古版与快照——配置层面就没有可检测的加载器）
    /// 与「确定不支持」（有 notSupported 结论）必须区分：
    /// - 前者不会产生任何缓存条目，`cachedLoaderStates` 恒为 nil，缓存判据永远不成立，
    ///   若不在此提前返回，每次调用都会空建一个不含任何请求的 in-flight 任务；
    /// - 后者结论已落盘，命中缓存后 `isFullyResolved` 为真，自然不再建任务。
    public static func prefetchForVersion(_ version: String) {
        guard !version.isEmpty else { return }
        guard !candidateDisplayNames(for: version).isEmpty else { return }
        if let states = cachedLoaderStates(for: version), isFullyResolved(states, for: version) { return }
        _ = Task { _ = await checkLoaderStates(for: version) }
    }

    // MARK: - 缓存清理

    public static func clearMemoryCache() {
        clearCacheStorage()
        inflightLock.lock()
        let runningTasks = inflight.values.map(\.task)
        inflight = [:]
        inflightLock.unlock()
        // 先摘除归属再取消：迟到回调无法找到条目，更不可能清理后续新任务。
        for task in runningTasks { task.cancel() }
        clearVersionListCache()
    }

    public static func clearCache() {
        clearMemoryCache()
        try? FileManager.default.removeItem(at: cacheFile)
    }

    // MARK: - in-flight 合并（原子创建 + ownerID 归属保护 + 多订阅者广播）

    private struct InflightEntry {
        let id: UUID
        let task: Task<[String: LoaderState], Never>
        var subscribers: [UUID: AsyncStream<(loader: String, state: LoaderState)>.Continuation] = [:]
    }

    private struct InflightSnapshot {
        let id: UUID
        let task: Task<[String: LoaderState], Never>
    }

    private static let inflightLock = NSLock()
    private static var inflight: [String: InflightEntry] = [:]

    /// 查询或创建任务必须在同一锁区间内完成，杜绝并发调用同时创建两组网络请求。
    private static func getOrCreateInflight(for version: String) -> InflightSnapshot {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        if let existing = inflight[version] {
            return InflightSnapshot(id: existing.id, task: existing.task)
        }
        let id = UUID()
        let task = Task { await detectAndMergeStates(for: version) }
        inflight[version] = InflightEntry(id: id, task: task)
        return InflightSnapshot(id: id, task: task)
    }

    /// 注册流订阅者；查询/创建/登记在同一锁区间内，避免错过新任务归属。
    private static func subscribeInflight(
        version: String,
        subscriberID: UUID,
        continuation: AsyncStream<(loader: String, state: LoaderState)>.Continuation
    ) -> InflightSnapshot {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        if var existing = inflight[version] {
            existing.subscribers[subscriberID] = continuation
            inflight[version] = existing
            return InflightSnapshot(id: existing.id, task: existing.task)
        }
        let id = UUID()
        let task = Task { await detectAndMergeStates(for: version) }
        var entry = InflightEntry(id: id, task: task)
        entry.subscribers[subscriberID] = continuation
        inflight[version] = entry
        return InflightSnapshot(id: id, task: task)
    }

    /// TaskGroup 单项完成后立刻广播；复制 continuation 后解锁再 yield，避免回调重入锁。
    /// 访问级别为 internal：探测层（LoaderSupportProbe.swift）逐项定论时调用。
    static func publishInflight(version: String, loader: String, state: LoaderState) {
        inflightLock.lock()
        let subscribers: [AsyncStream<(loader: String, state: LoaderState)>.Continuation]
        if let entry = inflight[version] {
            subscribers = Array(entry.subscribers.values)
        } else {
            subscribers = []
        }
        inflightLock.unlock()
        for continuation in subscribers { continuation.yield((loader, state)) }
    }

    private static func unsubscribeInflight(version: String, ownerID: UUID, subscriberID: UUID) {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        guard var entry = inflight[version], entry.id == ownerID else { return }
        entry.subscribers.removeValue(forKey: subscriberID)
        inflight[version] = entry
    }

    /// 归属校验清理：旧任务迟到完成时 ownerID 不匹配，绝不会清掉新任务。
    private static func dismissInflight(version: String, ownerID: UUID) {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        guard inflight[version]?.id == ownerID else { return }
        inflight[version] = nil
    }
}
