//
//  ProgressiveDownloader.swift
//  PCL.Mac
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
    
    public func start() async throws {
        guard !items.isEmpty else { return }
        
        // 构造多源分片下载任务：主源 + 官方源 fallback（PCL2 NetFile.Sources 多源失败切换）
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
            return PCLNetFile(urls: urls, destination: item.destination, checker: checker, replaceMethod: replaceMethod)
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
