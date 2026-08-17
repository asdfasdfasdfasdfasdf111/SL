//
//  ModFileDownloadTask.swift
//  下载详情页后端任务：照抄 PCL.Mac CustomFileDownloadTask 骨架，
//  单文件下载（模组/光影/资源包/整合包安装包），进度实时写入 currentStagePercentage，
//  状态 waiting → inprogress → finished，供 DownloadDetailView 逐阶段渲染。
//

import Foundation
import Combine

/// 单文件下载任务（对标 PCL.Mac CustomFileDownloadTask）
public class ModFileDownloadTask: InstallTask {
    private let url: URL
    private let destination: URL
    private let fileTitle: String

    @Published private var state: InstallState = .waiting
    /// 下载失败原因（成功为 nil），供完成回调区分成功/失败
    @Published private(set) var failureReason: String?

    public init(url: URL, destination: URL, title: String? = nil) {
        self.url = url
        self.destination = destination
        self.fileTitle = title ?? destination.lastPathComponent
        super.init()
        self.totalFiles = 1
        self.remainingFiles = 1
        self.updateStage(.modDownload)
    }

    public override func getTitle() -> String {
        fileTitle
    }

    public override func getProgress() -> Double {
        currentStagePercentage
    }

    public override func start() {
        Task { @MainActor in
            self.state = .inprogress
        }
        Task {
            do {
                try await SingleFileDownloader.download(
                    task: self,
                    url: url,
                    destination: destination,
                    replaceMethod: .replace
                ) { progress in
                    self.currentStagePercentage = progress
                }
                await MainActor.run {
                    self.state = .finished
                    self.completeOneFile()
                    self.complete()
                }
            } catch {
                await MainActor.run {
                    self.state = .failed
                    self.failureReason = error.localizedDescription
                    self.complete()
                }
            }
        }
    }

    public override func getInstallStates() -> [InstallStage: InstallState] {
        [.modDownload: state]
    }
}
