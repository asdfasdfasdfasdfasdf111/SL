//
//  HomeInteractionStateTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//  1. 初始态：搜索词为空串、拖入高亮关闭——根视图首次渲染不得带着残留状态；
//  2. 两个字段均可写，且每次写入都发出 `objectWillChange`（否则拖拽高亮与搜索框不刷新）；
//  3. 实例隔离：该类型承载的是「根视图自身的即时交互」，生命周期与根视图一致，
//     不得成为跨视图共享的全局状态。两个实例之间不得互相影响——一旦有人把它改成
//     单例或加静态存储，本用例即失败。
//
//  被测：App/ViewModels/HomeInteractionState.swift
//

import XCTest
import Combine
@testable import qwq

@MainActor
final class HomeInteractionStateTests: XCTestCase {

    /// 初始态：搜索词为空、拖拽高亮关闭
    func testInitialState() async {
        let state = HomeInteractionState()

        XCTAssertEqual(state.searchText, "")
        XCTAssertFalse(state.isDropTargeted)
    }

    /// 搜索词可写（当前根视图未提供搜索入口，字段保留以维持下游接口不变）
    func testSearchTextIsMutable() async {
        let state = HomeInteractionState()

        state.searchText = "optifine"
        XCTAssertEqual(state.searchText, "optifine")

        state.searchText = ""
        XCTAssertEqual(state.searchText, "")
    }

    /// 拖入高亮开关可写（由 onDrop 的 isTargeted 绑定驱动）
    func testDropTargetedIsMutable() async {
        let state = HomeInteractionState()

        state.isDropTargeted = true
        XCTAssertTrue(state.isDropTargeted)

        state.isDropTargeted = false
        XCTAssertFalse(state.isDropTargeted)
    }

    /// 两个实例互不影响（根视图级状态，不是全局状态）
    func testInstancesDoNotShareState() async {
        let first = HomeInteractionState()
        let second = HomeInteractionState()

        first.searchText = "只写第一个"
        first.isDropTargeted = true

        XCTAssertEqual(second.searchText, "", "状态串到第二个实例说明被改成了共享存储")
        XCTAssertFalse(second.isDropTargeted)
    }

    /// 每个字段的变化都发出重绘信号
    func testEachFieldChangeEmitsObjectWillChange() async {
        let state = HomeInteractionState()
        var emissions = 0
        let cancellable = state.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        state.searchText = "a"
        XCTAssertEqual(emissions, 1, "搜索词写入必须触发重绘信号")

        state.isDropTargeted = true
        XCTAssertEqual(emissions, 2, "拖拽高亮写入必须触发重绘信号")
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. `.onDrop(isTargeted:)` 绑定、拖拽悬停回调与搜索框输入本身依赖 SwiftUI
//     视图生命周期与手势系统，无 UI 承载时不可验证。本文件只覆盖状态容器的
//     可变性、初始值与实例隔离。
//  2. `searchText` 目前恒为空串（根视图未提供搜索入口），其「转交给
//     CategoryContentView」的链路属视图组合行为，无断言入口。
