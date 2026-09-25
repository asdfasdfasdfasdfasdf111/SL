import Foundation
import os

/// Java 解析的同步桥接层。
///
/// 背景：`SLLaunchBridge.slLaunchInternal` 运行在同步上下文里（内部用 `DispatchSemaphore`
/// 等待扫描结果），而统一的 `JavaResolver` 是 async 接口。直接把启动桥改成异步会牵动
/// 整条进程启动链路，风险过高。
///
/// 因此这里保留一个**受超时保护**的同步包装：启动链路复用统一解析器，
/// 失败或超时返回 `nil`，由调用方回退到旧链路，保证行为不退化。
///
/// 调用方实际所在线程（实读调用链，结论见 `docs/SWIFT_LANGUAGE_CHECKLIST.md` §8.2）：
/// `slLaunchInternal` 由 `SLLaunchBridge.slLaunch` 内的
/// `DispatchQueue.global(qos: .userInitiated).async` 驱动，恒运行在 GCD 全局并发队列的工作线程上，
/// **不在主线程**；因此本桥接正常路径仍会阻塞等待，阻塞的是该 GCD 线程而非 UI 线程。
/// 头部的主线程判断是为「将来有人从 MainActor 直接调用」这一情形兜底，而非当前路径的常态。
///
/// 并发约束（本文件必须遵守的三条）：
/// 1. 类型与方法均**显式**标 `nonisolated`。工程开启了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
///    未标注隔离的自由函数与枚举静态方法会被推断为 `@MainActor`；若保留推断，内部的
///    `DispatchSemaphore.wait(timeout:)` 就会顶着「主 actor 隔离」的名义出现在任意线程上，
///    隔离声明与真实运行线程不一致，任何真正合规的 MainActor 调用方都会直接踩到 8 秒阻塞。
/// 2. 跨线程结果不再用裸 `var` 承接，改用 `OSAllocatedUnfairLock<URL?>`：写入方（`Task.detached`）
///    与读取方（调用线程）只在锁的临界区内触碰同一存储，由锁的 acquire/release 语义建立
///    happens-before，消除原先「只有信号量计时序、没有同步边缘」形成的读写数据竞争。
///    该原语与 `Features/Launch/Adapters/` 下的既有用法一致，不引入新依赖。
/// 3. 主线程调用**不阻塞**，直接走「放弃同步解析」路径。详见 `resolveSynchronously` 的说明。
nonisolated enum JavaResolverBridge {

    /// 同步解析一次 Java。
    /// - Parameters:
    ///   - minimumMajor: 最低 Java 主版本要求（0 表示不限制）
    ///   - mcVersion: Minecraft 版本号，仅用于日志追溯
    ///   - timeout: 等待上限；超时即放弃，避免阻塞应用启动
    ///   - makeResolver: 解析器工厂。默认 `{ DefaultJavaResolver() }`，即生产路径；
    ///     测试注入固定行为的解析器／仓储，才能确定性地覆盖「解析失败 → nil」。
    ///
    ///     **为什么参数类型带 `@MainActor`**：`DefaultJavaResolver` 在本工程的默认隔离设置下被推断为
    ///     主 actor 隔离，只能在主 actor 上构造。把工厂标成 `@MainActor` 后，它既能在下方既有的
    ///     `MainActor.run` 里被调用，又不要求本函数本身改成 async/隔离——沿用原有做法，不新增约束。
    ///     工厂值本身是 `@Sendable` 的，因此可以安全地跨进 `Task.detached`。
    ///     必须标 `@escaping`：它会被下面的 `Task.detached` 闭包捕获，而那个闭包是逃逸的。
    ///     （`@MainActor` 只约束「在哪个 actor 上调用」，不改变逃逸性；漏标 `@escaping` 的后果是
    ///     `escaping closure captures non-escaping parameter` —— 注意这条**类型检查层看不到**，
    ///     只有真实编译会报，见 `scripts/verify-build.sh` 的必要性说明。）
    /// - Returns: 可用 Java 的可执行文件路径；解析失败、超时或主线程调用时返回 nil
    ///
    /// 为什么不能在这里「同步等待异步」：
    /// Swift 官方（Swift 书《Concurrency》）已明确：标准库不提供、也不建议自行实现「从同步代码
    /// 等待异步结果」的能力，自行实现会带来竞态、线程问题与死锁；WWDC21 10254 进一步点名
    /// 「用非结构化任务 `Task.detached` + 信号量建立跨任务依赖」会破坏运行时对线程前向推进的契约。
    /// 本方法正是在「启动链路整体改 async 代价过高」这一约束下保留的过渡形态，因此必须把上述
    /// 风险压缩到最小：隔离显式化（第 1 条）、共享状态加锁（第 2 条）、阻塞前先判断线程（第 3 条）。
    ///
    /// 主线程调用时的取舍：
    /// 阻塞点是下面的 `semaphore.wait(timeout:)`，最长 8 秒。这个代价一旦落在主线程上就是 UI 冻结，
    /// 远高于「本次 Java 解析未命中」的代价。因此检测到主线程时**不启动解析、不阻塞、不留游离任务**，
    /// 立即返回 `nil`，交由调用方回退既有链路（缓存 Java → DataManager → JavaManager 三级兜底）。
    /// 这不构成行为退化：本桥接是优先路径而非唯一路径，返回 `nil` 本来就是它既有的失败语义。
    ///
    /// ⚠️ 这条早退分支的**优先级高于一切**：主线程调用时，即使注入的解析器一定能成功，也照样返回 `nil`。
    /// 因此**测试必须区分线程**：断言「解析结果」的用例都要在非主线程上调用（见 `JavaResolverBridgeTests`
    /// 的 `callOffMainThread`），否则所有断言都变成「nil 是因为主线程」，看不出任何被测行为。
    nonisolated static func resolveSynchronously(
        minimumMajor: Int,
        mcVersion: String?,
        timeout: TimeInterval = 8,
        makeResolver: @escaping @MainActor @Sendable () -> any JavaResolver = { DefaultJavaResolver() }
    ) -> URL? {
        // 主线程一律不阻塞：既不等待，也不留下无人回收的后台任务。
        if Thread.isMainThread {
            NSLog("[JavaResolverBridge] 主线程调用，放弃同步解析（避免阻塞 UI），回退既有链路")
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        // 结果容器：写入与读取都在锁内完成，锁本身提供 happens-before。
        // 因此即使超时返回后后台任务才写入，也只是「无人读取的写入」，不会构成无保护的共享可变访问。
        let resolved = OSAllocatedUnfairLock<URL?>(initialState: nil)

        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }

            // JavaRequirement / DefaultJavaResolver 在本工程的默认隔离设置下同样被推断为
            // `@MainActor`，而本函数刚显式改为 `nonisolated`：若在此处**同步**构造它们，
            // 就会从非隔离上下文同步访问主 actor 隔离的初始化器（默认隔离下即告警，
            // Swift 6 语言模式下为错误）。两个值都是纯数据/无状态对象，这里改到后台任务内
            // 通过 `await MainActor.run` 异步构造：既是官方允许的跨 actor 访问形态，
            // 也只是一次不阻塞任何线程的跳转（`await` 挂起的是任务，不是线程）。
            //
            // 解析器改为经 `makeResolver` 构造（默认仍是 `DefaultJavaResolver()`），
            // 于是「在主 actor 上构造」这条约束对它同样成立——这也是工厂必须标 `@MainActor` 的原因。
            let (requirement, resolver) = await MainActor.run {
                (JavaRequirement(
                    minimumMajor: max(0, minimumMajor),
                    mcVersion: mcVersion,
                    remarks: "SLLaunchBridge 同步桥接"
                ), makeResolver())
            }

            do {
                let installation = try await resolver.resolve(requirement)
                let executableURL = installation.executableURL
                resolved.withLock { $0 = executableURL }
            } catch {
                // 解析失败不是错误路径：调用方会回退到既有链路
                NSLog("[JavaResolverBridge] Java 解析未命中：\(error.localizedDescription)")
            }
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            // 超时后后台任务仍在执行且无法取消；其写入受锁保护，不会与调用方读取构成数据竞争。
            NSLog("[JavaResolverBridge] Java 解析超时（\(Int(timeout))s），回退既有链路")
            return nil
        }
        return resolved.withLock { $0 }
    }
}
