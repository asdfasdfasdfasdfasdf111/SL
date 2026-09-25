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
//  3. **主线程上同步送达**：发布点就在 dispatch source 的 `.main` 队列上，多等一轮 runloop
//     没有必要，且同步完成能让「裁 CacheManager + 清 4 个缓存」落在同一个事件处理器里。
//  4. **注销生效**：`remove` 之后不得再被调用（订阅表泄漏 → 悬垂处理器）。
//  5. **多订阅者各自都收到**；**没有订阅者时不得崩**。
//  6. **`post` 的同步分支所依赖的运行时假设要有用例守着**（见 §「生产同构上下文」一节）。
//     生产里的发布点是一个 `queue: .main` 的 **dispatch source 回调**，不是 Swift 任务；
//     `Thread.isMainThread` 与「在 MainActor 执行器上」严格来说不等价，
//     所以这条假设不能只写在注释里 —— 本文件用同构的 dispatch source 把它钉住。
//  7. **注销后订阅表不得继续持有处理器**：否则是闭包泄漏，且被捕获的对象永不释放
//     （「broadcaster 是否仍保留 handler」这条生命周期问题的可验证形式）。
//  8. **注册幂等**：`MemoryCacheReclaimer.register()` 重复调用不得塞进第二个处理器。
//  9. **端到端接线**：`MemoryCacheReclaimer.register()` 之后，一次事件必须真的把
//     `ModrinthCategoryCache` 的内存缓存清掉 —— 这是「聚合动作搬到了装配层」的唯一可观测证据。
// 10. **装配根确实注册了**：`SLApp.init()` 里那一次 `MemoryCacheReclaimer.register()` 不能漏 ——
//     漏了的话真实运行时内存压力不会清任何缓存，而「自己注册自己收」的用例仍然是绿的。
//
//  ⚠️ **测试写法约定：一条失败只指向一个性质。**
//  只有第 3 条（`testPostOnMainThreadDeliversSynchronously`）**允许**不 `await` 就断言；
//  其余用例一律 `await` 送达后再断言。2026-09-25 反向用例实测：不 `await` 的版本在
//  「摘掉同步分支」这一个原因下会连带打红 5 条用例，失败信号指不到真正的性质上。
//
//  注意：`MemoryPressureBroadcaster` 只有 `shared` 单例（无 reset 接口），
//  因此每个用例自己 `defer { remove(token) }`；断言一律写成「本次注册的处理器收到什么」。
//  唯一例外是幂等性用例 —— 它必须看订阅表条数（`handlerCount`），但只比较
//  「调用前后的差值」，不比绝对值，所以不依赖其它用例的注册情况。
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
    /// ⚠️ **本用例是「同步送达」这条性质的唯一守卫**。其余用例一律 `await` 送达
    /// （见下面的 `testPostPreservesLevel` 等），刻意不依赖同步性 ——
    /// 否则「同步分支被摘掉」这一个原因会同时打红一大片用例，失败信号就指不到真正的性质上
    /// （2026-09-25 实测过：不 await 的版本在摘掉同步分支后有 5 条用例连带变红）。
    ///
    /// 反证：把 `post` 里 `Thread.isMainThread` 的同步分支摘掉（退回裸 `Task { @MainActor in }`），
    /// 只有本用例变红。
    func testPostOnMainThreadDeliversSynchronously() async {
        var received: [MemoryPressureLevel] = []
        let token = MemoryPressureBroadcaster.shared.add { received.append($0) }
        defer { MemoryPressureBroadcaster.shared.remove(token) }

        MemoryPressureBroadcaster.shared.post(.warning)

        // 关键：不 await、不 yield，紧接着断言 —— 只有同步送达才可能成立
        XCTAssertEqual(received, [.warning], "主线程发布被推迟到了下一轮 runloop")
    }

    /// 等级原样透传：两个等级分别送达且顺序不变。
    /// ⚠️ 这里 `await` 送达，**不**依赖同步性（同步性由上面那条独占守卫）。
    func testPostPreservesLevel() async {
        var received: [MemoryPressureLevel] = []
        let token = MemoryPressureBroadcaster.shared.add { received.append($0) }
        defer { MemoryPressureBroadcaster.shared.remove(token) }

        MemoryPressureBroadcaster.shared.post(.critical)
        MemoryPressureBroadcaster.shared.post(.warning)

        await waitUntil { received.count == 2 }
        XCTAssertEqual(received, [.critical, .warning],
                       "等级被改写或吞掉时本用例必须变红")
    }

    /// 多个订阅者各自都收到（订阅表是无序字典，只断言集合与条数，不断言先后）。
    /// ⚠️ 同样 `await` 送达，不依赖同步性。
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

        await waitUntil { !first.isEmpty && !second.isEmpty }
        XCTAssertEqual(first, [.warning])
        XCTAssertEqual(second, [.warning])
    }

    /// 注销后不得再被调用；且对未知令牌 `remove` 是安全 no-op。
    /// ⚠️ 每一段都 `await` 送达后再断言，避免「注销失效」与「送达被推迟」两种红混在一起。
    func testRemovedHandlerNoLongerReceives() async {
        var received: [MemoryPressureLevel] = []
        let token = MemoryPressureBroadcaster.shared.add { received.append($0) }

        MemoryPressureBroadcaster.shared.post(.warning)
        await waitUntil { received.count == 1 }
        XCTAssertEqual(received.count, 1, "注销前应正常收到")

        MemoryPressureBroadcaster.shared.remove(token)
        MemoryPressureBroadcaster.shared.post(.warning)
        // 给足两轮机会：若注销失效，处理器迟早会被调用，计数一定涨上去
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
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

    // MARK: - 生产同构上下文：`queue: .main` 的 dispatch source 回调

    /// 生产里的发布点不是 Swift 任务，而是 `AppContext` 上那个
    /// `DispatchSource.makeMemoryPressureSource(…, queue: .main)` 的事件回调。
    /// 本用例用**同构**的定时源复现那个上下文，钉住「在该上下文里发布同样送达」。
    ///
    /// 为什么必须有用例：`post` 的同步分支用 `Thread.isMainThread` 判断「是否已在主 actor 上」，
    /// 而 Swift 并不保证这两者等价（`MainActor.assumeIsolated` 校验的是执行器，不是线程）。
    /// 这条假设因此不能只活在注释里 —— 该上下文一旦不成立，本用例会**当场 trap**（宿主 abort），
    /// 而不是静默地走错路径。
    ///
    /// 反证：把 `AppContext` 里 source 的 `queue` 从 `.main` 改掉不影响本用例（本用例自建源），
    /// 但把 `post` 里的同步分支换成无条件 `Task { @MainActor in … }` 后，
    /// `testPostOnMainThreadDeliversSynchronously` 会变红（本用例仍绿，因为它只要求「送达」）。
    func testPostFromMainQueueDispatchSourceIsDelivered() async {
        var received: [MemoryPressureLevel] = []
        let token = MemoryPressureBroadcaster.shared.add { received.append($0) }
        defer { MemoryPressureBroadcaster.shared.remove(token) }

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.setEventHandler {
            MemoryPressureBroadcaster.shared.post(.critical)
        }
        source.schedule(deadline: .now() + 0.01)
        source.activate()
        defer { source.cancel() }

        await waitUntil { !received.isEmpty }
        XCTAssertEqual(received, [.critical],
                       "queue: .main 的 dispatch source 回调里发布必须送达")
    }

    // MARK: - 生命周期：注销后不得继续持有处理器

    /// `add` 会把闭包存进订阅表，`remove` 之后订阅表**不得再持有它**。
    ///
    /// 用一个哨兵对象 + `weak` 引用观察：注册期间必须被持有（否则事件根本送不到），
    /// 注销后必须被释放（否则是闭包泄漏，且被捕获的对象永远不释放 ——
    /// 这正是「broadcaster 是否仍保留 handler」这条生命周期问题的可验证形式）。
    func testRemovedHandlerReleasesItsCaptures() async {
        final class Sentry {}

        weak var weakSentry: Sentry?
        let handle: UUID
        do {
            let sentry = Sentry()
            weakSentry = sentry
            handle = MemoryPressureBroadcaster.shared.add { _ in
                // 强引用捕获：让上面的 weak 观察有意义（ObjectIdentifier 不会被优化掉）
                _ = ObjectIdentifier(sentry)
            }
            XCTAssertNotNil(weakSentry, "注册期间订阅表必须持有处理器，否则事件送不到")
        }

        MemoryPressureBroadcaster.shared.remove(handle)
        XCTAssertNil(weakSentry, "注销后订阅表仍在持有处理器 —— 闭包泄漏（被捕获对象永不释放）")
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

        // ⚠️ await 送达后再断言：本用例要证的是「事件触达了回收器」，
        // 不是「同步触达」——同步性由 testPostOnMainThreadDeliversSynchronously 独占守卫。
        await waitUntil { ModrinthCategoryCache.cachedModItems == nil }

        XCTAssertNil(ModrinthCategoryCache.cachedModItems,
                     "内存压力事件没有触达缓存回收器 —— 事件发布与订阅没接上")
        XCTAssertNil(ModrinthCategoryCache.lastGameSubCategory,
                     "子分类标记也必须一起清（否则 cachedGameVersions(for:) 会拿错子分类比对）")
    }

    /// 注册是**幂等**的：重复调用不得往订阅表里塞第二个处理器。
    ///
    /// 这里直接数订阅表条数（`handlerCount`），而不是像先前那样「连注册三次后看缓存还是不是被清掉」
    /// —— 后者根本区分不出 1 个处理器和 3 个处理器，等于没测幂等性（2026-09-25 自查发现并换掉）。
    ///
    /// 反证：摘掉 `MemoryCacheReclaimer.register()` 里的 `guard token == nil else { return }`，
    /// 本用例会精确变红（条数 +2）。
    func testReclaimerRegistrationIsIdempotent() async {
        // 先确保已经注册过一次，再重复调用，观察条数不变
        MemoryCacheReclaimer.register()
        let afterFirst = MemoryPressureBroadcaster.shared.handlerCount

        MemoryCacheReclaimer.register()
        MemoryCacheReclaimer.register()

        XCTAssertEqual(MemoryPressureBroadcaster.shared.handlerCount, afterFirst,
                       "重复注册往订阅表里塞了额外处理器 —— 幂等守卫失效（会重复清缓存）")
    }

    // MARK: - 无订阅者

    /// 订阅者为空时发布不得崩、也不得有任何延迟副作用。
    ///
    /// ⚠️ 这里必须**等一轮**再断言：`post` 在后台路径上是异步送达的，
    /// 若紧接着断言，就算注销失效、处理器真的被调用了也看不出来（本用例曾在
    /// 2026-09-25 的反向用例里因此「假绿」过一次）。
    func testPostWithoutHandlersDoesNotCrash() async {
        var received: [MemoryPressureLevel] = []
        let token = MemoryPressureBroadcaster.shared.add { received.append($0) }
        MemoryPressureBroadcaster.shared.remove(token)

        MemoryPressureBroadcaster.shared.post(.warning)
        MemoryPressureBroadcaster.shared.post(.critical)

        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(received.isEmpty, "已注销的处理器仍被调用")
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
//     需要真的把进程内存压到阈值，属集成测试范畴。本文件用同构的定时源代替，
//     只证明「该回调上下文里发布能送达」，不证明「内核真的会在压力下回调」。
//  3. 「AppContext 不再引用 DownloadCategoryView」是**编译期/源码级**性质，
//     运行期无法断言（方法已删除，引用它根本编译不过）。由 `grep` 与真实编译共同证明。
//  4. `AppContext` 的**生命周期**（`deinit` 是否会取消 source）无对应用例，但已逐条读代码核对：
//     - `AppContext.shared` 是进程级单例 ⇒ `deinit` 实际永不执行，`deinit { memoryPressureSource?.cancel() }`
//       是防御性写法（这条在 `docs/SWIFT_LANGUAGE_CHECKLIST.md` §1.7 G4 也记过）；
//     - 引用关系：`AppContext` →(强) `memoryPressureSource` →(强) 事件处理器 →(弱) `AppContext`
//       ⇒ **无环**；处理器不直接捕获局部变量 `source`（改为经 `self.memoryPressureSource` 间接取用），
//       否则会形成 `source ↔ handler` 的自环、使 `cancel()` 永远等不到；
//     - `MemoryCacheReclaimer` 注册的闭包**不捕获任何实例**（只引用 4 个静态类型）
//       ⇒ 不存在「handler 反向保活 AppContext」的强引用链。
//     「注销后不再持有捕获」这一半由 `testRemovedHandlerReleasesItsCaptures` 钉住；
//     `AppContext` 那一半因无法实例化而只能靠读代码。
