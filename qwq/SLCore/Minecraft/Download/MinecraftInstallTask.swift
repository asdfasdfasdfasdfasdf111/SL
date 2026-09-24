//
//  MinecraftInstallTask.swift
//  SL启动器
//
//  原版 Minecraft 安装任务（从 InstallTask.swift 逐字搬移，逻辑与文案未变）：
//  启动任务、阶段状态映射（串行阶段与并行阶段合并展示）、失败清理与标题。
//

import Foundation
import Combine

// MARK: - Minecraft 安装任务定义
public class MinecraftInstallTask: InstallTask {
    public var manifest: ClientManifest?
    public var assetIndex: AssetIndex?
    public var name: String
    public var versionURL: URL { minecraftDirectory.versionsURL.appendingPathComponent(name) }
    public let minecraftVersion: MinecraftVersion
    public let minecraftDirectory: MinecraftDirectory
    /// 显式固定为 MainActor 隔离，避免 Swift 6.2 + Swift 5 模式 + Approachable Concurrency
    /// 将初始化器参数转换为存储 async 闭包时误生成 ABI（swiftlang/swift#86332）：
    /// 隐式 actor 参数会与业务参数错位，最终在 await 返回处跳到损坏地址并 EXC_BAD_ACCESS。
    public let startTask: @MainActor (MinecraftInstallTask) async throws -> Void
    public let architecture: Architecture
    @Published private var currentState: InstallState = .inprogress
    /// 安装失败原因（成功为 nil）。失败路径设置后调用 complete()，供 onComplete 回调区分成功/失败
    /// —— 旧实现失败不 complete()：下载详情页任务永远挂着不 dismiss、不弹失败提示（用户反馈的
    /// 「下载失败不会自动终止任务并报错」根因）。
    public private(set) var failureReason: String?
    /// 失败时是否删除版本目录（`versionURL`）。默认 true = 全新安装：失败即清理半成品目录。
    /// 资源补全 / 启动前修复路径（`MinecraftInstaller.createCompleteTask`）作用在**已存在**的实例上，
    /// 必须置为 false——否则一次网络失败就会把用户的实例目录（版本 jar 与 json）直接删掉。
    var removesVersionOnFailure: Bool = true
    
    public init(minecraftVersion: MinecraftVersion, minecraftDirectory: MinecraftDirectory, name: String, architecture: Architecture = .system, startTask: @escaping @MainActor (MinecraftInstallTask) async throws -> Void) {
        self.minecraftVersion = minecraftVersion
        self.minecraftDirectory = minecraftDirectory
        self.name = name
        self.startTask = startTask
        self.architecture = architecture
    }
    
    public override func start() {
        Task {
            // 记录安装前版本目录是否已存在：覆盖安装（目录早已存在）失败时，绝不能删整个目录，
            // 否则一次网络失败会把用户既有的实例（版本 jar 与 json）一起清掉；只有「本次新建」的
            // 目录才是安装过程自己产出的半成品，失败清理才安全。
            let versionDirExistedBefore = FileManager.default.fileExists(atPath: versionURL.path)
            do {
                try await startTask(self)
                complete()
            } catch {
                await PopupManager.shared.show(.init(.error, "无法安装 Minecraft", "\(error.localizedDescription)\n若要反馈此问题，你可以进入设置 > 其它 > 打开日志，将选中的文件发给别人。", [.ok]))
                err("无法安装 Minecraft: \(error.localizedDescription)")
                let shouldRemoveVersion = removesVersionOnFailure && !versionDirExistedBefore
                await MainActor.run {
                    currentState = .failed
                    failureReason = error.localizedDescription
                    // 失败也必须 complete()：触发 onComplete 回调 → 关闭下载详情页 + 弹失败提示。
                    // complete() 幂等（didComplete）+ 归属校验：失败回调迟到（晚于下一个下载的
                    // start()）时识别出全局任务组已被替换 → 拒绝清理，避免旧任务清掉新任务引用
                    // （跨任务交叉清理 UAF，崩溃 #4 根因）。旧实现这里只清全局不调 complete()，
                    // 导致详情页永远挂着、无失败回调。
                    self.complete()
                }
                // 递归删除较重，移出主线程；仅当该目录是本次安装新建（安装前不存在）才清理，
                // 避免一次网络失败连用户的既有实例一起删掉。
                if shouldRemoveVersion {
                    // ⚠️ 必须**值捕获**要删的 URL：`Task.detached` 不继承 actor 隔离，若在闭包里写
                    // `self.versionURL` 就是「从主 actor 之外访问主 actor 隔离属性」（Swift 6 下为错误，
                    // 当前为告警）；`URL` 本身是 Sendable，先在这里读出来再传给后台任务即可。
                    let versionURLToRemove = versionURL
                    Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: versionURLToRemove)
                    }
                }
            }
        }
    }
    
    public override func getInstallStates() -> [InstallStage : InstallState] {
        let allStages: [InstallStage] = [.clientJson, .clientIndex, .clientJar, .clientResources, .clientLibraries, .natives]
        var result: [InstallStage: InstallState] = [:]
        var foundCurrent = false
        for stage in allStages {
            // 并发阶段有独立状态，优先返回；多个阶段可同时为 inprogress
            if let parallel = stateForParallelStage(stage) {
                // 总任务失败时，还在「下载中」的并发阶段显示为失败（与串行语义一致）
                result[stage] = currentState == .failed && parallel == .inprogress ? .failed : parallel
            } else if foundCurrent {
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
