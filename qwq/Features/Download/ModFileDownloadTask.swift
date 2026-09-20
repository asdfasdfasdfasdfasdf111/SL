//
//  ModFileDownloadTask.swift
//  下载详情页后端任务：照抄 PCL.Mac CustomFileDownloadTask 骨架，
//  单文件下载（模组/光影/资源包/整合包安装包），进度实时写入 currentStagePercentage，
//  状态 waiting → inprogress → finished，供 DownloadDetailView 逐阶段渲染。
//
//  迁移说明：本任务已由直接调用 `SingleFileDownloader`（内部为 `NetManager`）切换为
//  经 `DownloadEngine`（`NetDownloaderDownloadEngine`）提交下载。适配器后端仍是同一
//  `NetManager`，因此下载行为、校验、覆盖与临时文件清理路径均未改变。
//

import Foundation
import Combine

/// 单文件下载任务（对标 PCL.Mac CustomFileDownloadTask）
public class ModFileDownloadTask: InstallTask {
    private let url: URL
    private let destination: URL
    private let fileTitle: String

    /// 下载引擎。经 `NetDownloaderDownloadEngine` 转发到旧 `NetManager`。
    /// 每次任务持有独立实例仅用于承载任务台账，全局分片额度等调度状态仍由 `NetManager.shared` 统一维护。
    private let engine = NetDownloaderDownloadEngine(replaceMethod: .replace)

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
        Task {
            await MainActor.run { self.state = .inprogress }
            do {
                // 与原实现一致：单 URL、固定 `.replace`（目标路径已由调用方解析为完整文件路径）。
                let request = DownloadRequest(url: url, destinationURL: destination)
                let handle = try await engine.submit(request, replaceMethod: .replace)

                // 消费状态流：`preparing` 无对应 UI 语义，忽略；进度与终态按下述方式映射。
                for await downloadState in engine.observe(taskID: handle.taskID) {
                    switch downloadState {
                    case .downloading(let progress):
                        // 旧链路进度为 0…1 比例；`DownloadProgress.fraction` 与之同口径。
                        let fraction = progress.fraction
                        await MainActor.run { self.currentStagePercentage = fraction }

                    case .completed:
                        await MainActor.run {
                            // 旧链路在下载成功后固定回调 progress(1.0)，此处保持终值一致。
                            self.currentStagePercentage = 1
                            self.state = .finished
                            self.completeOneFile()
                            self.complete()
                        }

                    case .failed(let error):
                        // 失败文案取旧链路原始描述（NetManager 抛出错误的 localizedDescription），
                        // 保证与改造前逐字一致；结构化错误仅在原始描述缺失时兜底。
                        let reason = engine.legacyFailureReason(taskID: handle.taskID)
                            ?? error.errorDescription
                            ?? "下载失败。"
                        await MainActor.run {
                            self.state = .failed
                            self.failureReason = reason
                            self.complete()
                        }

                    case .cancelled:
                        // 本任务对外未提供取消入口（改造前后一致），该分支仅在引擎自身被取消时到达。
                        let reason = engine.legacyFailureReason(taskID: handle.taskID) ?? "下载已取消。"
                        await MainActor.run {
                            self.state = .failed
                            self.failureReason = reason
                            self.complete()
                        }

                    case .idle, .preparing, .verifying, .merging:
                        break
                    }
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
