//
//  ProgressiveDownloader.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/8/24.
//

import Foundation

public struct DownloadItem {
    public let url: URL
    public let destination: URL
    public let sha1: String?
    
    fileprivate var fallbackURL: URL? {
        fallbackURLProvider?()
    }
    private var fallbackURLProvider: (() -> URL)?
    
    public init(_ downloadSource: DownloadSource, _ urlProvider: @escaping (DownloadSource) -> URL, destination: URL, sha1: String? = nil) {
        self.url = urlProvider(downloadSource)
        // 备用源 = 与主源互补的源（官方↔镜像），而不是旧实现硬编码官方源：
        // 旧实现主源=镜像时 fallback 仍=官方 → 镜像失败切官方，官方被墙再次失败 → 无可用源报错，
        // 且「官方失败 → 切镜像」的路径永远不存在。现在任意方向失败都会切到另一个源。
        // 但仅「自动切换（both）」模式提供 fallback；手动单源（仅官方/仅镜像）时 fallback 为 nil，
        // 主源失败直接报错——用户明确限定源时不做悄悄跨源兜底（与 DownloadSourceManager 一致）。
        self.fallbackURLProvider = AppSettings.shared.fileDownloadSource == .both
            ? { urlProvider(DownloadSourceManager.shared.alternateSource(of: downloadSource)) }
            : nil
        self.destination = destination
        self.sha1 = sha1
    }
    
    public init(_ url: URL, _ destination: URL, sha1: String? = nil) {
        self.url = url
        self.destination = destination
        self.sha1 = sha1
    }
}

public class MultiFileDownloader {
    private let task: InstallTask?
    private let items: [DownloadItem]
    private let concurrentLimit: Int
    private let replaceMethod: ReplaceMethod
    private let progress: ((Double, Int) -> Void)?
    private let stage: InstallStage?
    private let total: Int
    private var totalProgress: Double = 0
    private var finishedCount: Int = 0
    
    public convenience init(
        task: InstallTask? = nil,
        urls: [URL],
        destinations: [URL],
        concurrentLimit: Int = 16,
        replaceMethod: ReplaceMethod = .skip,
        stage: InstallStage? = nil,
        progress: ((Double, Int) -> Void)? = nil
    ) {
        self.init(
            task: task,
            items: (0..<urls.count).map { .init(urls[$0], destinations[$0]) },
            concurrentLimit: concurrentLimit,
            replaceMethod: replaceMethod,
            stage: stage,
            progress: progress
        )
    }
    
    public init(
        task: InstallTask? = nil,
        items: [DownloadItem],
        concurrentLimit: Int = 16,
        replaceMethod: ReplaceMethod = .skip,
        stage: InstallStage? = nil,
        progress: ((Double, Int) -> Void)? = nil
    ) {
        self.task = task
        self.items = items
        self.concurrentLimit = concurrentLimit
        self.replaceMethod = replaceMethod
        self.stage = stage
        self.progress = progress
        self.total = items.count
    }
    
    /// 批量下载入口。
    ///
    /// 迁移状态：整条批量链路**保持旧后端**（本方法内调 `NetManager.downloadAll`），不切换 `DownloadEngine`。
    /// 判据见 `Core/Download/Adapters/MIGRATION.md` 第六节「批量路径（#5 / #6 / #8）评估：本轮不切换」：
    /// 批进度的分子与分母都定义在引擎内部状态上，在 `DownloadEngine` 边界不可观察，无法逐字复刻。
    /// 不可等价的三个具体落点（行号为当前代码）：
    /// 1. 分母 =「首片响应头已到达（`fileSize > 0`）且尚未 `.done`」的文件大小之和，该集合由引擎内部事件决定；
    ///    调用方拿不到每文件真实字节数，`DownloadProgress` 在无 `expectedSize` 时以固定分母承载比例
    ///    （`NetProgressReporting.swift:24-41`）；
    /// 2. 预检跳过项在开始下载前即回调 `onFileCompleted`，且不进入 pending、不计入 `count`
    ///    （`NetDownloader.swift:104-116`、`:119`）；新链路「已存在而跳过」与「实际下载完成」都只产生
    ///    `.completed`，两者在边界上不可分辨，`count` 的计入集合无法对齐；
    /// 3. 批进度由 200ms 采样轮询产生，**非单调**且末次上报可能为 0（`NetDownloader.swift:125-136`）；
    ///    本方法在 `downloadAll` 返回后还会再回放一次可能陈旧的采样值（见本方法末尾）。
    /// 该数值序列在三个调用点都是用户可见量：`MinecraftInstallerDownloads.swift:208 / 241 / 279`
    /// 经 `InstallTask.updateParallelStage` 渲染、`LaunchFix.swift:79 / 100` 直接交给 `onProgress`、
    /// `ForgeInstaller.swift:153` 映射为 `setProgress(0.3 + progress * 0.3)`。因此聚合口径不得由
    /// 旧链路的「字节加权」退化为「Σ 各文件 fraction ÷ 文件数」的等权口径。
    /// 切换前置条件见同节「解除卡点的前置条件」：引擎侧提供批进度聚合，并新增可区分「跳过 / 完成」的标记。
    ///
    /// 另：`concurrentLimit` 为死参数（仅赋值、无读取），旧链路真实并发由 `NetManager.config.maxSlices = 16`
    /// 的全局分片池兜底，切换时无需复刻该参数。
    public func start() async throws {
        guard !items.isEmpty else { return }
        
        // 构造多源分片下载任务：主源 + 官方源 fallback（参照上游 PCL2 的 NetFile.Sources 多源失败切换）
        let files = items.map { item in
            var urls = [item.url]
            if let fallback = item.fallbackURL {
                urls.append(fallback)
            }
            let checker: FileChecker?
            if let sha1 = item.sha1 {
                checker = FileChecker(hash: sha1)
            } else {
                checker = nil
            }
            return SLNetFile(urls: urls, destination: item.destination, checker: checker, replaceMethod: replaceMethod)
        }
        
        try await NetManager.shared.downloadAll(files, overallProgress: { p, count in
            Task { @MainActor in
                self.totalProgress = p
                self.finishedCount = count
                self.progress?(p, count)
                if let stage = self.stage {
                    self.task?.updateParallelStage(stage, progress: p)
                } else {
                    self.task?.currentStagePercentage = p
                }
            }
        }, onFileCompleted: {
            self.task?.completeOneFile()
        })
        
        await MainActor.run {
            // downloadAll 的 p 已经是整个批次 0...1，不能再次除以文件总数。
            progress?(self.totalProgress, self.finishedCount)
            if let stage = self.stage {
                task?.updateParallelStage(stage, progress: self.totalProgress)
            } else {
                task?.currentStagePercentage = self.totalProgress
            }
        }
    }
}

public enum ReplaceMethod {
    case skip, replace, `throw`
}
