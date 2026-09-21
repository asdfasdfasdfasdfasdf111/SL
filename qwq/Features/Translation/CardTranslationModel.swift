import SwiftUI
import Combine

/// 卡片副标题翻译状态 + 按需翻译调度（GameViews 列表页 / ModDetailView 详情页共享）。
///
/// 视图以 `@StateObject` 持有独立实例（非单例——列表页与详情页翻译的是不同项目集合）。
/// 统一调度流程：内存缓存（零阻塞）→ 磁盘缓存（detached 查盘，命中即应用）→ 网络翻译
/// （防抖 + 去重，滑动时未命中防抖窗口的请求被取消，不产生无谓网络请求）。
///
/// UAF 防护：所有异步写回先经 `isActive`（onAppear/onDisappear 联动）守卫，
/// 视图销毁后不再写 @Published 存储；网络分支再叠加 `[weak self]` 对象级守卫。
@MainActor
final class CardTranslationModel: ObservableObject {
    /// 已翻译副标题（项目 id → 中文），驱动卡片副标题实时更新
    @Published private(set) var translated: [String: String] = [:]

    /// 正在翻译中的项目 id（去重 + 超限裁剪的「活跃集」）
    private var pendingIDs: Set<String> = []

    /// 视图存活标记（onAppear/onDisappear 联动），销毁后异步回调不再写状态
    private var isActive = false

    /// 批量预取任务（切换分类时取消旧任务）
    private var prefetchTask: Task<Void, Never>?

    /// 视图出现：允许异步回调写回
    func activate() {
        isActive = true
    }

    /// 视图消失：禁止异步回调写回并取消批量预取
    func deactivate() {
        isActive = false
        prefetchTask?.cancel()
    }

    /// 取展示副标题：已翻译用译文，否则原文
    func subtitle(for item: DownloadedItem) -> String {
        translated[item.id] ?? item.subtitle
    }

    /// 批量应用翻译缓存（纯内存扫描 + 磁盘一次性批量预取）。
    /// 磁盘命中由 CacheManager.prefetchText 一次性枚举目录后批量读入内存：
    /// 相比逐条 fileExists+读盘，IO 次数从 O(n) 降到 O(1 次枚举 + 命中数)，
    /// 覆盖首屏 + 预加载窗口即可，避免对 12 万条本地目录做海量磁盘扫描
    func prefetch(_ items: [DownloadedItem], service: TranslationService) {
        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .background) { [weak self] in
            // 只预热前若干条目（覆盖首屏 + 预加载窗口），防止海量目录读盘拖慢启动
            let warmupCount = min(items.count, 5000)
            let ids = items.prefix(warmupCount).map { $0.id }
            let batch = service.prefetchTranslations(ids: ids)
            guard !batch.isEmpty, !Task.isCancelled else { return }
            // Sendable 闭包不可引用 weak var 捕获：先拷成强引用常量再进 MainActor.run
            guard let self else { return }
            await MainActor.run {
                guard !Task.isCancelled, self.isActive else { return }
                // 单次 merge 写入：只触发一次 body 重算；超限裁剪统一走 CardTranslationStore
                CardTranslationStore.merge(&self.translated, batch: batch, active: self.pendingIDs)
            }
        }
    }

    /// 按需翻译单个卡片：缓存命中直接应用，否则排队翻译（滚动到哪翻译到哪）
    ///
    /// 关键修复：原先在主线程直接调用 `cachedTranslation`（会同步读盘），
    /// 滚动时每个进入可视区的卡片都触发一次磁盘读取，造成主线程阻塞、列表卡顿。
    /// 现在主线程先查内存缓存（内置表 + 内存 LRU，瞬时、零阻塞），未命中才进入后续分支。
    ///
    /// 注意：后续分支里的 `Task.detached` 只保证「发起时不占用调用方线程」，
    /// 并不等于被调用的代码在后台线程执行——`TranslationService` 的
    /// `cachedTranslation` / `translateText` 均为主 actor 隔离方法（工程默认隔离为 MainActor），
    /// 跨域调用会 `await` 切回主 actor，磁盘读取与翻译编排实际仍落在主线程上。
    func requestTranslation(for item: DownloadedItem, service: TranslationService) async {
        let id = item.id
        guard !id.isEmpty, translated[id] == nil, !pendingIDs.contains(id) else { return }
        // 仅查内存缓存（内置表 + 内存 LRU），主线程零阻塞、瞬时返回
        if let cached = service.cachedTranslationInMemory(for: id), !cached.isEmpty {
            // 淡入动画：与网络翻译完成时的效果一致，避免瞬时跳变
            withAnimation(.easeInOut(duration: 0.3)) { setTranslated(id, cached) }
            return
        }
        pendingIDs.insert(id)
        let subtitle = item.subtitle
        // 磁盘缓存查询走 detached 立即执行（毫秒级、成本低，无需防抖）；
        // 命中即应用，减少「卡片出现 → 等防抖 → 再查盘」的感知延迟
        if let diskCached = await Task.detached(priority: .utility, operation: { service.cachedTranslation(for: id) }).value,
           !diskCached.isEmpty {
            if Task.isCancelled {
                pendingIDs.remove(id)
                return
            }
            // await 返回后已回到主线程（本方法 @MainActor）
            pendingIDs.remove(id)
            if !diskCached.isEmpty, isActive {
                withAnimation(.easeInOut(duration: 0.3)) { setTranslated(id, diskCached) }
            }
            return
        }
        // 磁盘未命中 → 网络翻译：短暂防抖，快速滑动时这张卡的任务会被取消 → 直接返回，不产生无谓的网络请求
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled {
            pendingIDs.remove(id)
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            // 隔离事实（原注释「必须脱离主线程执行」不成立）：`Task.detached` 确实不继承 actor
            // 隔离，但 `translateText` 自身是主 actor 隔离方法（工程默认隔离为 MainActor，该类未显式
            // 标注 `nonisolated`），对它的 async 调用会 `await` 切回主 actor，方法体仍在主线程执行。
            // 影响：`translateText` 在主线程内调用 semaphoreWait(Self.translationSemaphore)
            //（LockCompat.swift 明确该函数「阻塞当前线程直到拿到配额」），当并发翻译数超过上限 24 时
            // 主线程会一直阻塞到有配额释放，而配额要持有到该项目的网络竞速结束（URLSession 请求超时
            // 8~12s），期间界面无法响应；并发数未达上限时等待立即返回，无实际影响。
            // 依据：《Concurrency》Unstructured Concurrency —— `Task.detached` 不继承任何 actor
            // 隔离、优先级与任务局部状态；The Main Actor —— `@MainActor` 函数只在主 actor 上运行，
            // 从非主 actor 代码调用必须 `await` 切换到主 actor。
            // https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
            // 未做异步化改造的理由：让该方法真正脱离主 actor 需连带解除 CacheManager 及其内部
            // LRUCache / sha1Prefix 的默认 MainActor 隔离（实测仅去隔离 CacheManager 一项，
            // typecheck 告警即由 88 增至 104），且缓存的唯一入口 AppContext.shared 不在本次可改范围内。
            let result = try? await service.translateText(text: subtitle, projectId: id)
            let final = result ?? ""
            // Sendable 闭包不可引用 weak var 捕获：先拷成强引用常量再进 MainActor.run
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.pendingIDs.remove(id)
                if !final.isEmpty, self.isActive {
                    // 淡入动画：翻译完成时副标题文字柔和过渡，不再生硬跳变
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.setTranslated(id, final)
                    }
                }
            }
        }
    }

    private func setTranslated(_ id: String, _ value: String) {
        CardTranslationStore.set(&translated, id: id, value: value, active: pendingIDs)
    }
}
