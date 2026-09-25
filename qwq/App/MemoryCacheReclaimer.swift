//
//  MemoryCacheReclaimer.swift
//  内存压力 → 回收各子系统内存缓存的**装配**入口。
//
//  为什么放在 App 层：这里必须同时认识多个 Feature 的缓存入口（Modrinth 目录、翻译、
//  版本清单、加载器支持检查）—— 只有装配层（composition root）有权认识所有人。
//  基础设施 `AppContext` 只发布 `MemoryPressureBroadcaster` 事件，不认识任何具体缓存或 View。
//
//  历史：这段聚合逻辑原先挂在 `DownloadCategoryView.clearStaticCaches()`
//  （一个 `View` 类型上的 `static func`），并由 `AppContext` 直接调用 ——
//  构成 Infrastructure → UI 的反向依赖，且「清理各模块缓存」这件事被命名空间挂在了
//  一个与它无关的视图上（被清掉的 4 个缓存没有一个属于该视图）。
//  本次改为：事件由基础设施发布，聚合动作移到装配层，`DownloadCategoryView` 上的那个方法已删除。
//
//  使用方：`App/AppCompositionRoot.swift` 的 `registerRuntimeServices()`，
//          而它由 `App/qwqApp.swift` 的 `SLApp.init()` 调用（主线程、早于首帧，见那两个文件头部约束）。
//  测试：`qwqTests/MemoryPressureTests`。注意 `token` 是**进程级**静态状态 ——
//        用例若要断言「注册前后条数差多少」，必须先 `resetForTesting()` 回到确定状态，
//        否则条数会被先前用例决定（2026-09-25 复核指出过这一点）。
//

import Foundation

/// 内存压力下的缓存回收注册入口。**只在装配期调用一次**。
enum MemoryCacheReclaimer {
    /// 已注册的处理器令牌。非 nil 即「已注册」。
    ///
    /// 只读写在主 actor 上（`register()` 是 `@MainActor`），所以无需加锁。
    /// 存在它的意义是把「只调用一次」从注释里的口头约定变成**代码里可执行的约定**：
    /// 重复调用（App 结构体被重建、测试里多次调用）不会往订阅表里塞进重复处理器。
    @MainActor
    private static var token: UUID?

    /// 注册内存压力订阅。**幂等**：重复调用不产生第二个处理器。
    ///
    /// 等级处理：`warning` 与 `critical` 当前回收**同一批**缓存，与原实现（不分等级）
    /// 行为逐条一致 —— 这里刻意不引入「critical 才清某个缓存」这类新策略，属行为变更需单独评估。
    /// 等级仍原样透传，订阅方将来要分等级处理时无需改这里的注册方式。
    ///
    /// ⚠️ 被清掉的 4 个缓存全部只动内存、不碰磁盘（已逐个核对）：
    /// `ModrinthCategoryCache.clearAll` 明确注释「不动磁盘缓存」；
    /// `SearchTranslator.clearCache` 只清字典；`GameVersionManifest.clearCache` 只清内存索引与取回时间；
    /// `LoaderSupportChecker.clearMemoryCache` 只清内存表并取消未触发的刷盘任务。
    /// 因此本处理器可以安全地同步跑在内存压力事件里。
    @MainActor
    static func register() {
        guard token == nil else { return }
        token = MemoryPressureBroadcaster.shared.add { _ in
            ModrinthCategoryCache.clearAll()
            SearchTranslator.clearCache()
            GameVersionManifest.clearCache()
            LoaderSupportChecker.clearMemoryCache()
        }
    }

#if DEBUG
    /// **仅供测试**：注销并清空令牌，把状态还原成「未注册过」。
    ///
    /// 为什么需要它：`token` 是**进程级**静态状态，用例一旦调用 `register()` 就再也回不到
    /// 「未注册」。于是后续用例看到的订阅表条数会由**先前用例**决定，断言只能退化成
    /// 「大于等于 1」这类无法区分「谁注册的」的形式（2026-09-25 复核指出）。
    /// 有了它，用例可以从确定状态出发断言**差值**（`注册前条数 + 1`），与执行顺序无关。
    ///
    /// ⚠️ 生产代码不得调用；Release 构建里此方法不存在（`#if DEBUG`）。
    @MainActor
    static func resetForTesting() {
        if let token {
            MemoryPressureBroadcaster.shared.remove(token)
        }
        token = nil
    }
#endif
}
