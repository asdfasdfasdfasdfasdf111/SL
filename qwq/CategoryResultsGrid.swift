//
//  CategoryResultsGrid.swift
//  模块化拆分：从 GameViews.swift 拆出（原 resultsGrid 方法）
//  纯视图组件：分类页结果网格（LazyVGrid 卡片列表），分页切片（前 displayLimit 条）、
//  滚动锚点恢复、触底追加、卡片按需翻译均在此封装；数据与回调全部外部传入，
//  滚动锚点静态成员随组件迁移（仅用于返回列表时恢复位置，不触发重渲染）。
//

import SwiftUI

/// 分类页「结果卡片网格」：分页渲染 + 滚动锚点 + 触底追加 + 按需翻译
struct CategoryResultsGrid: View {
    let results: [DownloadedItem]
    let translatedSubtitles: [String: String]
    let cardWidth: CGFloat
    let cardPadding: CGFloat
    let columns: Int
    @Binding var displayLimit: Int
    let onOpen: (DownloadedItem) -> Void
    let onRequestTranslation: (DownloadedItem) async -> Void

    /// 滚动锚点：仅用于返回列表时恢复位置，无需触发视图重渲染，故不用 @State
    /// （快速滑动时每次 onAppear 写 @State 都会让整个列表 body 重算，是快速滑动卡顿的元凶之一）
    private nonisolated(unsafe) static var lastAnchorItemID: String? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: cardPadding), count: columns),
                    spacing: cardPadding
                ) {
                    // 分页切片：只对前 displayLimit 条做 diff，本地目录数万条时首帧仅 120 条，
                    // 避免整列 ForEach 全量 diff + LazyVGrid 布局卡死主线程
                    ForEach(results.prefix(displayLimit)) { item in
                        ContentCard(
                            title: item.name,
                            subtitle: translatedSubtitles[item.id] ?? item.subtitle,
                            cardWidth: cardWidth,
                            tags: item.tags,
                            action: { onOpen(item) }
                        )
                        .equatable()
                        .id(item.id)
                        .onAppear {
                            Self.lastAnchorItemID = item.id
                            // 本地目录分页：最后一张已展示卡片进入可视区时追加下一批（增量 120 条），
                            // 避免把数万条目录一次性注入 ForEach 做全量 diff；滚出再滚回会再次触发
                            // ⚠️ displayLimit 是 @Binding：onAppear 处于视图更新事务中，同步写会触发
                            // "Modifying state during view update" → 状态机错乱 → 悬垂指针崩溃，
                            // 必须延迟到渲染事务之外再写（分页晚一帧追加无感知）
                            if displayLimit < results.count {
                                let lastVisibleIndex = min(displayLimit, results.count) - 1
                                if results[lastVisibleIndex].id == item.id {
                                    let newLimit = min(displayLimit + 120, results.count)
                                    DispatchQueue.main.async {
                                        displayLimit = newLimit
                                    }
                                }
                            }
                        }
                        .task(id: item.id) { await onRequestTranslation(item) }
                    }
                }
                .padding(.horizontal, cardPadding)
                .padding(.bottom, cardPadding)
            }
            .coordinateSpace(name: "listScroll")
            .onAppear {
                if let id = Self.lastAnchorItemID {
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
            }
        }
    }
}
