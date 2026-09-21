//
//  MinecraftLauncherDownload.swift
//  PCL.Mac
//
//  启动器自带资源的下载入口（从 MinecraftLauncher.swift 逐字搬移，逻辑与文案未变）：
//  - downloadAuthlibInjector：authlib-injector 下载与 SHA256 校验
//  - downloadSingleFile：单文件下载（经 DownloadEngine 提交，后端仍为 NetManager）
//
//  downloadSingleFile 保持 private static：仅本文件的 downloadAuthlibInjector 调用。
//

import Foundation

extension MinecraftLauncher {
    public static func downloadAuthlibInjector() async throws {
        if FileManager.default.fileExists(atPath: SharedConstants.shared.authlibInjectorURL.path) { return }
        let json = try await Requests.get("https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/latest.json").getJSONOrThrow()
        guard let downloadURL = json["download_url"].url else {
            throw MyLocalizedError(reason: "无效的 authlib-injector 下载 URL")
        }
        try await downloadSingleFile(from: downloadURL, to: SharedConstants.shared.authlibInjectorURL)

        // 下载后校验 SHA256（BMCLAPI latest.json 的 checksums.sha256），防篡改/损坏：
        // 校验失败说明文件被中间人替换或下载不完整，删除并报错，绝不静默放行注入游戏进程
        if let sha256 = json["checksums"]["sha256"].string, !sha256.isEmpty,
           let failReason = FileChecker(hash: sha256).check(SharedConstants.shared.authlibInjectorURL) {
            try? FileManager.default.removeItem(at: SharedConstants.shared.authlibInjectorURL)
            throw MyLocalizedError(reason: "authlib-injector 哈希校验失败：\(failReason)")
        }
        log("authlib-injector 下载完成")
    }

    // MARK: - 单文件下载（经 DownloadEngine 提交，后端仍为 NetManager）

    /// 单文件下载，替代原 `SingleFileDownloader.download(url:destination:)` 调用点。
    ///
    /// 行为等价要点：
    /// - 候选源固定为传入的单个 URL（旧调用只传一个 URL），故注入无备用源的顺序解析器，
    ///   不因 `fileDownloadSource == .both` 凭空追加镜像源；
    /// - 覆盖策略沿用旧链路缺省值 `.skip`（调用方已在入口处按文件存在与否提前返回，该分支常态不可达）；
    /// - 不把校验参数塞进请求：旧链路是「先下载、再由调用方校验」，把 sha256 交给引擎会改变
    ///   校验时机、失败文案与「删除已落盘文件」的归属，故保持调用方自行校验；
    /// - 旧调用未传进度回调；失败抛出携带旧链路原始描述的错误（唯一调用方以 `try?` 吞掉错误）。
    private static func downloadSingleFile(from url: URL, to destination: URL) async throws {
        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver(), replaceMethod: .skip)
        let request = DownloadRequest(url: url, destinationURL: destination)
        let handle = try await engine.submit(request)

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
