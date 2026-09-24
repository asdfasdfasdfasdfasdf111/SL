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

    // MARK: - 分类画布手势参数

    // 以下取值与抽取前逐字一致（response 0.6 / dampingFraction 0.65 / blendDuration 0.15、
    // 最小拖拽 20 点、换页阈值占画布宽度 25%）。这些参数直接决定画布手感，
    // 归口在此仅为消除重复字面量，任何改动都等同于修改动画与手势行为。

    /// 分类画布位移动画：点击导航换页与拖拽换页共用同一曲线
    static let canvasSpring = Animation.spring(response: 0.6, dampingFraction: 0.65, blendDuration: 0.15)

    /// 画布拖拽的手势识别最小位移
    static let canvasDragMinimumDistance: CGFloat = 20

    /// 拖拽换页的位移阈值比例（相对画布宽度）
    static let canvasFlipThresholdRatio: CGFloat = 0.25

    /// 位移是否以横向为主。纵向为主时不触发画布位移，交由页面内滚动消费。
    static func isHorizontalDrag(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }

    /// 画布拖拽松手后的目标分类下标。
    /// 未超过阈值、或已处在画布首尾边界时返回当前下标（调用方仍按原逻辑执行赋值，不做提前返回）。
    func canvasTargetIndex(translationWidth: CGFloat, canvasWidth: CGFloat) -> Int {
        let threshold = canvasWidth * Self.canvasFlipThresholdRatio
        if translationWidth < -threshold && selectedIndex < categories.count - 1 {
            return selectedIndex + 1
        }
        if translationWidth > threshold && selectedIndex > 0 {
            return selectedIndex - 1
        }
        return selectedIndex
    }

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
    /// 原 `dragOffset == 0` 守卫已移除：本方法仅由 `onChange(of: selectedCategory)` 触发，
    /// 而 selectedCategory 的两种变更来源在触发时 dragOffset 都已是 0——点击导航本就无位移；
    /// 拖拽换页在 `withAnimation` 块内与 `dragOffset = 0` 同批提交，onChange 处理时位移已归零。
    /// 故该守卫恒真，属死条件，移除不改变任何行为。
    func handleSelectedCategoryChange() {
        if downloadDetail.isPresented {
            downloadDetail.toggle()
        }
    }
}
