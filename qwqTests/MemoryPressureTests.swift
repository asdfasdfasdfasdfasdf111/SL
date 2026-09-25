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
// 10. **装配根确实注册了**：`SLApp.init()` → `AppCompositionRoot.registerRuntimeServices()` →
//     `MemoryCacheReclaimer.register()` 这条接线不能断 —— 断了的话真实运行时内存压力不会清任何缓存，
//     而「自己注册自己收」的用例仍然是绿的。
//     ⚠️ 这条**不能**用「订阅表里至少有 1 个 handler」来证：那是个会被其它用例污染的绝对条数。
//     本文件改为断言 `AppCompositionRoot.didRegisterRuntimeServices`（单调、不被污染，
//     唯一置位点是应用自己的装配入口），另加一句「后果」断言（条数 ≥ 1）。
//
//  ⚠️ **测试写法约定：一条失败只指向一个性质。**
//  只有第 3 条（`testPostOnMainThreadDeliversSynchronously`）**允许**不 `await` 就断言；
//  其余用例一律 `await` 送达后再断言。2026-09-25 反向用例实测：不 `await` 的版本在
//  「摘掉同步分支」这一个原因下会连带打红 5 条用例，失败信号指不到真正的性质上。
//
//  ⚠️ **进程级状态的处理约定**（2026-09-25 复核后改）：本文件涉及两处会跨用例持续的状态 ——
//  ① `MemoryPressureBroadcaster.shared` 的订阅表：每个只加自己 handler 的用例都
//     `defer { remove(token) }`，断言写成「本次注册的处理器收到什么」；
//  ② `MemoryCacheReclaimer.token`：动过它的用例必须先用 `resetForTesting()` 回到
//     「未注册」这一确定状态，再断言**差值**（`注册前条数 + 1`），收尾用
//     `restoreReclaimerRegistration()` 还原成进程启动时应有的「已注册」。
//     否则条数会由先前用例决定，断言只能退化成「大于等于 1」—— 那正是复核指出的假绿。
//
//  被测：Core/Events/MemoryPressure.swift、App/MemoryCacheReclaimer.swift、
//        App/AppCompositionRoot.swift
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

    // MARK: - 进程级状态还原

    /// 把 `MemoryCacheReclaimer` 还原成**进程启动时应有的状态**：已注册。
    ///
    /// 动过注册状态的用例在 `defer` 里调用它 —— 否则后续用例看到的订阅表条数
    /// 会被本用例决定（复核指出的「顺序污染」）。
    /// 之所以还原成「已注册」而不是「未注册」：真实进程里应用启动就注册过一次，
    /// 还原成未注册会让「条数 ≥ 1」这类后果断言在别的用例里无缘由地变红。
    private func restoreReclaimerRegistration() {
        MemoryCacheReclaimer.resetForTesting()
        MemoryCacheReclaimer.register()
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

    /// 装配根（`SLApp.init()` → `AppCompositionRoot.registerRuntimeServices()`）必须真的跑过。
    ///
    /// **本条守卫的是「接线」，与下面那条「注册了就能清缓存」是两条不同性质。**
    ///
    /// ⚠️ 这里**不**断言「订阅表里至少 1 个 handler」——那是绝对条数，会被本文件其它用例
    /// （它们会自己 `register()`）污染，也不能区分「应用注册的」与「测试注册的」。
    /// 改成断言 `AppCompositionRoot.didRegisterRuntimeServices`：
    /// 它**单调**（置位后不再被任何人重置）、**唯一置位点**就是应用自己的装配入口，
    /// 所以不依赖用例执行顺序。测试 bundle 由 `qwq.app` 宿主，`SLApp.init()` 先于任何用例执行。
    ///
    /// 第二句是「后果」断言：装配跑过则订阅表必然非空。它单独不构成证据（会被污染），
    /// 只用来确认注册的效果真实可见 —— 而它之所以稳定，是因为动过注册状态的用例
    /// 都会在 `defer` 里 `restoreReclaimerRegistration()` 还原。
    ///
    /// 反证（实测）：把 `AppCompositionRoot.registerRuntimeServices()` 从 `SLApp.init()` 摘掉，
    /// 本用例**精确只红这一条**（单跑与全量跑都是 1 条失败）。
    /// 若本用例变红，按顺序查：① 那行调用是否被删；② `AppCompositionRoot` 里是否漏调
    /// `MemoryCacheReclaimer.register()`；③ 测试 target 的 `TEST_HOST` 是否仍指向 `qwq.app`
    /// （宿主没了则 `SLApp.init()` 不会执行，此断言便无从成立）。
    func testCompositionRootRegistersReclaimerSubscription() async {
        XCTAssertTrue(
            AppCompositionRoot.didRegisterRuntimeServices,
            "应用装配根没有执行 —— SLApp.init() 到 AppCompositionRoot.registerRuntimeServices() 的接线断了。"
                + "真实运行时内存压力将不会清理任何缓存，而所有「自己注册自己收」的用例仍然是绿的。")

        XCTAssertGreaterThanOrEqual(
            MemoryPressureBroadcaster.shared.handlerCount, 1,
            "装配根注册的内存压力订阅在订阅表里不可见 —— 注册动作没有真正生效")
    }

    /// `MemoryCacheReclaimer.register()` 之后，一次事件必须清掉 `ModrinthCategoryCache` 的内存缓存。
    ///
    /// 这是「聚合动作搬到装配层」唯一可观测的证据：只验证 `post` 能触发处理器还不够，
    /// 得证明处理器里挂的确实是那批缓存清理。
    ///
    /// ⚠️ 先从「未注册」出发（`resetForTesting()`）：否则应用启动时那次注册会顶替本用例
    /// 自己那次注册，本用例在「注册失效」的情况下也会通过 —— 那就是复核说的假绿。
    ///
    /// 反证：把 `MemoryCacheReclaimer.register()` 里的 `add` 去掉（注册不再产生处理器），
    /// 缓存保持非 nil → 本用例变红（真实运行里对应的就是「内存压力来了但缓存不清」）。
    func testReclaimerRegistrationClearsModrinthMemoryCache() async {
        // 造一份非空内存缓存（显式保存/还原，避免污染其它用例）
        let savedModItems = ModrinthCategoryCache.cachedModItems
        let savedSubCategory = ModrinthCategoryCache.lastGameSubCategory
        defer {
            ModrinthCategoryCache.cachedModItems = savedModItems
            ModrinthCategoryCache.lastGameSubCategory = savedSubCategory
        }

        // 注册状态也一样要还原：从确定状态出发，收尾还原成进程启动态
        MemoryCacheReclaimer.resetForTesting()
        defer { restoreReclaimerRegistration() }

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

    /// 首次注册恰好新增 **1** 个处理器。
    ///
    /// ⚠️ 这条只有在 `resetForTesting()` 之后才有意义 —— 它断言的是**差值**，
    /// 而不是「订阅表里有没有东西」。先前的写法用绝对条数（`handlerCount >= 1`），
    /// 分不出「本次注册生效」与「先前用例注册过」（2026-09-25 复核指出）。
    ///
    /// 反证：`resetForTesting()` 失效（不再清令牌）→ 阈值前的条数已被占住 → 本用例变红且只红这一条。
    func testFirstRegisterAddsExactlyOneHandler() async {
        MemoryCacheReclaimer.resetForTesting()
        defer { restoreReclaimerRegistration() }

        let before = MemoryPressureBroadcaster.shared.handlerCount
        MemoryCacheReclaimer.register()

        XCTAssertEqual(MemoryPressureBroadcaster.shared.handlerCount, before + 1,
                       "首次注册没有新增（或新增了不止一个）处理器 —— 注册动作失效或重复挂载")
    }

    /// 注册是**幂等**的：重复调用不得往订阅表里塞第二个处理器。
    ///
    /// 与上一条互补：上一条管「第一次 +1」，本条管「之后 +0」。拆开写是为了让失败信号
    /// 精确落在「幂等守卫失效」上 —— 合成一条的话，`guard` 被摘掉时会连带上一条一起红。
    ///
    /// 反证：摘掉 `MemoryCacheReclaimer.register()` 里的 `guard token == nil else { return }`，
    /// 本用例**精确只红这一条**（条数 +2）。
    func testRepeatedRegisterAddsNoHandler() async {
        MemoryCacheReclaimer.resetForTesting()
        defer { restoreReclaimerRegistration() }

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
//  5. **不在用例里构造 `SLApp()`**（`_ = SLApp()`），尽管那是最直白的「执行装配根」方式。
//     原因有两条，都会让证据不成立：
//     · `SLApp` 有 `@NSApplicationDelegateAdaptor(AppDelegate.self)` 存储属性 —— 构造第二个
//       `SLApp` 实例会再建一个 AppDelegate 适配器，而宿主进程里已经有一个在跑；
//     · 真正要证的「装配执行过」在**宿主启动那一刻就已经发生过**（测试 bundle 由 `qwq.app` 宿主，
//       `SLApp.init()` 先于任何用例执行），再构造一次只是在重复自己，并不能多证明什么。
//     ⇒ 因此改为观察 `AppCompositionRoot.didRegisterRuntimeServices` 这个**单调标志**。
//     ⚠️ 这条依赖「测试 target 的 `TEST_HOST` 指向 `qwq.app`」。若哪天测试改成无宿主的
//     logic test，标志会是 false、`testCompositionRootRegistersReclaimerSubscription` 变红 ——
//     那是**正确**的失败（装配根确实不再被执行），按该用例注释里的三步排查，不要直接删断言。
