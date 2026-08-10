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
            await MainActor.run {
                guard !Task.isCancelled, let self, self.isActive else { return }
                // 单次 merge 写入：只触发一次 body 重算；超限裁剪统一走 CardTranslationStore
                CardTranslationStore.merge(&self.translated, batch: batch, active: self.pendingIDs)
            }
        }
    }

    /// 按需翻译单个卡片：缓存命中直接应用，否则排队翻译（滚动到哪翻译到哪）
    ///
    /// 关键修复：原先在主线程直接调用 `cachedTranslation`（会同步读盘），
    /// 滚动时每个进入可视区的卡片都触发一次磁盘读取，造成主线程阻塞、列表卡顿。
    /// 现在主线程只查内存缓存（内置表 + 内存 LRU，瞬时、零阻塞），
    /// 磁盘读取与网络翻译全部下沉到后台任务，彻底解除滚动卡顿。
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
        if let diskCached = try? await Task.detached(priority: .utility, operation: { service.cachedTranslation(for: id) }).value,
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
            // 后台线程发起网络翻译：translateText 内含信号量阻塞等待，必须脱离主线程执行
            let result = try? await service.translateText(text: subtitle, projectId: id)
            let final = result ?? ""
            await MainActor.run {
                guard let self else { return }
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
