//
//  FabricInstaller.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/8/15.
//

import Foundation
import ZIPFoundation

public class FabricInstaller {
    public static func installFabric(_ instance: MinecraftInstance, _ loaderVersion: String) async throws {
        try await installFabric(version: instance.version!, minecraftDirectory: instance.minecraftDirectory, runningDirectory: instance.runningDirectory, loaderVersion)
        
        instance.clientBrand = .fabric
        instance.saveConfig()
    }
    
    public static func installFabric(version: MinecraftVersion, minecraftDirectory: MinecraftDirectory, runningDirectory: URL, _ loaderVersion: String) async throws {
        let manifestURL = runningDirectory.appendingPathComponent("\(runningDirectory.lastPathComponent).json")
        // 若 inheritsFrom 对应的版本 JSON 不存在，复制
        let baseManifestURL = minecraftDirectory.versionsURL.appendingPathComponent(version.displayName).appendingPathComponent("\(version.displayName).json")
        if !FileManager.default.fileExists(atPath: baseManifestURL.path) {
            try? FileManager.default.createDirectory(at: baseManifestURL.parent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: manifestURL, to: baseManifestURL)
        }
        
        try await downloadProfileJSON(
            url: "https://meta.fabricmc.net/v2/versions/loader/\(version.displayName)/\(loaderVersion)/profile/json".url,
            destination: manifestURL
        )
    }

    // MARK: - 下载 loader profile JSON（经 DownloadEngine 提交，后端仍为 NetManager）

    /// 替代原 `SingleFileDownloader.download(url:destination:replaceMethod:)` 调用点。
    ///
    /// 行为等价要点：
    /// - 候选源固定为传入的单个 URL（旧调用只传一个 URL），故注入无备用源的顺序解析器，
    ///   不因 `fileDownloadSource == .both` 凭空追加镜像源；
    /// - 覆盖策略沿用旧调用的 `.replace`；
    /// - 无校验要求：旧链路 `checker == nil`，新链路在无期望值时返回空期望 `FileChecker`，
    ///   `.replace` 下两者都不产生跳过或校验失败分支；
    /// - 旧调用未传 `task` / `progress`，故无文件计数与进度回调需要对齐；
    /// - 失败抛出携带旧链路原始描述的错误，调用方取 `error.localizedDescription` 的文案不变。
    private static func downloadProfileJSON(url: URL, destination: URL) async throws {
        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver())
        let request = DownloadRequest(url: url, destinationURL: destination)
        let handle = try await engine.submit(request, replaceMethod: .replace)

        for await state in engine.observe(taskID: handle.taskID) {
            switch state {
            case .completed:
                return
            case .failed(let error):
                // 结构化错误会归一化文案，优先回放旧链路的原始描述。
                let reason = engine.legacyFailureReason(taskID: handle.taskID)
                    ?? error.errorDescription
                    ?? "下载失败。"
                throw MyLocalizedError(reason: reason)
            case .cancelled:
                throw CancellationError()
            case .idle, .preparing, .downloading, .verifying, .merging:
                break
            }
        }
    }
}
