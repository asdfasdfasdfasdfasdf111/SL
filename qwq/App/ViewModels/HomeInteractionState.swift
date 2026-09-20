//
//  HomeInteractionState.swift
//  模块化收口：ContentView 根视图的轻量交互状态（分类内容区搜索词、文件拖入高亮）。
//
//  与 NavigationState 的分工：NavigationState 承载「页面级」状态（分类选中、画布位移、
//  详情页开关），会被下载详情等领域间接依赖；本类型只承载「根视图自身的即时交互」，
//  不涉及页面切换、不落盘、不跨领域共享，生命周期与根视图一致。
//
//  状态约定：两者均在主线程读写（搜索框输入、拖拽悬停回调、拖拽落点判定）。
//

import Foundation
import Combine

/// 根视图交互状态。
@MainActor
final class HomeInteractionState: ObservableObject {

    /// 分类内容区搜索词（转交给 CategoryContentView）。
    /// 说明：该值目前恒为空串——根视图未提供搜索入口，真正的搜索状态由
    /// GameViews 内的分类视图自行持有；此处保留字段以维持原有数据流与下游接口不变。
    @Published var searchText = ""

    /// 文件拖入窗口期间的整窗高亮开关（由 onDrop 的 isTargeted 绑定驱动）。
    @Published var isDropTargeted = false
}
