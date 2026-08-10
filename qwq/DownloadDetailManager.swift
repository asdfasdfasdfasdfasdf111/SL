//
//  DownloadDetailManager.swift
//  下载详情页全局管理器：对标 PCL.Mac AppRouter + DataManager.inprogressInstallTasks。
//  持有进行中的 InstallTasks 与「详情页是否展示」「圆按钮是否可见」两个全局状态，
//  详情页由 ContentView 顶层渲染为独立页面（非线性动画整页切换），
//  圆按钮由 ContentView 顶层渲染为全局 overlay（任何页面可点，toggle 进/出详情页）。
//

import Foundation
import Combine
import SwiftUI // withAnimation（页面/圆按钮非线性动画）

@MainActor
final class DownloadDetailManager: ObservableObject {
    static let shared = DownloadDetailManager()

    /// 进行中的下载任务集合（一个下载一个任务）
    @Published var tasks: InstallTasks = .empty() {
        didSet {
            // 任务内部进度变化（InstallTasks 会转发子任务 objectWillChange）→ 转发给本 manager，
            // 否则 DownloadDetailView 只观察 manager 收不到实时进度刷新
            taskCancellable = tasks.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
    /// 详情页是否展示（ContentView 顶层独立页面，对标 PCL.Mac router 的 installing 路由）
    @Published var isPresented = false
    /// 圆形下载按钮是否可见（下载开始后显示，任务结束隐藏；全局可见可点）
    @Published var showCircleButton = false
    /// 圆按钮弹入动画状态（由 start 触发，ContentView 顶层渲染）
    @Published var circleScale: CGFloat = 0.01
    @Published var circleOpacity: Double = 0

    private var taskCancellable: AnyCancellable?

    private init() {}

    /// 开始一个新下载任务并打开详情页
    /// 注意 key 必须在 InstallTasks.getTasks() 的固定顺序表内（minecraft/fabric/forge/neoforge/customFile），
    /// 否则 getTasks() 取不到任务（order 里没有的 key 会被过滤掉）
    func start(_ task: InstallTask, key: String = "customFile") {
        start(InstallTasks.single(task, key: key))
    }

    /// 开始一组下载任务（如游戏版本安装：minecraft + fabric/forge/neoforge）并打开详情页
    /// 同时同步到 DataManager.inprogressInstallTasks——MinecraftInstaller.createTask 内部靠它
    /// 查找加载器任务（tasks["fabric"/"forge"/"neoforge"]）来串联加载器安装
    /// 详情页跳入带非线性动画（interpolatingSpring 回弹，对标 PCL.Mac 页面切换手感），
    /// 在 manager 内部包裹，任何调用方（含后台回调）都能获得动画，不依赖调用方 withAnimation
    func start(_ tasks: InstallTasks) {
        self.tasks = tasks
        DataManager.shared.inprogressInstallTasks = tasks
        showCircleButton = true
        withAnimation(.interpolatingSpring(stiffness: 170, damping: 14, initialVelocity: 6)) {
            isPresented = true
        }
    }

    /// 追加任务（当前未用，保留多任务扩展能力）
    func addTask(_ task: InstallTask, key: String) {
        tasks.addTask(key: key, task: task)
    }

    /// 关闭详情页并清空任务（下载完成 / 失败后调用）
    /// 关闭带非线性动画，与打开对称；后台回调也走这里，动画自动在主线程播放
    func dismiss() {
        withAnimation(.interpolatingSpring(stiffness: 190, damping: 16)) {
            isPresented = false
        }
        tasks = .empty()
        showCircleButton = false
    }

    /// 详情页开关（圆按钮点击触发：进详情页 / 回到刚才的页面，无返回键）
    /// 与 ContentView 按钮点击时的 withAnimation 保持同一弹簧曲线，保证动画可播
    func toggle() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isPresented.toggle()
        }
    }
}
