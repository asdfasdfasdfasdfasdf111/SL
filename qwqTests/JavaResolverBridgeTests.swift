//
//  JavaResolverBridgeTests.swift
//  qwqTests
//
//  覆盖 `Features/Java/JavaResolverBridge.swift`（同步桥接层：启动链在同步上下文里复用统一解析器）。
//
//  ⚠️ 读本文件前必须先知道的一件事：`resolveSynchronously` 的**第一条分支是「主线程 → 立即返回 nil」**
//  （实现里的 `Thread.isMainThread` 早退，用意是避免 8 秒信号量等待冻结 UI）。而本工程的测试 target
//  开启了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，`XCTestCase` 的 async 用例体就跑在主线程上。
//  两者相遇的后果是：**只要在用例里直接调用桥接，被测行为就会被那条早退分支整体短路** ——
//  不论超时、解析成功还是解析失败，拿到的都是 nil。
//
//  这正是本文件 2026-09-25 重写前的真实状态：当时的用例断言「timeout=0 → nil」「极小超时 → nil」
//  「负数超时 → nil」「5 次零超时调用要秒级返回」，全部为真；但它们**并不能证明超时保护生效**，
//  因为 nil 来自主线程早退、快也来自主线程早退。属典型的假绿（绿了，但没测到声称测的东西）。
//
//  因此本文件把「调用线程」变成必须显式选择的两个入口：
//    · `callOffMainThread` —— 在 `Task.detached` 里调用，走**真实**解析路径；
//      所有关于「解析结果 / 超时」的断言都必须用它。
//    · `callOnMainThread`  —— 在 `MainActor.run` 里调用，用于断言**主线程早退**这条性质本身。
//  两者配对（同一份「必定成功」的解析器，唯一变量是线程），才能做到「一条失败只指向一个性质」。
//
//  注入点：`resolveSynchronously(minimumMajor:mcVersion:timeout:makeResolver:)` 的 `makeResolver`
//  （2026-09-25 新增）。默认值 `{ DefaultJavaResolver() }` 即生产路径；注入替身即可确定性地
//  构造「解析命中」与「解析未命中」，不必依赖本机是否装了 Java。
//
//  与 `JavaResolverTests.swift` 的分工（两层合起来才是完整的）：
//    · 那一边覆盖「**什么情况会抛** scanFailed / noCompatibleVersion / notFound」——
//      用 fake 仓储驱动真实 `DefaultJavaResolver`，验证判因逻辑；
//    · 本文件覆盖「**桥接拿到结果或错误之后怎么办**」——命中则透传路径，出错则一律吞掉、
//      只打日志、返回 nil，且失败要立刻返回而不是耗满 timeout。判因逻辑不在这里重复验证。
//
//  为什么本文件不跑一次「真实默认解析器」：`DefaultJavaRepository.save` 会写入
//  `JavaManager.shared.saveCachedJavaPath`，即**真实用户设置**。让测试去驱动真实扫描
//  等于在测试里改用户数据，故一律用替身。代价与缺口见文末「覆盖率缺口」。
//

import XCTest
@testable import qwq

// MARK: - 测试替身与小工具

/// 当前是否在主线程。
///
/// 刻意**不用** `Thread.isMainThread`：在异步上下文里读它会被工具链判为
/// `class property 'isMainThread' is unavailable from asynchronous contexts`（新增告警，
/// 且 Swift 6 语言模式下是错误），而本文件恰恰要在 async 用例里观察线程。
/// `pthread_main_np()` 是同一判定的底层 C 调用（`Thread.isMainThread` 内部就是它），
/// 同步/异步上下文里都可用且无告警。
///
/// 必须标 `nonisolated`：本工程默认隔离为 MainActor，未标注的文件级函数会被推断为 `@MainActor`，
/// 那样就没法在 `Task.detached` 里读了。函数体只调 C 函数，不存在隔离成员的连带访问。
nonisolated private func isOnMainThread() -> Bool { pthread_main_np() != 0 }

/// 线程安全的值盒：在 `@Sendable` 工厂闭包与用例之间传递一个值（闭包不能捕获可变局部变量）。
private final class ValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T?
    func set(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        storage = value
    }
    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// 线程安全的调用计数器：用来断言「工厂到底有没有被调用」。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() {
        lock.lock(); defer { lock.unlock() }
        storage += 1
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// `JavaResolver` 的测试替身：按预设结果返回或抛错，可选地记录收到的需求、并插入人为延迟。
///
/// 与 `DefaultJavaResolver` 一样，在默认隔离设置下被推断为 `@MainActor` —— 单这一点就要求
/// `makeResolver` 的签名带 `@MainActor`（否则本替身无法在主 actor 上构造）。它也正因是
/// 主 actor 隔离类型而**隐式满足 `Sendable`**，不需要 `@unchecked Sendable` 这类逃生舱。
private final class StubJavaResolver: JavaResolver {

    /// 预设结果：`.failure` 用来构造三条「解析未命中」分支
    private let outcome: Result<JavaInstallation, JavaResolutionError>

    /// 返回前的人为延迟（秒），用来模拟「扫描很慢」从而触发超时
    private let delay: TimeInterval

    /// 非 nil 时把 `resolve` 收到的需求写入该盒子，供用例跨线程读取
    private let capture: ValueBox<JavaRequirement>?

    init(outcome: Result<JavaInstallation, JavaResolutionError>,
         delay: TimeInterval = 0,
         capture: ValueBox<JavaRequirement>? = nil) {
        self.outcome = outcome
        self.delay = delay
        self.capture = capture
    }

    convenience init(returning installation: JavaInstallation,
                     capture: ValueBox<JavaRequirement>? = nil) {
        self.init(outcome: .success(installation), capture: capture)
    }

    convenience init(failingWith error: JavaResolutionError) {
        self.init(outcome: .failure(error))
    }

    convenience init(delaying seconds: TimeInterval, returning installation: JavaInstallation) {
        self.init(outcome: .success(installation), delay: seconds)
    }

    convenience init(delaying seconds: TimeInterval, failingWith error: JavaResolutionError) {
        self.init(outcome: .failure(error), delay: seconds)
    }

    func resolve(_ requirement: JavaRequirement) async throws -> JavaInstallation {
        capture?.set(requirement)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return try outcome.get()
    }
}

/// 替身回传的固定安装。路径不指向真实文件是刻意的：桥接只做**透传**，
/// 「路径真的存在吗」由解析器/仓储侧保证（见 `JavaResolverTests`），本文件不重复验证。
private let stubInstallation = JavaInstallation(
    executableURL: URL(fileURLWithPath: "/opt/stub/java21/bin/java"),
    majorVersion: 21,
    fullVersion: "21.0.2",
    architecture: .universal,
    vendor: "stub",
    isCompatible: true,
    isJDK: true
)

// MARK: - 用例

final class JavaResolverBridgeTests: XCTestCase {

    // MARK: 调用入口（本文件的核心：线程必须显式选择）

    /// 在**非主线程**上调用桥接 —— 走真实解析路径。
    ///
    /// ⚠️ 断言「解析结果 / 超时」的用例必须用这个入口，否则会先撞上主线程早退分支而假绿。
    /// `Task.detached` 恒在全局并发执行器上运行，不会落到主线程。
    private func callOffMainThread(
        minimumMajor: Int,
        mcVersion: String? = nil,
        timeout: TimeInterval = 8,
        makeResolver: @escaping @MainActor @Sendable () -> any JavaResolver = { DefaultJavaResolver() }
    ) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            JavaResolverBridge.resolveSynchronously(
                minimumMajor: minimumMajor,
                mcVersion: mcVersion,
                timeout: timeout,
                makeResolver: makeResolver
            )
        }.value
    }

    /// 在**主线程**（主 actor）上调用桥接 —— 用于断言主线程早退这条性质本身。
    private func callOnMainThread(
        minimumMajor: Int,
        mcVersion: String? = nil,
        timeout: TimeInterval = 8,
        makeResolver: @escaping @MainActor @Sendable () -> any JavaResolver = { DefaultJavaResolver() }
    ) async -> URL? {
        await MainActor.run {
            JavaResolverBridge.resolveSynchronously(
                minimumMajor: minimumMajor,
                mcVersion: mcVersion,
                timeout: timeout,
                makeResolver: makeResolver
            )
        }
    }

    // MARK: 前提（本文件全部断言的基石）

    /// 两个线程前提必须成立，否则下面的用例会退化成假绿：
    /// ① `MainActor.run` 内是主线程 —— `callOnMainThread` 才真的在测早退分支；
    /// ② `Task.detached` 内不是主线程 —— `callOffMainThread` 才真的绕开了早退分支。
    ///
    /// 把前提本身钉成断言，是为了让「下一个人换掉调用方式」时立刻变红，
    /// 而不是悄悄退回「所有断言都因为主线程返回 nil 而变绿」的状态。
    func testThreadPremisesHold() async {
        let onMain = await MainActor.run { isOnMainThread() }
        XCTAssertTrue(onMain, "MainActor.run 应落在主线程上，否则 callOnMainThread 测不到早退分支")

        let offMain = await Task.detached { isOnMainThread() }.value
        XCTAssertFalse(offMain, "Task.detached 不得落在主线程上，否则 callOffMainThread 会被早退分支短路")
    }

    // MARK: 主线程早退

    /// 主线程调用：**即使注入的解析器必定成功**，也必须立即返回 nil，且完全不触碰工厂
    /// （不构造解析器，也就不可能留下无人回收的游离任务）。
    ///
    /// 与 `testOffMainThreadReturnsExecutableURLOnSuccess` 配对：两者用的是同一份「必定成功」的解析器，
    /// 唯一变量是调用线程 ⇒ 这条失败只可能指向「主线程早退」这一个性质。
    ///
    /// timeout 故意放大到 10 秒：若早退分支失效，调用会阻塞主 actor 直到信号量超时——
    /// 届时「耗时必须远小于 timeout」这条断言会带着可读的原因变红（而不是默默等 10 秒后拿到 nil 还算通过）。
    func testMainThreadCallReturnsNilWithoutTouchingResolver() async {
        let factoryCalls = CallCounter()

        let start = Date()
        let result = await callOnMainThread(minimumMajor: 21, mcVersion: "1.20.6", timeout: 10, makeResolver: {
            factoryCalls.increment()
            return StubJavaResolver(returning: stubInstallation)
        })
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "主线程调用必须放弃同步解析，避免冻结 UI")
        XCTAssertEqual(factoryCalls.count, 0, "主线程早退时不应构造解析器")
        XCTAssertLessThan(elapsed, 2.0,
                          "主线程调用耗时 \(elapsed)s，说明早退分支没生效（会冻结 UI 直到 timeout）")
    }

    // MARK: 命中（非主线程）

    /// 非主线程 + 必定成功的解析器 ⇒ 原样透传该安装的可执行文件路径。
    func testOffMainThreadReturnsExecutableURLOnSuccess() async {
        let result = await callOffMainThread(minimumMajor: 21, mcVersion: "1.20.6", makeResolver: {
            StubJavaResolver(returning: stubInstallation)
        })
        XCTAssertEqual(result, stubInstallation.executableURL, "解析命中时必须原样回传 executableURL")
    }

    /// 桥接对入参的钳制：负数与 `Int.min` 的 `minimumMajor` 在构造需求前被钳到 0。
    /// 该断言过去做不了 —— 没有注入点就拿不到「解析器实际收到的需求」，
    /// 只能退而断言「不崩溃」，而那又被主线程早退掩盖着。
    func testMinimumMajorIsClampedBeforeReachingResolver() async {
        for input in [-5, Int.min] {
            let captured = ValueBox<JavaRequirement>()
            _ = await callOffMainThread(minimumMajor: input, mcVersion: nil, timeout: 8, makeResolver: {
                StubJavaResolver(returning: stubInstallation, capture: captured)
            })
            XCTAssertEqual(captured.value?.minimumMajor, 0,
                           "minimumMajor=\(input) 应在构造 JavaRequirement 前被钳到 0")
        }
    }

    /// 超大 `minimumMajor` 不得被钳制、不得溢出崩溃，且 `mcVersion` 原样透传（它仅用于日志追溯）。
    func testExtremeMinimumMajorAndNilVersionArePassedThrough() async {
        let captured = ValueBox<JavaRequirement>()
        _ = await callOffMainThread(minimumMajor: Int.max, mcVersion: nil, timeout: 8, makeResolver: {
            StubJavaResolver(outcome: .failure(.scanFailed), capture: captured)
        })
        XCTAssertEqual(captured.value?.minimumMajor, Int.max, "Int.max 应原样透传，不得被钳到其它值")
        XCTAssertNil(captured.value?.mcVersion, "mcVersion 为 nil 时应原样透传")
        XCTAssertEqual(captured.value?.remarks, "SLLaunchBridge 同步桥接",
                       "桥接注入的 remarks 用于日志追溯，不应被改掉")
    }

    // MARK: 超时（非主线程，真实走完等待逻辑）

    /// 解析器迟迟不返回时，必须在 timeout 到达后返回 nil 并交还控制权。
    /// 下界断言（≥ 0.25）保证这条走的是**真的等待到超时**，而不是因为别的原因提前返回。
    func testSlowResolverTimesOutAndReturnsNil() async {
        let start = Date()
        let result = await callOffMainThread(minimumMajor: 21, mcVersion: nil, timeout: 0.3, makeResolver: {
            StubJavaResolver(delaying: 5, returning: stubInstallation)   // 解析要 5 秒，远超 0.3 秒上限
        })
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "等待超过 timeout 时必须放弃解析并返回 nil")
        XCTAssertGreaterThanOrEqual(elapsed, 0.25, "返回得比 timeout 还早，说明测的不是超时路径")
        XCTAssertLessThan(elapsed, 3.0,
                          "timeout=0.3 却耗时 \(elapsed)s，说明超时保护未生效，启动会被扫描拖死")
    }

    /// 零 / 负 / 极小 timeout（调用方误传）一律按「已经超时」处理：返回 nil、不崩溃、不永久等待。
    func testDegenerateTimeoutsReturnNilPromptly() async {
        for timeout in [0.0, -1.0, 0.001] {
            let start = Date()
            let result = await callOffMainThread(minimumMajor: 17, mcVersion: nil, timeout: timeout, makeResolver: {
                StubJavaResolver(delaying: 5, returning: stubInstallation)
            })
            XCTAssertNil(result, "timeout=\(timeout) 时应放弃解析")
            XCTAssertLessThan(Date().timeIntervalSince(start), 2.0,
                              "timeout=\(timeout) 却阻塞了 2 秒以上，说明退化入参没有被当作已超时处理")
        }
    }

    // MARK: 解析未命中 → nil（注入替身，三条原因逐条覆盖）

    /// 三条「解析未命中」原因都必须被桥接**吞掉**（不抛错、不崩溃）并返回 nil，交调用方回退旧链路。
    ///
    /// 用循环而非三个独立方法：三者被测行为完全相同（同一条分支），拆成三条用例只会让
    /// 「一条失败指向一个性质」变模糊。三条原因**在什么条件下抛**由 `JavaResolverTests` 覆盖。
    ///
    /// 线程必须是非主线程 —— 否则 nil 来自主线程早退，与解析失败无关。
    func testResolutionFailuresAreSwallowedAndReturnNil() async {
        let requirement = JavaRequirement(minimumMajor: 21, mcVersion: "1.20.6")
        let cases: [(name: String, error: JavaResolutionError)] = [
            ("scanFailed", .scanFailed),
            ("noCompatibleVersion", .noCompatibleVersion(requirement: requirement, available: [])),
            ("notFound", .notFound(requirement))
        ]

        for testCase in cases {
            let result = await callOffMainThread(minimumMajor: 21, mcVersion: "1.20.6", timeout: 8, makeResolver: {
                StubJavaResolver(failingWith: testCase.error)
            })
            XCTAssertNil(result, "\(testCase.name) 时应吞掉错误并返回 nil，交调用方回退既有链路")
        }
    }

    /// 解析失败要**立刻**返回，而不是把 timeout 耗满。
    /// 依据：实现里 `defer { semaphore.signal() }` 在解析抛出后立即放行信号量。
    /// 若有人删掉那句 `defer`，本用例会因耗时逼近 timeout 而变红 —— 注意此时返回值**仍是 nil**，
    /// 只有耗时能把「提前返回」和「等满超时」区分开，这也是这条断言存在的唯一理由。
    func testResolutionFailureReturnsWithoutBurningTimeout() async {
        let start = Date()
        let result = await callOffMainThread(minimumMajor: 21, mcVersion: nil, timeout: 8, makeResolver: {
            StubJavaResolver(failingWith: .scanFailed)
        })
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 3.0,
                          "解析失败却耗时 \(elapsed)s（timeout=8），说明失败路径没有提前放行信号量")
    }

    /// 慢解析器 + 失败结果：仍应在 timeout 内返回 nil（不因「失败得晚」而穿透超时保护）。
    func testSlowFailingResolverStillReturnsNilWithinTimeout() async {
        let start = Date()
        let result = await callOffMainThread(minimumMajor: 21, mcVersion: nil, timeout: 0.3, makeResolver: {
            StubJavaResolver(delaying: 5, failingWith: .notFound(JavaRequirement(minimumMajor: 21)))
        })
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 3.0, "慢解析器 + 失败结果不应穿透超时保护，实际耗时 \(elapsed)s")
    }

    // MARK: 返回值形状

    /// 命中时回传的必须是「本机文件 URL 形状」的路径，而不是任意 URL。
    func testNonNilResultIsAFileURLWithNonEmptyPath() async {
        let result = await callOffMainThread(minimumMajor: 0, mcVersion: "1.20.1", timeout: 2, makeResolver: {
            StubJavaResolver(returning: stubInstallation)
        })
        guard let url = result else {
            return XCTFail("注入必定成功的解析器后必须拿到非 nil 结果")
        }
        XCTAssertTrue(url.isFileURL, "桥接只应回传本机文件路径，实际：\(url)")
        XCTAssertFalse(url.path.isEmpty, "回传路径不得为空")
    }

    // MARK: 并发

    /// 并发调用各持自己的信号量：不得死锁、不得互相污染返回值。
    /// 每个迭代都注入各自的替身，因此可以断言**每次都能拿到自己的结果**，
    /// 而不是像改写前那样只能断言「都返回 nil」（那种断言在早退分支下毫无区分力）。
    func testConcurrentCallsDoNotDeadlockOrCrossTalk() async {
        await withTaskGroup(of: (Int, URL?).self) { group in
            for index in 0..<6 {
                group.addTask {
                    let installation = JavaInstallation(
                        executableURL: URL(fileURLWithPath: "/opt/stub/java\(index)/bin/java"),
                        majorVersion: 8 + index,
                        fullVersion: "\(8 + index).0.1",
                        architecture: .universal,
                        vendor: "stub",
                        isCompatible: true,
                        isJDK: true
                    )
                    let url = await Task.detached(priority: .userInitiated) {
                        JavaResolverBridge.resolveSynchronously(
                            minimumMajor: 0,
                            mcVersion: nil,
                            timeout: 8,
                            makeResolver: { StubJavaResolver(returning: installation) }
                        )
                    }.value
                    return (index, url)
                }
            }
            for await (index, url) in group {
                XCTAssertEqual(url?.path, "/opt/stub/java\(index)/bin/java",
                               "第 \(index) 次并发调用拿到了别人的结果，说明信号量/结果容器被串扰")
            }
        }
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. **生产默认工厂 `{ DefaultJavaResolver() }` 未被驱动**。要驱动它就会走到
//     `DefaultJavaRepository.save` → `JavaManager.shared.saveCachedJavaPath`，
//     那是**真实用户设置**：让测试去改用户数据比缺一条用例更糟。因此本文件的替身只验证
//     「桥接拿到结果/错误之后怎么办」，`DefaultJavaResolver` 自身的判因逻辑由
//     `JavaResolverTests`（fake 仓储）覆盖。默认值那一行只在代码评审层面被守住。
//  2. 超时后桥内的 `Task.detached` 仍会继续跑完（实现不取消它），可能仍有后续日志与仓储写入。
//     该副作用没有句柄可观测，本文件不做断言（实现注释已说明：其写入受 `OSAllocatedUnfairLock` 保护，
//     不与调用方读取构成数据竞争）。
//