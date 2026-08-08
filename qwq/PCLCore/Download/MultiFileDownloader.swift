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
        self.fallbackURLProvider = { urlProvider(OfficialDownloadSource.shared) }
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
    private let total: Int
    private var totalProgress: Double = 0
    private var finishedCount: Int = 0
    
    public convenience init(
        task: InstallTask? = nil,
        urls: [URL],
        destinations: [URL],
        concurrentLimit: Int = 16,
        replaceMethod: ReplaceMethod = .skip,
        progress: ((Double, Int) -> Void)? = nil
    ) {
        self.init(
            task: task,
            items: (0..<urls.count).map { .init(urls[$0], destinations[$0]) },
            concurrentLimit: concurrentLimit,
            replaceMethod: replaceMethod,
            progress: progress
        )
    }
    
    public init(
        task: InstallTask? = nil,
        items: [DownloadItem],
        concurrentLimit: Int = 16,
        replaceMethod: ReplaceMethod = .skip,
        progress: ((Double, Int) -> Void)? = nil
    ) {
        self.task = task
        self.items = items
        self.concurrentLimit = concurrentLimit
        self.replaceMethod = replaceMethod
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
                self.task?.currentStagePercentage = p
            }
        }, onFileCompleted: {
            self.task?.completeOneFile()
        })
        
        await MainActor.run {
            progress?(self.totalProgress / Double(self.total), self.finishedCount)
            task?.currentStagePercentage = self.totalProgress / Double(self.total)
        }
    }
}

public enum ReplaceMethod {
    case skip, replace, `throw`
}
