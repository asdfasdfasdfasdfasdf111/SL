//
//  MemoryPressure.swift
//  系统内存压力的应用内广播：基础设施只「发布」，不认识任何订阅者。
//
//  为什么必须有这一层：`AppContext` 把系统内存压力翻译成「各子系统回收缓存」。
//  若由它直接调用某个具体类型（原实现是 `DownloadCategoryView.clearStaticCaches()` ——
//  一个 View 上的静态方法），基础设施层就被绑到了具体 UI 类型上：
//  依赖方向反过来（Infrastructure → UI），删/改那个 View 会波及应用基础设施，
//  且后续任何页面想响应内存压力都只能继续往 `AppContext` 里加具体 View 调用。
//  改为「发布事件 + 装配层订阅」后，`AppContext` 不再认识任何 UI 类型。
//
//  ⚠️ 隔离约定：
//  - 本类型 `nonisolated`（注册点在装配期主线程、发布点来自 dispatch source，可能不在同一隔离域），
//    订阅表用 `NSLock` 串行化；
//  - 处理器类型是 `@MainActor`，因为订阅方要碰主 actor 隔离的静态缓存；
//  - `post` 在主线程时**同步**调用处理器（见下方注释），后台线程则 hop 到主 actor。
//    ⚠️ 同步分支依赖「主线程 ⇒ 当前就在 MainActor 执行器上」这一**运行时假设** ——
//    它不是语言保证，理由、实测证据与守它的用例都写在 `post` 的注释里，改动前先读那段。
//
//  使用方：
//  - 发布：`App/AppContext.swift`（内存压力 source 的事件处理器）；
//  - 订阅：`App/MemoryCacheReclaimer.swift`（装配层注册，聚合各子系统缓存回收）。
//

import Foundation

/// 内存压力等级，对应 `DispatchSourceMemoryPressure` 的 `.warning` / `.critical`。
///
/// `Equatable` 供测试与订阅方做等值判定（本枚举无关联值，相等语义即「同一个 case」）。
enum MemoryPressureLevel: Sendable, Equatable {
    case warning
    case critical
}

/// 内存压力广播者。
///
/// `post` 与订阅完全解耦：基础设施只发事件，不知道谁会处理；
/// 订阅方由装配层（composition root）注册，因此「谁需要响应内存压力」这一知识
/// 只存在于装配层，不泄漏进基础设施。
nonisolated final class MemoryPressureBroadcaster: @unchecked Sendable {
    static let shared = MemoryPressureBroadcaster()

    private let lock = NSLock()
    private var handlers: [UUID: @MainActor (MemoryPressureLevel) -> Void] = [:]

    private init() {}

    /// 注册处理器，返回用于注销的令牌。处理器在**主 actor** 上被调用。
    /// ⚠️ 调用方负责在不再需要时 `remove`，否则处理器（及其捕获）会一直存活。
    @discardableResult
    func add(_ handler: @escaping @MainActor (MemoryPressureLevel) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    /// 注销处理器。对未知令牌或无令牌为空是安全的（幂等）。
    func remove(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    /// 当前已注册的处理器数量。
    ///
    /// 只读诊断用：让「装配期确实注册过」这件事**可断言**（否则测试只能验证
    /// 「自己注册的能收到」，验证不了「应用真的注册了」——后者才是真实运行时生效的前提）。
    var handlerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handlers.count
    }

    /// 发布一次内存压力事件。**处理器的调用顺序不保证**（订阅表是无序字典）。
    ///
    /// 主线程上**同步**调用：发布点（`AppContext` 的 dispatch source 跑在 `.main` 队列）本就在主线程，
    /// 若一律 hop，`post` 会在下一次 runloop 才生效 —— 内存压力这类「越快越好」的响应没必要多等一轮，
    /// 而且同步完成能让「裁 CacheManager + 清 4 个缓存」这一批动作落在同一个事件处理器里、不被主 actor
    /// 上的其它活儿插到中间。后台线程走 hop 路径，行为与主线程一致（只是异步到达）。
    ///
    /// ⚠️ **这里有一个必须写明的运行时假设**：`Thread.isMainThread == true` 不被 Swift 语言定义为
    /// 「当前处于 MainActor 执行器上」，两者严格来说不等价；`MainActor.assumeIsolated` 校验的是后者。
    /// 本工程接受该假设，理由是可核对的：
    /// 1. **发布点的上下文与生产同构地实测过**（2026-09-25，独立探针）：在
    ///    `DispatchSource.makeTimerSource(queue: .main)` 的事件回调里调 `assumeIsolated` **通过**；
    ///    同一份探针从后台线程调则被拒绝（`SIGTRAP`，退出码 133）—— 说明该检查真的会拒绝错的环境，
    ///    不是恒真。
    /// 2. **「主线程但不在 MainActor 执行器上」这个上下文在本工具链下构造不出来**：40000 个
    ///    `Task.detached` / 后台发起的非隔离任务，落在主线程上的次数为 **0**（协同线程池从不使用主线程）；
    ///    而主 actor 的执行器就是主队列本身。
    /// 3. **这条检查在真实风险方向上是保守的**：若哪天有人把 `AppContext` 里 source 的 `queue` 改掉，
    ///    `Thread.isMainThread` 会变成 false → 自动走 else 的 hop 路径，而不是误走同步路径。
    ///    即最可能的未来改动只会让它退化（更安全），不会让它变危险。
    /// 4. `MemoryPressureTests.testPostFromMainQueueDispatchSourceIsDelivered` 用**同构的
    ///    dispatch source 上下文**把这条假设钉住 —— 假设一旦不成立，那个用例会当场 trap/变红，
    ///    而不是静默地错。
    ///
    /// 对照：`NoticeCenter.post` 里有结构相同的一段，**不要「顺手统一」**。那边的同步投递是**承重**的
    /// （先 `post` 后 `presentAndWait` 会顺序倒置 → 提示被当成"被顶替"直接应答，用户看不到），
    /// 且已有专门的反证用例；本处只是省一轮 runloop，取舍不同。
    func post(_ level: MemoryPressureLevel) {
        lock.lock()
        let snapshot = Array(handlers.values)
        lock.unlock()

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                for handler in snapshot { handler(level) }
            }
        } else {
            Task { @MainActor in
                for handler in snapshot { handler(level) }
            }
        }
    }
}
