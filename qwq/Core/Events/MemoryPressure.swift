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
    /// 若一律 hop，`post` 会在下一次 runloop 才生效 —— 内存压力这类「越快越好」的响应没必要多等一轮。
    /// 后台线程走 hop 路径，行为与主线程一致（只是异步到达）。
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
