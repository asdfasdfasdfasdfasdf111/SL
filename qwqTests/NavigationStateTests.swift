//
//  NavigationStateTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//  1. 分类选中 ↔ 画布下标的换算：`selectedIndex` 必须跟随 `selectedCategory`，
//     未知分类必须回落到 0（不得越界崩溃）；
//  2. 拖拽换页的阈值判定：位移未超过「画布宽度 × 25%」不得换页（严格小于/大于），
//     首尾边界不得越界，横向为主的判定 `isHorizontalDrag` 不得把纵向滚动识别成换页；
//  3. 手势常量被冻结：最小拖拽距离 20 点、换页阈值比例 0.25，改动即改变画布手感；
//  4. 下载详情页状态归口：`isShowingDownloadDetail` / 圆按钮系列属性必须逐项代理
//     `DownloadDetailManager`，且其变化要透传到本对象的 `objectWillChange`
//     （否则订阅根视图的视图不会重绘）；
//  5. `handleSelectedCategoryChange` 的条件收起：详情页展开且画布未处于拖拽位移时收起，
//     拖拽中不得收起。
//
//  被测：App/ViewModels/NavigationState.swift
//

import XCTest
import Combine
@testable import qwq

@MainActor
final class NavigationStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DownloadDetailManager.shared.dismiss()
    }

    override func tearDown() {
        DownloadDetailManager.shared.dismiss()
        super.tearDown()
    }

    // MARK: - 分类与下标

    /// categories 与 Category.all 同序同内容，初始选中首个分类
    func testCategoriesMirrorCategoryAllAndSelectFirst() async {
        let state = NavigationState()

        XCTAssertEqual(state.categories.count, Category.all.count)
        XCTAssertEqual(state.categories.map(\.name), Category.all.map(\.name))
        XCTAssertEqual(state.selectedCategory.name, Category.all[0].name)
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertEqual(state.dragOffset, 0)
    }

    /// selectedIndex 跟随 selectedCategory
    func testSelectedIndexFollowsSelectedCategory() async {
        let state = NavigationState()

        state.selectedCategory = state.categories[3]
        XCTAssertEqual(state.selectedIndex, 3)

        state.selectedCategory = state.categories[state.categories.count - 1]
        XCTAssertEqual(state.selectedIndex, state.categories.count - 1)
    }

    /// 不在 categories 中的分类回落到下标 0，不得越界
    func testUnknownCategoryFallsBackToFirstIndex() async {
        let state = NavigationState()
        state.selectedCategory = state.categories[2]

        state.selectedCategory = Category(name: "不存在的分类", systemImage: "questionmark", filter: nil)

        XCTAssertEqual(state.selectedIndex, 0)
    }

    // MARK: - 手势常量与方向判定

    /// 手势常量被冻结（改动等同于改动画与手势行为）
    func testCanvasGestureConstantsAreFrozen() async {
        XCTAssertEqual(NavigationState.canvasDragMinimumDistance, 20)
        XCTAssertEqual(NavigationState.canvasFlipThresholdRatio, 0.25)
    }

    /// 横向位移为主才触发画布换页
    func testIsHorizontalDrag() async {
        XCTAssertTrue(NavigationState.isHorizontalDrag(CGSize(width: 30, height: 10)))
        XCTAssertTrue(NavigationState.isHorizontalDrag(CGSize(width: -30, height: 10)))
        XCTAssertTrue(NavigationState.isHorizontalDrag(CGSize(width: 12, height: -5)))

        XCTAssertFalse(NavigationState.isHorizontalDrag(CGSize(width: 10, height: 30)),
                       "纵向为主时不得由画布消费位移，应交由页面内滚动")
        XCTAssertFalse(NavigationState.isHorizontalDrag(CGSize(width: 20, height: -20)))
        XCTAssertFalse(NavigationState.isHorizontalDrag(CGSize(width: 0, height: 0)))
    }

    // MARK: - 拖拽换页目标下标

    /// 左移超过阈值 → 下一页（画布宽 400，阈值 100）
    func testDragLeftBeyondThresholdMovesToNextPage() async {
        let state = NavigationState()
        state.selectedCategory = state.categories[1]

        XCTAssertEqual(state.canvasTargetIndex(translationWidth: -101, canvasWidth: 400), 2)
    }

    /// 恰好等于阈值不换页（判定是严格小于/大于）
    func testDragExactlyAtThresholdDoesNotMove() async {
        let state = NavigationState()
        state.selectedCategory = state.categories[1]

        XCTAssertEqual(state.canvasTargetIndex(translationWidth: -100, canvasWidth: 400), 1)
        XCTAssertEqual(state.canvasTargetIndex(translationWidth: 100, canvasWidth: 400), 1)
        XCTAssertEqual(state.canvasTargetIndex(translationWidth: -99, canvasWidth: 400), 1)
        XCTAssertEqual(state.canvasTargetIndex(translationWidth: 99, canvasWidth: 400), 1)
    }

    /// 右移超过阈值 → 上一页
    func testDragRightBeyondThresholdMovesToPreviousPage() async {
        let state = NavigationState()
        state.selectedCategory = state.categories[2]

        XCTAssertEqual(state.canvasTargetIndex(translationWidth: 101, canvasWidth: 400), 1)
    }

    /// 首尾边界不得越界
    func testDragAtBoundaryStaysOnCurrentPage() async {
        let state = NavigationState()

        // 已在首页，再怎么右移也不换页
        state.selectedCategory = state.categories[0]
        XCTAssertEqual(state.canvasTargetIndex(translationWidth: 500, canvasWidth: 400), 0)

        // 已在末页，再怎么左移也不换页
        let last = state.categories.count - 1
        state.selectedCategory = state.categories[last]
        XCTAssertEqual(state.canvasTargetIndex(translationWidth: -500, canvasWidth: 400), last)
    }

    /// 画布宽度为 0（布局尚未完成）时阈值为 0：无位移不换页；
    /// 一旦有位移即视为越过阈值——这是当前实现的边界行为，此断言用于锁定它，避免误改。
    func testZeroWidthCanvasThresholdBehaviour() async {
        let state = NavigationState()
        state.selectedCategory = state.categories[1]

        XCTAssertEqual(state.canvasTargetIndex(translationWidth: 0, canvasWidth: 0), 1)
        XCTAssertEqual(state.canvasTargetIndex(translationWidth: -1, canvasWidth: 0), 2)
    }

    // MARK: - 下载详情页代理

    /// 详情页开关与圆按钮系列属性逐项代理 DownloadDetailManager
    func testDownloadDetailProxiesMirrorManager() async {
        let state = NavigationState()
        let manager = DownloadDetailManager.shared

        XCTAssertEqual(state.isShowingDownloadDetail, manager.isPresented)
        XCTAssertEqual(state.isDownloadCircleVisible, manager.showCircleButton)
        XCTAssertEqual(state.downloadCircleScale, manager.circleScale)
        XCTAssertEqual(state.downloadCircleOpacity, manager.circleOpacity)
    }

    /// toggleDownloadDetail 真正翻转详情页展示状态（状态源在 DownloadDetailManager）
    func testToggleDownloadDetailFlipsPresentation() async {
        let state = NavigationState()

        state.toggleDownloadDetail()
        XCTAssertTrue(state.isShowingDownloadDetail)
        XCTAssertTrue(DownloadDetailManager.shared.isPresented)

        state.toggleDownloadDetail()
        XCTAssertFalse(state.isShowingDownloadDetail)
    }

    /// DownloadDetailManager 的变化必须透传到 NavigationState 的 objectWillChange
    func testDownloadDetailChangesAreForwardedToObservers() async {
        let state = NavigationState()
        var emissions = 0
        let cancellable = state.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        DownloadDetailManager.shared.toggle()

        XCTAssertEqual(emissions, 1,
                       "详情页状态变化未透传时，订阅 NavigationState 的视图不重绘")
    }

    // MARK: - 切换分类时收起详情页

    /// 详情页展开且画布不在拖拽位移中 → 切换分类时收起
    func testHandleSelectedCategoryChangeCollapsesDetailWhenIdle() async {
        let state = NavigationState()
        state.toggleDownloadDetail()
        XCTAssertTrue(state.isShowingDownloadDetail)

        state.dragOffset = 0
        state.handleSelectedCategoryChange()

        XCTAssertFalse(state.isShowingDownloadDetail)
    }

    /// 画布处于拖拽位移中（dragOffset != 0）时不得收起详情页
    func testHandleSelectedCategoryChangeKeepsDetailDuringDrag() async {
        let state = NavigationState()
        state.dragOffset = 60
        state.toggleDownloadDetail()

        state.handleSelectedCategoryChange()
        XCTAssertTrue(state.isShowingDownloadDetail,
                      "拖拽位移未归零时收起详情页会打断画布动画")

        state.dragOffset = 0
        state.handleSelectedCategoryChange()
        XCTAssertFalse(state.isShowingDownloadDetail)
    }

    /// 详情页本就未展示时，切换分类不得产生额外开关动作
    func testHandleSelectedCategoryChangeIsNoOpWhenDetailHidden() async {
        let state = NavigationState()
        XCTAssertFalse(state.isShowingDownloadDetail)

        state.dragOffset = 0
        state.handleSelectedCategoryChange()
        XCTAssertFalse(state.isShowingDownloadDetail)

        state.dragOffset = 120
        state.handleSelectedCategoryChange()
        XCTAssertFalse(state.isShowingDownloadDetail)
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. 画布换页动画手感（`canvasSpring` 的 response / dampingFraction / blendDuration）
//     无法断言：`Animation` 不提供可读参数，且实际手感依赖 SwiftUI 运行时插值。
//     本文件只锁定决定手感的两个数值常量。
//  2. 拖拽手势本身（`DragGesture` 的 minimumDistance 生效、松手后的位移归零）
//     依赖 SwiftUI 手势识别与视图生命周期，无 UI 承载时不可验证。
