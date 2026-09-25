//
//  AppCompositionRoot.swift
//  装配根（composition root）：首帧之前的一次性运行时装配集中在这里，且**可被指名**。
//
//  为什么要有这个类型：原先这三行初始化直接写在 `SLApp.init()` 里，于是「装配根确实执行过」
//  这件事在测试里**指不出来** —— 用例只能去看副作用（例如内存压力订阅表里有没有 handler），
//  而那张订阅表是进程级状态、会被其它用例污染，也无法区分「应用注册的」与「测试注册的」。
//  把装配动作收进一个具名入口后，`SLApp.init()` 只剩一行调用，
//  「接线是否成立」就有了明确的观察点：`didRegisterRuntimeServices`（见下）。
//
//  职责：把各子系统的启动装配动作集中到一处 —— 装崩溃处理器、登记内存压力订阅、
//        预热本地目录。**只做「把谁装起来」，不含业务逻辑。**
//  边界：不持有运行时状态（`didRegisterRuntimeServices` 是例外，它记录的是「装配是否已发生」
//        这一事实本身，不是业务状态）。任何读盘的初始化都不得放进来：`SLApp.init()` 在主线程
//        且早于首帧，**同步 IO 会直接推迟窗口出现**；重活必须自己丢到后台
//        （`LocalModCatalog.warmUp` 内部就是 `Task.detached`）。
//
//  使用方：`App/qwqApp.swift` 的 `SLApp.init()` —— **唯一生产调用方**。
//  测试：`qwqTests/MemoryPressureTests.testCompositionRootRegistersReclaimerSubscription`
//        通过 `didRegisterRuntimeServices` 断言接线成立。
//  ⚠️ 不要为了「测入口本身」而在用例里调用 `registerRuntimeServices()`：一旦测试自己调过，
//     这个标志就不再能证明「应用装配根跑过」，那条用例会退化成假绿。
//     要测的是注册动作本身时，请直接测 `MemoryCacheReclaimer.register()`。
//  ⚠️ 也不要提供 `resetForTesting()`：把标志重置掉等于把唯一证据抹掉。
//     需要隔离状态的用例请用 `MemoryCacheReclaimer.resetForTesting()`。
//

import Foundation

/// 首帧之前的一次性运行时装配入口。**只在应用启动时调用一次。**
enum AppCompositionRoot {
    /// 装配是否已在**本进程内**执行过。
    ///
    /// 唯一置位点是下面的 `registerRuntimeServices()`，且置位发生在**所有装配动作之后**，
    /// 所以它为 `true` 可以断定「有人完整跑过装配入口」。
    ///
    /// 生产里唯一的调用方是 `SLApp.init()`；测试 bundle 由 `qwq.app` 宿主，
    /// 因此 `SLApp.init()` 会先于任何用例执行 —— 用例开始时这里应当已经是 `true`。
    /// 这正是「装配根接线成立」的可断言形式，且**不依赖用例执行顺序**：
    /// 它是单调的（置位后不再变），不会被其它用例的注册/注销影响。
    @MainActor
    private(set) static var didRegisterRuntimeServices = false

    /// 执行运行时装配。**不保证幂等** —— 里面三条各自的行为不由本类型控制，
    /// 生产路径靠「`SLApp.init()` 整个进程只执行一次」来保证只跑一遍。
    @MainActor
    static func registerRuntimeServices() {
        // 崩溃自捕获：崩溃后把线程堆栈写到 ~/Library/Logs/SL_crash.log（LLDB 拦截时系统不落 .ips）
        CrashReporter.install()
        // 内存压力订阅：把「各子系统缓存回收」登记为内存压力事件的订阅者。
        // 必须在装配期登记：`AppContext` 只发事件、不认识缓存属主。仅登记闭包，不读盘。
        MemoryCacheReclaimer.register()
        // 启动即后台预热本地 Modrinth 全量目录，让下载/mod 页首帧即有数据（参考 PCL 的加载器秒出）
        LocalModCatalog.warmUp()

        // 置位放在最后：三条装配动作都执行过，才算「装配已发生」。
        // 放在最前会让「执行到一半就崩」也留下 true，证据就不成立了。
        didRegisterRuntimeServices = true
    }
}
