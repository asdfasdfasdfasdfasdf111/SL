//
//  NavigationState.swift
//  模块化收口：ContentView 的页面导航状态唯一持有者。
//  持有「当前分类」与「分类画布拖拽位移」；「下载详情页开关」转发给
//  DownloadDetailManager（详情页状态本就归下载模块所有，这里只做视图侧归口，不复制状态）。
//

import SwiftUI
import Combine

/// 根视图导航状态：分类选中、画布滑动位移、下载详情页开关。
///
/// 状态约定：所有可变状态只在主线程读写（分类点击、拖拽手势、圆按钮点击均在主线程）；
/// 标注 `@MainActor` 是因为详情页状态源 `DownloadDetailManager` 本身是 MainActor 隔离的。
@MainActor
final class NavigationState: ObservableObject {

    /// 全部分类页（数组顺序即画布横向顺序）
    let categories = Category.all

    /// 当前选中的分类
    @Published var selectedCategory: Category = Category.all.first!

    /// 分类画布拖拽中的实时位移（松手后归零）
    @Published var dragOffset: CGFloat = 0

    /// 当前分类在画布中的下标
    var selectedIndex: Int { categories.firstIndex(of: selectedCategory) ?? 0 }

    // MARK: - 下载详情页（状态源在 DownloadDetailManager）

    private let downloadDetail = DownloadDetailManager.shared
    /// DownloadDetailManager 的状态变化需透传到本对象，否则订阅本对象的视图不会重绘
    private var downloadDetailCancellable: AnyCancellable?

    /// 下载详情页是否展示
    var isShowingDownloadDetail: Bool { downloadDetail.isPresented }
    /// 全局圆形下载按钮是否可见
    var isDownloadCircleVisible: Bool { downloadDetail.showCircleButton }
    /// 圆按钮弹入动画状态
    var downloadCircleScale: CGFloat { downloadDetail.circleScale }
    var downloadCircleOpacity: Double { downloadDetail.circleOpacity }

    init() {
        downloadDetailCancellable = downloadDetail.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// 详情页开关（圆按钮点击：进详情页 / 回到刚才的页面）
    func toggleDownloadDetail() {
        downloadDetail.toggle()
    }

    /// 切换分类时收起下载详情。
    /// 仅当画布未处于拖拽位移中时才收起，保持既有行为不变。
    func handleSelectedCategoryChange() {
        if downloadDetail.isPresented && dragOffset == 0 {
            downloadDetail.toggle()
        }
    }
}
