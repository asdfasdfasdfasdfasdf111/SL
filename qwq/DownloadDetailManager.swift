//
//  DownloadDetailManager.swift
//  下载详情页全局管理器：持有进行中的 InstallTasks 与展示状态，
//  供圆形按钮点击进入详情页时读取。对标 PCL.Mac DataManager.inprogressInstallTasks。
//

import Foundation
import Combine

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
    /// 详情页是否展示
    @Published var isPresented = false

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
    func start(_ tasks: InstallTasks) {
        self.tasks = tasks
        DataManager.shared.inprogressInstallTasks = tasks
        isPresented = true
    }

    /// 追加任务（当前未用，保留多任务扩展能力）
    func addTask(_ task: InstallTask, key: String) {
        tasks.addTask(key: key, task: task)
    }

    /// 关闭详情页并清空任务
    func dismiss() {
        isPresented = false
        tasks = .empty()
    }
}
