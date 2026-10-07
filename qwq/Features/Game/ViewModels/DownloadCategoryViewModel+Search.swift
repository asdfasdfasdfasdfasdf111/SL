//
//  DownloadCategoryViewModel+Search.swift
//  分类页搜索过滤的扩展文件。
//  2026-10-03 自 DownloadCategoryViewModel.swift 拆出（纯物理搬移，逻辑零变更）。
//  拆出缘由：主文件 553 行职责饱满（状态/取数/搜索/分页），搜索链与其余部分正交，
//  按项目既有做法（+Orchestration.swift 先例）单列一文件。
//

import Foundation
import Combine
import SwiftUI

extension DownloadCategoryViewModel {

    // MARK: - 搜索

    /// 搜索过滤决策树（防抖 400ms）：
    /// 1. 空串：直接回填全部条目
    /// 2. 游戏版本页：本地过滤（统一谓词，tags 为空自动退化为标题+简介）
    /// 3. 其余分类：本地全量目录过滤（仅当后台解析完成，避免主线程同步解压目录）
    /// 4. 目录不可用：中文先翻译成英文再走 Modrinth 检索
    func applyFilter(translation: CardTranslationModel) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let normalized = searchText.replacingOccurrences(of: "。", with: ".")
            if normalized.trimmingCharacters(in: .whitespaces).isEmpty {
                await MainActor.run {
                    debouncedSearchText = searchText
                    activeSearchQuery = ""
                    filteredResults = items
                    displayLimit = 120
                    searchPopInIds = []
                }
                return
            }
            // 游戏版本页：本地过滤（本地版本列表；统一谓词，tags 为空自动退化为标题+简介）
            if selectedSection == .game {
                let filtered = items.filter { ItemFilter.matches($0, query: normalized) }
                await MainActor.run {
                    debouncedSearchText = searchText
                    activeSearchQuery = ""
                    filteredResults = filtered
                    displayLimit = 120
                    searchPopInIds = []
                }
                return
            }
            // 其余分类：优先本地全量目录过滤（标题/简介/标签，含中文标签直接匹配）
            // 仅当后台已解析完成时读取本地目录，避免主线程同步解压 12 万条目录造成卡顿
            if LocalModCatalog.isReady {
                let local = LocalModCatalog.items(for: selectedSection)
                if !local.isEmpty {
                    let literalHits = local.filter { ItemFilter.matches($0, query: normalized) }
                    var filtered = literalHits
                    // 中文查询一律取英文候选词并**合并**结果（不能挂在「零命中才触发」上）：
                    // Modrinth 允许作者用中文起项目名，原词常能字面命中少数中文命名模组——
                    // 若命中即短路，定译名能对上的正主（搜「地平线」的 Distant Horizons）
                    // 反而永远进不来，用户实测踩中。字面命中的条目排前面，定译名/机翻
                    // 新增的条目按目录原序接在后面；两条来源都取不到（断网）时只剩字面结果。
                    if ChineseText.contains(normalized) {
                        async let communityNames = CommunityNameResolver.englishNames(for: normalized)
                        async let machineTerms = SearchTranslator.translate(normalized)
                        let (community, machine) = await (communityNames, machineTerms)
                        // 两个 await 期间用户可能已继续输入（防抖任务被取消重启），
                        // 旧任务不得回写过滤结果 —— 与下方联网分支的取消守卫同一约定
                        if Task.isCancelled { return }
                        let englishTerms = community + machine
                        if !englishTerms.isEmpty {
                            let literalIds = Set(literalHits.map { $0.id })
                            let extra = local.filter {
                                !literalIds.contains($0.id) &&
                                ItemFilter.matchesAny($0,
                                                      queries: englishTerms,
                                                      originalQuery: normalized,
                                                      translatedSubtitle: translation.translated[$0.id])
                            }
                            filtered = literalHits + extra
                        }
                    }
                    await MainActor.run {
                    // 搜索结果弹入填充点之一：本分支是「用户输入关键词 → 本地全量目录检索结果写回」，
                    // 与下面的联网检索同属「搜索结果出现」语义（见 searchPopInIds 声明处的说明）：
                    // 目录随包分发且 `warmUp()` 预解析，实际运行时 isReady 恒为真、本分支先于联网分支
                    // 命中并 return，仅填联网分支会导致动画在正式构建里永不播放。
                    // 先于 filteredResults 写入：确保与触发本次重渲染的写入同批完成。
                    searchPopInIds = Set(filtered.map { $0.id })
                    debouncedSearchText = searchText
                    activeSearchQuery = ""
                    filteredResults = filtered
                    displayLimit = 120
                }
                translation.prefetch(filtered, service: TranslationService.shared)
                return
            }
            }
            // 目录不可用时：中文先翻译成英文，再调用 API 搜索全库（检索标题与简介）
            var searchQuery = normalized
            let hasChinese = ChineseText.contains(normalized)
            if hasChinese {
                let englishTerms = await SearchTranslator.translate(normalized)
                if !englishTerms.isEmpty {
                    searchQuery = englishTerms.joined(separator: " ")
                }
            }
            let section = selectedSection
            guard let type = ModrinthSectionType.type(for: section) else { return }
            let result = await ModrinthSearcher.search(type: type, label: "", query: searchQuery, offset: 0)
            if Task.isCancelled { return }
            guard isViewActive else { return }
            await MainActor.run {
                guard section == self.selectedSection else { return }
                // 搜索结果弹入填充点之二：本分支是「用户输入关键词 → 联网检索结果写回」，
                // 与上面的本地目录检索同属「搜索结果出现」语义（见 searchPopInIds 声明处的说明）。
                // 空串回填、游戏版本页本地过滤、本地全量目录加载都在上面提前 return，不到此处。
                // 先于 items/filteredResults 写入：确保与触发本次重渲染的那批写入同批完成，
                // 视图取值时集合已就位。
                searchPopInIds = Set(result.items.map { $0.id })
                debouncedSearchText = searchText
                activeSearchQuery = searchQuery
                items = result.items
                // 记录本次写回批次：供 handleItemsChanged 识别来源，避免再触发一轮请求
                itemsFromSearch = result.items
                currentOffset = result.items.count
                hasMore = result.totalHits > result.items.count
                filteredResults = result.items
                displayLimit = 120
            }
        }
    }
}
