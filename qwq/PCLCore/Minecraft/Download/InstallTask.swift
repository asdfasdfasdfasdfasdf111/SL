//
//  InstallTask.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/7.
//
//  安装任务基类与任务组。本文件只保留协调职责：
//  - InstallTask：阶段/进度状态、并行阶段账目、幂等 complete 与全局引用归属校验清理
//  - InstallTasks：任务组登记、objectWillChange 转发、批量进度聚合
//  其余具体任务与进度词汇按职责拆分在同目录，逻辑、常量与文案均与原实现逐字一致（仅物理搬移）：
//  - InstallProgress.swift         InstallStage / InstallState 阶段与状态定义
//  - MinecraftInstallTask.swift    原版安装任务（阶段状态映射与失败清理）
//  - LoaderInstallTasks.swift      Fabric / Forge / NeoForge 安装任务
//  - CustomFileDownloadTask.swift  自定义文件下载任务
//

import Foundation
import Combine

public class InstallTask: ObservableObject, Identifiable, Hashable, Equatable {
    @Published public var stage: InstallStage = .before
    @Published public var remainingFiles: Int = -1
    @Published public var totalFiles: Int = -1
    @Published public var currentStagePercentage: Double = 0
    /// 并发下载阶段的独立状态/进度。Minecraft 安装后半程会同时下载资源、依赖与 natives，
    /// 不能再用单一 stage/currentStagePercentage 互相覆盖。
    @Published private var parallelStageStates: [InstallStage: InstallState] = [:]
    @Published private var parallelStageProgress: [InstallStage: Double] = [:]
    
    public let id: UUID = UUID()
    public var callback: (() -> Void)? = nil
    
    /// 幂等完成标志：complete() 被调用多次时只真正清理一次。
    /// 根治「重复 complete → 重复清理 / 重复 dismiss / 重复 resume continuation」类 UAF 前兆。
    private var didComplete = false
    /// 所属任务组（weak 防循环引用；由 InstallTasks.addTask/init 时设置）。
    /// complete() 清全局 inprogressInstallTasks 前用它做归属校验：
    /// 只有「全局仍是自己所属那一组」才清理，否则说明新任务已接管，绝不能动全局引用
    /// —— 旧任务迟到回调清掉新任务引用 → 新任务失去强持有 → 下载中 UAF（崩溃 #4 根因）。
    internal weak var containerTasks: InstallTasks?
    
    public static func == (lhs: InstallTask, rhs: InstallTask) -> Bool {
        lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    /// 启动任务。基类为空实现：只有可独立启动的任务（MinecraftInstallTask /
    /// CustomFileDownloadTask / ModFileDownloadTask）覆写了本方法；
    /// FabricInstallTask / LoaderInstallTask 属于子任务，由 MinecraftInstaller 通过
    /// `install(_:)` 驱动，**不经过 start()**，故沿用空实现。
    /// 调用方若对子任务调用 start()，将不会有任何动作——请改用 install(_:)。
    public func start() { }
    /// 各阶段安装状态。基类返回空字典：子任务需覆写，否则下载详情页无进度可显示。
    public func getInstallStates() -> [InstallStage : InstallState] { [:] }
    /// 任务标题。基类返回空串：具体任务需覆写，否则下载详情页标题为空。
    public func getTitle() -> String { "" }
    public func onComplete(_ callback: @escaping () -> Void) {
        self.callback = callback
    }
    
    public func updateStage(_ stage: InstallStage) {
        debug("切换阶段: \(stage.getDisplayName())")
        DispatchQueue.main.async {
            self.stage = stage
            self.currentStagePercentage = 0
        }
    }
    
    /// 标记一个可并行阶段开始/结束，并维护各阶段独立进度。
    public func beginParallelStage(_ stage: InstallStage) async {
        await MainActor.run {
            parallelStageStates[stage] = .inprogress
            parallelStageProgress[stage] = 0
        }
    }

    public func updateParallelStage(_ stage: InstallStage, progress: Double) {
        let clamped = min(1, max(0, progress))
        DispatchQueue.main.async {
            self.parallelStageProgress[stage] = clamped
        }
    }

    public func finishParallelStage(_ stage: InstallStage) async {
        await MainActor.run {
            parallelStageProgress[stage] = 1
            parallelStageStates[stage] = .finished
        }
    }

    public func failParallelStage(_ stage: InstallStage) async {
        await MainActor.run {
            parallelStageStates[stage] = .failed
        }
    }

    public func stateForParallelStage(_ stage: InstallStage) -> InstallState? {
        parallelStageStates[stage]
    }

    public func progressForStage(_ stage: InstallStage) -> Double {
        parallelStageProgress[stage] ?? (self.stage == stage ? currentStagePercentage : 0)
    }

    /// 进度口径：`remainingFiles` 一律由 `completeOneFile()` **逐文件**递减——凡在 `totalFiles` 里
    /// 计过数的文件，其「已满足」或「已完成」都要调用一次（实际下载完成、预检命中已存在而跳过、
    /// 缓存命中 / 校验通过而不进下载列表的库与 natives 都算）。
    /// 进度 = (totalFiles − remainingFiles) / totalFiles，与「剩余待完成文件数」保持同一口径，
    /// 成功安装结束时 remainingFiles 自然归零（`completeOneFile` 的下限钳制保证不会为负）。
    /// 注意：`complete()` **不**清零 remainingFiles——旧注释称其清零，与实际实现不符，此处按实现修正。
    public func getProgress() -> Double {
        guard totalFiles > 0 else { return 0 }
        // 正常下载中保证 0 ≤ r ≤ total
        let remaining = min(totalFiles, max(0, remainingFiles))
        let p = Double(totalFiles - remaining) / Double(totalFiles)
        return min(1, max(0, p))
    }
    
    public func complete() {
        // 幂等：重复调用只保留第一次的效果（updateStage + 清理 + callback 只发一次）
        guard !didComplete else { return }
        didComplete = true
        log("下载任务结束")
        self.updateStage(.end)
        DispatchQueue.main.async {
            // 归属校验：仅当全局 inprogressInstallTasks 里仍包含本任务（== 未被新任务顶替）
            // 才清理全局引用。旧任务 A 的迟到回调晚于新任务 B 的 start() 到达时，
            // 全局已是 B 的任务组 → 含有的是 B 不是 A → A 一律不动 →
            // 彻底消除「旧任务清理误清新任务引用 → 新任务失去强持有 → 下载中 UAF」竞态。
            if DataManager.shared.inprogressInstallTasks?.tasks.values.contains(where: { $0 === self }) == true {
                DataManager.shared.inprogressInstallTasks = nil
                if case .installing(_) = DataManager.shared.router.getLast() {
                    DataManager.shared.router.removeLast()
                }
            }
            self.callback?()
        }
    }
    
    /// 计入 `totalFiles` 的每个文件完成时都应调用一次（实际下载完成、预检跳过、缓存命中 /
    /// 校验通过而不进下载列表的库与 natives 同样计数），与 `getProgress()` 的口径配套。
    public func completeOneFile() {
        DispatchQueue.main.async {
            // 下限保护：依赖数组枚举数可能与实际完成数略有出入，避免进度越界
            self.remainingFiles = max(0, self.remainingFiles - 1)
        }
    }
}

public class InstallTasks: ObservableObject, Identifiable, Hashable, Equatable {
    @Published public var tasks: [String : InstallTask]
    
    public let id: UUID = .init()
    public static func == (lhs: InstallTasks, rhs: InstallTasks) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(tasks)
    }
    
    public var totalFiles: Int {
        var totalFiles = 0
        tasks.values.forEach { totalFiles += $0.totalFiles }
        return totalFiles
    }
    
    public var remainingFiles: Int {
        var remainingFiles = 0
        tasks.values.forEach { remainingFiles += $0.remainingFiles }
        return remainingFiles
    }
    
    public func getProgress() -> Double {
        var progress: Double = 0
        for task in tasks.values {
            progress += task.getProgress()
        }
        return progress / Double(tasks.count)
    }
    
    public func getTasks() -> [InstallTask] {
        let order = ["minecraft", "fabric", "forge", "neoforge", "customFile"]
        return order.compactMap { tasks[$0] }
    }
    
    public func addTask(key: String, task: InstallTask) {
        tasks[key] = task
        task.containerTasks = self
        subscribeToTask(task)
    }
    
    init(_ tasks: [String : InstallTask]) {
        self.tasks = tasks
        tasks.values.forEach { $0.containerTasks = self }
        subscribeToTasks()
    }
    
    private var cancellables: [AnyCancellable] = []
    
    private func subscribeToTasks() {
        cancellables.forEach { $0.cancel() }
        cancellables = []
        for task in tasks.values {
            subscribeToTask(task)
        }
    }

    private func subscribeToTask(_ task: InstallTask) {
        let cancellable = task.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        cancellables.append(cancellable)
    }
    
    public static func single(_ task: InstallTask, key: String = "minecraft") -> InstallTasks { .init([key : task]) }
    
    public static func empty() -> InstallTasks { .init([:]) }
}
