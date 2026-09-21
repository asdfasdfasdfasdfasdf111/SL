//
//  CustomFileDownloadTask.swift
//  PCL.Mac
//
//  自定义文件下载任务（从 InstallTask.swift 逐字搬移，逻辑与文案未变）：
//  经 DownloadEngine 提交单文件下载，后端仍为 NetManager。
//

import Foundation
import Combine

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
            // 迁移说明：由 `SingleFileDownloader`（内部 `NetManager`）切换为经 `DownloadEngine` 提交，
            // 后端仍是同一 `NetManager`。旧调用只传一个 URL 且未指定覆盖策略，故这里显式注入
            // 无备用源的顺序解析器（不凭空追加镜像源），覆盖策略沿用旧链路缺省值 `.skip`。
            let engine = NetDownloaderDownloadEngine(replaceMethod: .skip)
            do {
                let request = DownloadRequest(url: url, destinationURL: destination)
                let handle = try await engine.submit(request)
                for await state in engine.observe(taskID: handle.taskID) {
                    switch state {
                    case .downloading(let snapshot):
                        // 旧链路进度回调由 NetManager 派发到 @MainActor，这里保持同样的隔离；
                        // 进度口径同为 0…1 比例。
                        let fraction = snapshot.fraction
                        await MainActor.run { self.currentStagePercentage = fraction }
                    case .completed:
                        // 旧链路在成功路径末尾固定回调 progress(1.0)，此处保持终值一致。
                        await MainActor.run { self.currentStagePercentage = 1 }
                    case .failed(let error):
                        // 结构化错误会归一化文案，优先回放旧链路的原始描述。
                        let reason = engine.legacyFailureReason(taskID: handle.taskID)
                            ?? error.errorDescription
                            ?? "下载失败。"
                        throw MyLocalizedError(reason: reason)
                    case .cancelled:
                        throw CancellationError()
                    case .idle, .preparing, .verifying, .merging:
                        break
                    }
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
