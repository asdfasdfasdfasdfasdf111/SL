//
//  DownloadCategoryViewModel+Fetching.swift
//  分类页取数逻辑的扩展文件。
//  2026-10-03 自 DownloadCategoryViewModel.swift 拆出（纯物理搬移，逻辑零变更）。
//  拆出缘由：主文件 553 行职责饱满（状态/取数/搜索/分页），取数链（分页触底 +
//  分类取数 + 游戏版本清单编排）与状态声明正交，按项目既有做法（+Orchestration.swift
//  先例）单列一文件。
//

import Foundation
import Combine
import SwiftUI

extension DownloadCategoryViewModel {

    // MARK: - 分页

    /// 触底加载下一页（仅 Modrinth 网络分类；本地全量目录与游戏版本页没有更多数据）
    func loadMore() {
        guard hasMore, !isLoadingMore, selectedSection != .game else { return }
        isLoadingMore = true
        let section = selectedSection
        guard let type = ModrinthSectionType.type(for: section) else {
            isLoadingMore = false
            return
        }
        let query = activeSearchQuery
        let offset = currentOffset
        let baseItems = items
        Task {
            let result = await ModrinthSearcher.search(type: type, label: "", query: query, offset: offset, limit: 30)
            // 取消时**必须**一并清 isLoadingMore：该标志是 `loadMore` 入口守卫
            // （`guard hasMore, !isLoadingMore, …`）的一个条件，只 return 不清标志会把
            // 「本页没加载」变成「本分类此后永远不能再加载」——与 `LaunchCoordinator`
            // 非法字符分支未复位 `launchPhase`（按钮永久停在「准备中…」）是同一型缺陷。
            // 下面第 360 行的归属守卫作者记得复位，这一处漏了；补齐使三条出口一致。
            if Task.isCancelled { isLoadingMore = false; return }
            await MainActor.run {
                guard section == self.selectedSection else { self.isLoadingMore = false; return }
                var merged = baseItems
                let existingIds = Set(baseItems.map { $0.id })
                for item in result.items where !existingIds.contains(item.id) {
                    merged.append(item)
                }
                items = merged
                currentOffset = offset + result.items.count
                hasMore = result.totalHits > offset + result.items.count
                filteredResults = merged
                displayLimit = 120
                isLoadingMore = false
            }
        }
    }

    // MARK: - 取数

    /// 取当前分类的列表数据。
    ///
    /// 分支顺序与收口前逐条一致：
    /// 1. 非游戏分类且本地全量目录就绪 → 直接加载全量（不翻译）
    /// 2. 游戏分类 → 磁盘/内存清单先立即渲染，联网刷新放后台（首屏不等网络）
    /// 3. 其它分类的内存/磁盘缓存
    /// 4. 联网：游戏版本清单 或 Modrinth 检索
    func fetchItems(translation: CardTranslationModel) {
        fetchTask?.cancel()
        fetchToken &+= 1
        let token = fetchToken

        // 本地全量目录模式：mod/resourcepack/shader/modpack 直接加载全量（不翻译）
        // 仅当后台已解析完成时走本地目录，主线程绝不触碰磁盘/解压 12 万条目录
        if selectedSection != .game && LocalModCatalog.isReady {
            let local = LocalModCatalog.items(for: selectedSection)
            if !local.isEmpty {
                isLoading = true
                items = []
                filteredResults = []
                fetchTask = Task {
                    let result = LocalModCatalog.items(for: selectedSection)
                    if Task.isCancelled { return }
                    var shouldPrefetch = false
                    await MainActor.run {
                        // 归属校验：期间已发起新请求（切换分类/刷新）则丢弃本次结果
                        guard token == fetchToken else { return }
                        items = result
                        currentOffset = result.count
                        hasMore = false
                        isLoading = false
                        filteredResults = result
                        displayLimit = 120
                        searchPopInIds = []
                        shouldPrefetch = true
                    }
                    if shouldPrefetch {
                        translation.prefetch(result, service: TranslationService.shared)
                    }
                }
                return
            }
        }

        // 游戏版本：磁盘/内存清单先立即渲染，联网刷新放后台，不再让首屏等待网络。
        if selectedSection == .game,
           let cachedVersions = versionCatalog.cachedVersions() {
            let cached = makeMinecraftVersionItems(cachedVersions, subCategory: selectedSubCategory)
            if !cached.isEmpty {
                items = cached
                filteredResults = cached
                currentOffset = cached.count
                hasMore = false
                isLoading = false
                ModrinthCategoryCache.cachedGameVersions = cached
                ModrinthCategoryCache.lastGameSubCategory = selectedSubCategory
            }
        } else if let cached = ModrinthCategoryCache.cache(for: selectedSection, sub: selectedSubCategory) {
            items = cached
            currentOffset = cached.count
            hasMore = true
            isLoading = false
            if selectedSection != .game {
                translation.prefetch(cached, service: TranslationService.shared)
            }
            return
        }

        let targetSection = selectedSection
        if targetSection != .game || items.isEmpty { isLoading = true }
        if targetSection != .game { items = [] }
        fetchTask = Task {
            let result: [DownloadedItem]
            var totalHits = 0
            switch targetSection {
            case .game:
                result = await fetchMinecraftVersions(subCategory: selectedSubCategory, forceRefresh: true)
                totalHits = result.count
            case .mod, .resourcePack, .shader, .modpack:
                // 四类 Modrinth 分类统一走搜索 + 内存/磁盘缓存写回（type 由 ModrinthSectionType 映射）
                let type = ModrinthSectionType.type(for: targetSection) ?? "mod"
                let r = await ModrinthSearcher.search(type: type, label: "", limit: 100)
                result = r.items; totalHits = r.totalHits
                if !result.isEmpty {
                    ModrinthCategoryCache.setCache(result, for: targetSection)
                    if let key = ModrinthCategoryCache.diskKey(for: targetSection) {
                        ModrinthCategoryCache.saveToDisk(result, for: key)
                    }
                }
            }
            if Task.isCancelled { return }
            var shouldPrefetch = false
            await MainActor.run {
                // 归属校验：期间已发起新请求（切换分类/刷新）则丢弃本次结果
                guard token == fetchToken else { return }
                items = result
                filteredResults = result
                currentOffset = result.count
                hasMore = totalHits > result.count
                isLoading = false
                shouldPrefetch = targetSection != .game
            }
            if shouldPrefetch {
                translation.prefetch(result, service: TranslationService.shared)
            }
        }
    }

    /// 游戏版本清单：命中上次同子分类的游戏版本缓存则直接返回，否则拉取并按子分类过滤。
    ///
    /// 清单取数（主源/镜像并发、三级缓存、未列出版本合并）与分类规则分别由
    /// `VersionCatalogService` / `VersionFilterUseCase` 承担，本方法只做「清单 → 列表项」的编排。
    private func fetchMinecraftVersions(subCategory: GameSubCategory?, forceRefresh: Bool = false) async -> [DownloadedItem] {
        if !forceRefresh, subCategory == ModrinthCategoryCache.lastGameSubCategory, let cached = ModrinthCategoryCache.cachedGameVersions {
            return cached
        }
        let versions = await versionCatalog.fetchVersions(forceRefresh: forceRefresh)
        guard !versions.isEmpty else { return ModrinthCategoryCache.cachedGameVersions ?? [] }
        return makeMinecraftVersionItems(versions, subCategory: subCategory)
    }

    /// 清单快照 → 列表项：按子分类过滤后取版本号，并回写游戏版本缓存。
    ///
    /// 缓存写回先于空列表判断（与收口前一致：`makeMinecraftVersionItems` 无论结果是否为空都写缓存）。
    ///
    /// 副标题与标签在此处填充。此前每项只填 `id`/`name`/`subtitle = displayTitle`、`tags = []`，
    /// 于是整列表除版本号外完全一样（副标题恒为「正式版」），用户挑版本只能逐张读版本号 ——
    /// 评审第 4 条。现在：
    ///  - `subtitle`：`2026-08-12 · 正式版`（日期取清单 `releaseTime` 前 10 位即 yyyy-MM-dd）
    ///  - `tags`：`需 Java N`（`JavaRequirement`）与 `已安装`（本地 versions 目录）
    ///
    /// ⚠️ 结果会被缓存在 `ModrinthCategoryCache.cachedGameVersions`（按子分类），
    /// 因此「已安装」是**快照时刻**的状态：装完一个版本后需刷新（`forceRefresh`）才会更新。
    private func makeMinecraftVersionItems(_ versions: [MinecraftVersionInfo], subCategory: GameSubCategory?) -> [DownloadedItem] {
        let byID = Dictionary(versions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 已安装集合在循环外算一次：`installedVersionList` 会列举 versions 目录，不能逐项重来。
        // 用只读版本（不带 normalize 的磁盘重命名副作用）—— 本函数跑在主线程的列表渲染路径上。
        let rawInstalled = GameDirectoryScanner.installedVersionList(gameRoot: LauncherSettings.shared.selectedGameRoot)
        // 「已安装」匹配口径（2026-10-02 修复）：清单 id 是**不带加载器后缀**的版本号
        // （1.21.1），而本地目录可能被 normalizeVersionFolderNames 重命名为「版本-加载器」
        // （1.21.1-Fabric）。两侧集合一起判：id 精确命中 或 剥掉已知加载器后缀后命中。
        let installed = Set(rawInstalled)
        let installedBase = Set(rawInstalled.map { GameDirectoryScanner.baseVersionName(of: $0) })
        // 本地已安装的 Java 大版本集合（JavaManager 扫描结果已同步到 settings，主线程可读）。
        // 用它决定「此 Java 版本你已安装」绿勾：Java 向后兼容，本地装有 ≥ 所需大版本的
        // 任意一个即可跑该版本，故用「存在 ≥ 要求的安装」判定。
        let installedJavaMajors = Set(LauncherSettings.shared.availableJavaList.map { $0.majorVersion })
        // 用 `map` 而不是 `compactMap`：`versionFilter.ids` 是「从同一个 versions 数组过滤」
        // 得来的（`filter(...).map(\.id)`），所以 `byID` 必然命中；真要没命中，也该保留该项
        // （副标题退化为类型名）而不是静默丢一条 —— 列表少一项用户只会以为版本不存在。
        let result = versionFilter.ids(versions, subCategory: subCategory).map { id -> DownloadedItem in
            let info = byID[id]
            var tags: [String] = []
            let javaMajor = JavaRequirement.minimumMajor(forMinecraftVersion: id)
            if javaMajor > 0 {
                tags.append("需 Java \(javaMajor)")
                // 绿色勾（ContentCard 以 "✓" 前缀渲染成绿勾样式）：本地已装 ≥ 所需大版本
                // 的 Java 即可跑该版本，提示「此 Java 版本你已安装」而不是让用户再去装一个。
                if installedJavaMajors.contains(where: { $0 >= javaMajor }) {
                    tags.append("✓此 Java 版本你已安装")
                }
            }
            if installed.contains(id) || installedBase.contains(id) { tags.append("已安装") }
            return DownloadedItem(id: id,
                                  name: id,
                                  subtitle: info.map { Self.versionSubtitle(releaseTime: $0.releaseTime, type: displayTitle) } ?? displayTitle,
                                  iconURL: nil,
                                  tags: tags)
        }
        ModrinthCategoryCache.cachedGameVersions = result
        ModrinthCategoryCache.lastGameSubCategory = subCategory
        return result
    }

    /// 版本卡片副标题：`yyyy-MM-dd · 类型`。
    /// 清单没给发布日期时（`releaseTime` 为空串）退化为原来的类型名，避免出现 ` · 正式版` 这种前导分隔符。
    private static func versionSubtitle(releaseTime: String, type: String) -> String {
        let date = String(releaseTime.prefix(10))
        // 只接受形如 yyyy-MM-dd；异常形态一律不拼进副标题
        let looksLikeDate = date.count == 10
            && date.dropFirst(4).first == "-"
            && date.dropFirst(7).first == "-"
        return looksLikeDate ? "\(date) · \(type)" : type
    }
}
