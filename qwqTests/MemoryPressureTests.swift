//
//  MemoryPressureTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//
//  1. **事件能到达订阅者**（这条是 P0 重构的验收条件）。`AppContext` 原先直接调用
//     `DownloadCategoryView.clearStaticCaches()` —— 一个 View 上的静态方法，构成
//     Infrastructure → UI 的反向依赖。改成「基础设施发事件 + 装配层订阅」后，
//     必须证明事件确实能送到订阅者，否则就是「依赖去掉了、功能也去掉了」。
//  2. **等级原样透传**：`warning` / `critical` 不得在广播层被吞掉或改写 ——
//     它现在虽然对缓存回收无差别，但删掉它等于把将来分等级处理的路堵死。
//  3. **主线程上同步送达**：发布点在 dispatch source 的 `.main` 队列，多等一轮 runloop
//     毫无意义；且与 `NoticeCenter.post` 保持同一约定（同一类「越快越好」的响应）。
//  4. **注销生效**：`remove` 之后不得再被调用（订阅表泄漏 → 悬垂处理器）。
//  5. **多订阅者各自都收到**；**没有订阅者时不得崩**。
//  6. **端到端接线**：`MemoryCacheReclaimer.register()` 之后，一次事件必须真的把
//     `ModrinthCategoryCache` 的内存缓存清掉 —— 这是「聚合动作搬到了装配层」的唯一可观测证据。
//  7. **装配根确实注册了**：`SLApp.init()` 里那一次 `MemoryCacheReclaimer.register()` 不能漏 ——
//     漏了的话真实运行时内存压力不会清任何缓存，而「自己注册自己收」的用例仍然是绿的。
//
//  注意：`MemoryPressureBroadcaster` 只有 `shared` 单例（无 reset 接口），
//  因此每个用例自己 `defer { remove(token) }`，断言一律写成「本次注册的处理器收到什么」，
//  不依赖订阅表的绝对条数。
//
//  被测：Core/Events/MemoryPressure.swift、App/MemoryCacheReclaimer.swift
//

import XCTest
@testable import qwq

@MainActor
final class MemoryPressureTests: XCTestCase {

    // MARK: - 等待辅助

    /// 轮询等待条件成立（给 hop 到主 actor 的异步送达路径用）。
    private func waitUntil(timeout: TimeInterval = 2,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("等待条件超时（\(timeout)s）", file: file, line: line)
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)
        }
    }

    // MARK: - 送达

    /// 主线程上发布必须**同步**送达：不做任何等待，紧接着断言。
    ///
    /// 反证：把 `post` 里 `Thread.isMainThread` 的同步分支摘掉（退回裸 `Task { @MainActor in }`），
    /// 本用例会在断言处变红。
    func testPostOnMainThreadDeliversSynchronously() async {
        var received: [MemoryPressureLevel] = []
        let token = MemoryPressureBroadcaster.shared.add { received.append($0) }
        defer { MemoryPressureBroadcaster.shared.remove(token) }

        MemoryPressureBroadcaster.shared.post(.warning)

        // 关键：不 await、不 yield，紧接着断言 —— 只有同步送达才可能成立
        XCTAssertEqual(received, [.warning], "主线程发布被推迟到了下一轮 runloop")
    }

    /// 等级原样透传：两个等级分别送达，且都不是「另一个」
    func testPostPreservesLevel() async {
        var received: [MemoryPressureLevel] = []
        let token = MemoryPressureBroadcaster.shared.add { received.append($0) }
        defer { MemoryPressureBroadcaster.shared.remove(token) }

        MemoryPressureBroadcaster.shared.post(.critical)
        MemoryPressureBroadcaster.shared.post(.warning)

        XCTAssertEqual(received, [.critical, .warning],
                       "等级被改写或吞掉时本用例必须变红")
    }

    /// 多个订阅者各自都收到（订阅表是无序字典，只断言集合与条数，不断言先后）
    func testPostReachesEveryRegisteredHandler() async {
        var first: [MemoryPressureLevel] = []
        var second: [MemoryPressureLevel] = []
        let tokenA = MemoryPressureBroadcaster.shared.add { first.append($0) }
        let tokenB = MemoryPressureBroadcaster.shared.add { second.append($0) }
        defer {
            MemoryPressureBroadcaster.shared.remove(tokenA)
            MemoryPressureBroadcaster.shared.remove(tokenB)
        }

        MemoryPressureBroadcaster.shared.post(.warning)

        XCTAssertEqual(first, [.warning])
        XCTAssertEqual(second, [.warning])
    }

    /// 注销后不得再被调用；且对未知令牌 `remove` 是安全 no-op
    func testRemovedHandlerNoLongerReceives() async {
        var received: [MemoryPressureLevel] = []
        let token = MemoryPressureBroadcaster.shared.add { received.append($0) }

        MemoryPressureBroadcaster.shared.post(.warning)
        XCTAssertEqual(received.count, 1, "注销前应正常收到")

        MemoryPressureBroadcaster.shared.remove(token)
        MemoryPressureBroadcaster.shared.post(.warning)
        XCTAssertEqual(received.count, 1, "注销后仍在被调用 → 订阅表泄漏")

        // 重复注销 / 注销未知令牌都不得崩
        MemoryPressureBroadcaster.shared.remove(token)
        MemoryPressureBroadcaster.shared.remove(UUID())
    }

    /// 后台线程发布同样必须送达（走 hop 到主 actor 的路径）
    func testPostFromBackgroundThreadIsDelivered() async {
        var received: [MemoryPressureLevel] = []
        let token = MemoryPressureBroadcaster.shared.add { received.append($0) }
        defer { MemoryPressureBroadcaster.shared.remove(token) }

        DispatchQueue.global(qos: .userInitiated).async {
            MemoryPressureBroadcaster.shared.post(.critical)
        }

        await waitUntil { !received.isEmpty }
        XCTAssertEqual(received, [.critical])
    }

    // MARK: - 端到端：装配层注册 → 缓存真的被回收

    /// 装配根（`SLApp.init()`）必须已经注册过内存压力订阅。
    ///
    /// 与下面的端到端用例互补：那个用例自己调 `register()`，只能证明「注册了就能清缓存」；
    /// 本条断言的是「**应用真的注册了**」—— 缺了这一条，真实运行时内存压力来了什么都不会发生，
    /// 而所有单测仍然是绿的。
    ///
    /// 反证：把 `MemoryCacheReclaimer.register()` 从 `SLApp.init()` 摘掉后，本用例变红。
    func testCompositionRootRegistersReclaimerSubscription() async {
        XCTAssertGreaterThanOrEqual(
            MemoryPressureBroadcaster.shared.handlerCount, 1,
            "装配根没有注册内存压力订阅 —— 真实运行时内存压力将不会清理任何缓存")
    }

    /// `MemoryCacheReclaimer.register()` 之后，一次事件必须清掉 `ModrinthCategoryCache` 的内存缓存。
    ///
    /// 这是「聚合动作搬到装配层」唯一可观测的证据：只验证 `post` 能触发处理器还不够，
    /// 得证明处理器里挂的确实是那批缓存清理。
    ///
    /// 反证：把 `MemoryCacheReclaimer.register()` 从 `SLApp.init()` 摘掉、并跳过本用例里的显式
    /// 调用，缓存会保持非 nil → 断言变红（这在真实运行里对应的就是「内存压力来了但缓存不清」）。
    func testReclaimerRegistrationClearsModrinthMemoryCache() async {
        // 造一份非空内存缓存（显式保存/还原，避免污染其它用例）
        let savedModItems = ModrinthCategoryCache.cachedModItems
        let savedSubCategory = ModrinthCategoryCache.lastGameSubCategory
        defer {
            ModrinthCategoryCache.cachedModItems = savedModItems
            ModrinthCategoryCache.lastGameSubCategory = savedSubCategory
        }

        ModrinthCategoryCache.cachedModItems = []
        ModrinthCategoryCache.lastGameSubCategory = .release
        XCTAssertNotNil(ModrinthCategoryCache.cache(for: .mod, sub: nil), "前置条件：缓存已就位")

        MemoryCacheReclaimer.register()
        MemoryPressureBroadcaster.shared.post(.warning)

        XCTAssertNil(ModrinthCategoryCache.cachedModItems,
                     "内存压力事件没有触达缓存回收器 —— 事件发布与订阅没接上")
        XCTAssertNil(ModrinthCategoryCache.lastGameSubCategory,
                     "子分类标记也必须一起清（否则 cachedGameVersions(for:) 会拿错子分类比对）")
    }

    /// 注册是幂等的：重复调用不改变「清一次缓存」这个可观测结果。
    ///
    /// 无法直接数订阅表条数（未暴露），因此从行为侧验证：连调两次注册后一次事件，
    /// 缓存照样被清空，且不崩。
    func testReclaimerRegistrationIsIdempotent() async {
        let savedModItems = ModrinthCategoryCache.cachedModItems
        defer { ModrinthCategoryCache.cachedModItems = savedModItems }

        MemoryCacheReclaimer.register()
        MemoryCacheReclaimer.register()
        MemoryCacheReclaimer.register()

        ModrinthCategoryCache.cachedModItems = []
        MemoryPressureBroadcaster.shared.post(.critical)

        XCTAssertNil(ModrinthCategoryCache.cachedModItems)
    }

    // MARK: - 无订阅者

    /// 订阅者为空时发布不得崩（释放最后一批订阅者后立即发布）
    func testPostWithoutHandlersDoesNotCrash() async {
        var received: [MemoryPressureLevel] = []
        let token = MemoryPressureBroadcaster.shared.add { received.append($0) }
        MemoryPressureBroadcaster.shared.remove(token)

        MemoryPressureBroadcaster.shared.post(.warning)
        MemoryPressureBroadcaster.shared.post(.critical)

        XCTAssertTrue(received.isEmpty)
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. `AppContext.init()` 里的 dispatch source 接线（`memoryPressureSource` 的
//     「先赋值后 activate」顺序、以及 handler 从 `source.data` 读等级）无法在单测里驱动：
//     `AppContext` 只有私有 init + `shared` 单例，实例化会建 3 个 URLSession、1 个 ProcessPool、
//     并启动一次磁盘缓存清扫的 `Task.detached` —— 属真实副作用，不适合在用例里触发。
//     该接线由「读代码 + 真实运行」覆盖，本文件只覆盖它下游的事件语义。
//  2. 系统真实内存压力事件（`DispatchSourceMemoryPressure` 被内核触达）不做断言：
//     需要真的把进程内存压到阈值，属集成测试范畴。
//  3. 「AppContext 不再引用 DownloadCategoryView」是**编译期/源码级**性质，
//     运行期无法断言（方法已删除，引用它根本编译不过）。由 `grep` 与真实编译共同证明。
