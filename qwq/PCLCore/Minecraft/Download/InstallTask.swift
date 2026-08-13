//
//  InstallTask.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/7.
//

import Foundation
import Combine

public class InstallTask: ObservableObject, Identifiable, Hashable, Equatable {
    @Published public var stage: InstallStage = .before
    @Published public var remainingFiles: Int = -1
    @Published public var totalFiles: Int = -1
    @Published public var currentStagePercentage: Double = 0
    
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
    
    public func start() { }
    public func getInstallStates() -> [InstallStage : InstallState] { [:] }
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
    
    public func getProgress() -> Double {
        Double(totalFiles - remainingFiles) / Double(totalFiles)
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
    
    public func completeOneFile() {
        DispatchQueue.main.async {
            self.remainingFiles -= 1
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

// MARK: - Minecraft 安装任务定义
public class MinecraftInstallTask: InstallTask {
    public var manifest: ClientManifest?
    public var assetIndex: AssetIndex?
    public var name: String
    public var versionURL: URL { minecraftDirectory.versionsURL.appending(path: name) }
    public let minecraftVersion: MinecraftVersion
    public let minecraftDirectory: MinecraftDirectory
    public let startTask: (MinecraftInstallTask) async throws -> Void
    public let architecture: Architecture
    @Published private var currentState: InstallState = .inprogress
    
    public init(minecraftVersion: MinecraftVersion, minecraftDirectory: MinecraftDirectory, name: String, architecture: Architecture = .system, startTask: @escaping (MinecraftInstallTask) async throws -> Void) {
        self.minecraftVersion = minecraftVersion
        self.minecraftDirectory = minecraftDirectory
        self.name = name
        self.startTask = startTask
        self.architecture = architecture
    }
    
    public override func start() {
        Task {
            do {
                try await startTask(self)
                complete()
            } catch {
                await PopupManager.shared.show(.init(.error, "无法安装 Minecraft", "\(error.localizedDescription)\n若要反馈此问题，你可以进入设置 > 其它 > 打开日志，将选中的文件发给别人。", [.ok]))
                err("无法安装 Minecraft: \(error.localizedDescription)")
                await MainActor.run {
                    currentState = .failed
                    // 归属校验（与 complete() 同一套）：失败回调也可能迟到（晚于下一个下载的
                    // start()），此时全局已是新任务组 → 绝不清空，避免旧任务清掉新任务引用
                    // （跨任务交叉清理 UAF，崩溃 #4 根因）
                    if DataManager.shared.inprogressInstallTasks?.tasks.values.contains(where: { $0 === self }) == true {
                        DataManager.shared.inprogressInstallTasks = nil
                    }
                    try? FileManager.default.removeItem(at: versionURL)
                }
            }
        }
    }
    
    public override func getInstallStates() -> [InstallStage : InstallState] {
        let allStages: [InstallStage] = [.clientJson, .clientIndex, .clientJar, .clientResources, .clientLibraries, .natives]
        var result: [InstallStage: InstallState] = [:]
        var foundCurrent = false
        for stage in allStages {
            if foundCurrent {
                result[stage] = .waiting
            } else if self.stage == stage {
                result[stage] = currentState
                foundCurrent = true
            } else {
                result[stage] = .finished
            }
        }
        return result
    }
    
    public override func getTitle() -> String {
        "\(minecraftVersion.displayName) 安装"
    }
}

// MARK: - Fabric 安装任务定义
public class FabricInstallTask: InstallTask {
    @Published private var state: InstallState
    private let loaderVersion: String
    
    init(loaderVersion: String) {
        self.state = .waiting
        self.loaderVersion = loaderVersion
    }
    
    public func install(_ task: MinecraftInstallTask) async {
        await MainActor.run {
            state = .inprogress
        }
        do {
            let manifestURL = task.versionURL.appending(path: "\(task.name).json")
            try await FabricInstaller.installFabric(version: task.minecraftVersion, minecraftDirectory: task.minecraftDirectory, runningDirectory: task.versionURL, self.loaderVersion)
            task.manifest = try ClientManifest.parse(url: manifestURL, minecraftDirectory: task.minecraftDirectory)
        } catch {
            await PopupManager.shared.show(.init(.error, "无法安装 Fabric", "\(error.localizedDescription)\n若要反馈此问题，你可以进入设置 > 其它 > 打开日志，将选中的文件发给别人。", [.ok]))
            err("无法安装 Fabric: \(error.localizedDescription)")
        }
        await MainActor.run {
            state = .finished
        }
    }
    
    public override func getInstallStates() -> [InstallStage : InstallState] { [.installFabric : state] }
    
    public override func getTitle() -> String {
        "Fabric \(loaderVersion) 安装"
    }
}

public class ForgeInstallTask: InstallTask {
    @Published private var state: InstallState
    private let forgeVersion: String
    
    init(forgeVersion: String) {
        self.state = .waiting
        self.forgeVersion = forgeVersion
    }
    
    public func install(_ task: MinecraftInstallTask) async {
        await MainActor.run {
            state = .inprogress
        }
        do {
            let installer = ForgeInstaller(task.minecraftDirectory, task.versionURL, task.manifest!) { progress in
                self.currentStagePercentage = progress
            }
            try await installer.install(minecraftVersion: task.minecraftVersion, forgeVersion: forgeVersion)
            log("Forge 安装完成")
        } catch {
            await PopupManager.shared.show(.init(.error, "无法安装 Forge", "\(error.localizedDescription)\n若要反馈此问题，你可以进入设置 > 其它 > 打开日志，将选中的文件发给别人。", [.ok]))
            err("无法安装 Forge: \(error.localizedDescription)")
        }
        await MainActor.run {
            state = .finished
        }
    }
    
    public override func getInstallStates() -> [InstallStage : InstallState] { [.installForge : state] }
    public override func getTitle() -> String { "Forge \(forgeVersion) 安装" }
}

public class NeoforgeInstallTask: InstallTask {
    @Published private var state: InstallState
    private let neoforgeVersion: String
    
    init(neoforgeVersion: String) {
        self.state = .waiting
        self.neoforgeVersion = neoforgeVersion
    }
    
    public func install(_ task: MinecraftInstallTask) async {
        await MainActor.run {
            state = .inprogress
        }
        do {
            let installer = NeoforgeInstaller(task.minecraftDirectory, task.versionURL, task.manifest!) { progress in
                self.currentStagePercentage = progress
            }
            try await installer.install(minecraftVersion: task.minecraftVersion, forgeVersion: neoforgeVersion)
            log("NeoForge 安装完成")
        } catch {
            await PopupManager.shared.show(.init(.error, "无法安装 NeoForge", "\(error.localizedDescription)\n若要反馈此问题，你可以进入设置 > 其它 > 打开日志，将选中的文件发给别人。", [.ok]))
            err("无法安装 NeoForge: \(error.localizedDescription)")
        }
        await MainActor.run {
            state = .finished
        }
    }
    
    public override func getInstallStates() -> [InstallStage : InstallState] { [.installNeoforge : state] }
    public override func getTitle() -> String { "NeoForge \(neoforgeVersion) 安装" }
}

public class CustomFileDownloadTask: InstallTask {
    private let url: URL
    private let destination: URL
    @Published private var progress: Double = 0
    
    init(url: URL, destination: URL) {
        self.url = url
        self.destination = destination
        super.init()
        self.totalFiles = 1
        self.remainingFiles = 1
    }
    
    public override func getTitle() -> String {
        "自定义下载：\(destination.lastPathComponent)"
    }
    
    public override func getProgress() -> Double {
        currentStagePercentage
    }
    
    public override func start() {
        Task {
            do {
                try await SingleFileDownloader.download(url: url, destination: destination) { progress in
                    self.currentStagePercentage = progress
                }
            } catch {
                hint("\(destination.lastPathComponent) 下载失败: \(error.localizedDescription.replacingOccurrences(of: "\n", with: ""))", .critical)
                complete()
                return
            }
            hint("\(destination.lastPathComponent) 下载完成！", .finish)
            complete()
        }
    }
    
    public override func getInstallStates() -> [InstallStage : InstallState] {
        [.customFile: .inprogress]
    }
}

// MARK: - 安装进度定义
public enum InstallStage: Int {
    case before = 0
    case clientJson = 1
    case clientIndex = 2
    case clientJar = 3
    case clientResources = 4
    case clientLibraries = 5
    case natives = 6
    case end = 7
    
    case installFabric = 1000
    case installForge = 1001
    case installNeoforge = 1002
    
    case customFile = 2000
    case modDownload = 2001
    
    case resources = 3000
    
    case javaDownload = 4000
    case javaInstall = 4001
    
    public func getDisplayName() -> String {
        switch self {
        case .before: "未启动"
        case .clientJson: "下载原版 json 文件"
        case .clientJar: "下载原版 jar 文件"
        case .installFabric: "安装 Fabric"
        case .installForge: "安装 Forge"
        case .installNeoforge: "安装 NeoForge"
        case .clientIndex: "下载资源索引文件"
        case .clientResources: "下载散列资源文件"
        case .clientLibraries: "下载依赖项文件"
        case .natives: "下载本地库文件"
        case .customFile: "下载自定义文件"
        case .modDownload: "下载文件"
        case .resources: "下载资源"
        case .end: "结束"
        case .javaDownload: "下载 Java"
        case .javaInstall: "安装 Java"
        }
    }
}

// MARK: - 安装进度状态定义
public enum InstallState {
    case waiting, inprogress, finished, failed
    public func getImageName() -> String {
        switch self {
        case .waiting:
            "InstallWaiting"
        case .finished:
            "InstallFinished"
        default:
            "Missingno"
        }
    }
}
