//
//  MinecraftInstallerDownloads.swift
//  PCL.Mac
//
//  Minecraft 原版安装的各阶段下载（从 MinecraftInstaller.swift 逐字搬移，逻辑与文案未变）：
//  - downloadSingleFile：单文件下载，经 DownloadEngine 提交（后端仍为 NetManager）
//  - downloadClientManifest / downloadClientJar：客户端清单与客户端本体
//  - downloadAssetIndex / downloadHashResourcesFiles：资源索引与散列资源
//  - downloadLibraries / downloadNatives：依赖项与本地库
//
//  结构分层（自 MinecraftInstaller.swift 逐字搬移）：本次只做物理拆分，不改阶段顺序与进度口径。
//  拆分后两条路径的后端分工为——单文件已在此前的切换批次中改经 `DownloadEngine` 提交
//  （后端仍为 `NetManager`）；批量路径仍经 `MultiFileDownloader` → `NetManager.downloadAll`，
//  **不切换**（原因见下）。
//
//  批量路径不切换的原因（完整清单见 `Core/Download/Adapters/MIGRATION.md` 第六节
//  「批量路径（#5 / #6 / #8）评估：本轮不切换」，逐条判据与本文件的对应关系记录在
//  `PCLCore/Download/MultiFileDownloader.swift` 的 `start()` 上，此处不重复）：
//  `downloadAll` 的批进度是「字节加权（分母为各文件首片响应头给出的 fileSize 之和）+ 200ms 采样轮询
//  + 预检跳过项不进入批次」三者耦合的引擎内部量，在 `DownloadEngine` 边界不可观察；
//  而本文件三处批进度都经 `task.updateParallelStage` 写进 `parallelStageProgress`，
//  最终由 `DownloadDetailView` 渲染为阶段百分比，属用户可见量，不能接受数值序列变化。
//

import Foundation

extension MinecraftInstaller {

    // MARK: 单文件下载（经 DownloadEngine 提交，后端仍为 NetManager）

    /// 单文件下载，替代原 `SingleFileDownloader.download(task:urls:destination:...)` 调用点。
    ///
    /// 行为等价要点：
    /// - 候选源顺序逐点保留：调用方已用 `DownloadSourceManager.downloadURLs` 解析出
    ///   「主源 + 互补源」有序数组，这里把首位作主源、其余作顺序备用源，
    ///   不重新解析（避免默认解析器按 host 再补一次镜像源，或丢失镜像主源场景下的官方备用源）；
    /// - 校验：`expectedSHA1` → `DownloadRequest.sha1`，与旧链路 `FileChecker(hash:)` 同义
    ///   （都为 actualSize = -1，算法按长度自动判定）；
    /// - 覆盖策略由调用方显式传入，与旧调用点逐一对应（旧实现缺省 `.skip`）；
    /// - 进度口径为 0…1 比例，路由方式与旧实现一致：指定 `stage` 时写并行阶段进度，否则写
    ///   `currentStagePercentage`；成功（含「已存在且校验通过而跳过」）固定回调终值 `1.0`
    ///   并调用一次 `completeOneFile()`；
    /// - 失败抛出携带旧链路原始描述的错误，调用方取 `error.localizedDescription` 的文案不变。
    private static func downloadSingleFile(
        task: MinecraftInstallTask?,
        urls: [URL],
        destination: URL,
        replaceMethod: ReplaceMethod,
        expectedSHA1: String? = nil,
        stage: InstallStage? = nil,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        // 调用方在构造 urls 后均已判空；此处仅作边界兜底。
        guard let primary = urls.first else {
            throw MyLocalizedError(reason: "无可用下载源。")
        }

        let engine = NetDownloaderDownloadEngine(
            resolver: SequentialDownloadSourceResolver(fallbacks: Array(urls.dropFirst()))
        )
        var request = DownloadRequest(url: primary, destinationURL: destination)
        request.sha1 = expectedSHA1
        let handle = try await engine.submit(request, replaceMethod: replaceMethod)

        for await state in engine.observe(taskID: handle.taskID) {
            switch state {
            case .downloading(let snapshot):
                // 旧链路进度回调由 NetManager 派发到 @MainActor，这里保持同样的隔离。
                let fraction = snapshot.fraction
                await MainActor.run {
                    if let stage {
                        task?.updateParallelStage(stage, progress: fraction)
                    } else {
                        task?.currentStagePercentage = fraction
                    }
                    progress?(fraction)
                }
            case .completed:
                await MainActor.run {
                    if let stage {
                        task?.updateParallelStage(stage, progress: 1)
                    } else {
                        task?.currentStagePercentage = 1
                    }
                    progress?(1.0)
                }
                // 旧 `SingleFileDownloader` 在下载返回后固定调用一次，跳过分支同样计数。
                task?.completeOneFile()
                return
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
    }
    
    // MARK: 下载客户端清单
    /// 访问级别为 internal：安装编排链（MinecraftInstaller.swift）调用。
    static func downloadClientManifest(_ task: MinecraftInstallTask) async throws {
        task.updateStage(.clientJson)
        // 主源 + 镜像源双 URL：官方源失败自动切镜像（旧实现单 URL，失败即无源可用报错）
        let urls = DownloadSourceManager.shared.downloadURLs { $0.getClientManifestURL(task.minecraftVersion) }
        guard !urls.isEmpty else {
            throw MyLocalizedError(reason: "无法获取 \(task.minecraftVersion.displayName) 的 JSON 下载 URL。")
        }
        let destination = task.versionURL.appendingPathComponent("\(task.name).json")
        
        try await downloadSingleFile(task: task, urls: urls, destination: destination, replaceMethod: .replace)
        
        if let manifest: ClientManifest = try .parse(url: destination, minecraftDirectory: nil) {
            task.manifest = manifest
        } else {
            let handle = try FileHandle(forReadingFrom: destination)
            let rawData = (try? handle.readToEnd()) ?? Data()
            try? handle.close()
            let content = String(data: rawData, encoding: .utf8) ?? "(binary data, \(rawData.count) bytes)"
            err("无法解析客户端清单: \(content)")
            throw MyLocalizedError(reason: "无法解析客户端清单：\(content)")
        }
    }
    
    // MARK: 下载客户端本体
    /// 访问级别为 internal：安装编排链（MinecraftInstaller.swift）调用。
    static func downloadClientJar(_ task: MinecraftInstallTask, parallel: Bool = false) async throws {
        if parallel { await task.beginParallelStage(.clientJar) }
        else { task.updateStage(.clientJar) }
        guard let manifest = task.manifest else {
            throw MyLocalizedError(reason: "客户端清单为空，无法下载客户端本体。")
        }
        // 主源 + 镜像源双 URL（原版 jar 下载失败自动切换下载源——用户反馈的核心场景）
        let urls = DownloadSourceManager.shared.downloadURLs { $0.getClientJARURL(task.minecraftVersion, manifest) }
        guard !urls.isEmpty else {
            throw MyLocalizedError(reason: "无法获取 \(task.minecraftVersion.displayName) 的客户端下载 URL。")
        }
        
        try await downloadSingleFile(
            task: task,
            urls: urls,
            destination: task.versionURL.appendingPathComponent("\(task.name).jar"),
            replaceMethod: .skip, // 旧链路未显式传 replaceMethod，缺省为 .skip
            expectedSHA1: manifest.clientDownload?.sha1,
            stage: parallel ? .clientJar : nil
        )
        if parallel { await task.finishParallelStage(.clientJar) }
    }
    
    // MARK: 下载资源索引
    /// 访问级别为 internal：安装编排链（MinecraftInstaller.swift）调用。
    static func downloadAssetIndex(_ task: MinecraftInstallTask, parallel: Bool = false) async throws {
        if parallel { await task.beginParallelStage(.clientIndex) }
        guard let manifest = task.manifest else {
            err("任务客户端清单为空值，停止下载资源索引")
            task.assetIndex = .init(objects: [])
            return
        }
        
        task.updateStage(.clientIndex)

        // 客户端清单可能缺少 assetIndex（旧版本如 1.5.2 及以下无独立资源索引）：
        // 必须在构造下载 URL 前判空，否则两个下载源都会返回 nil，并先触发「无 URL」错误。
        guard let assetIndex = manifest.assetIndex else {
            err("客户端清单缺少资源索引字段（该版本可能无独立资产索引），跳过资源索引阶段")
            task.assetIndex = .init(objects: [])
            return
        }

        // 主源 + 镜像源双 URL
        let urls = DownloadSourceManager.shared.downloadURLs { $0.getAssetIndexURL(task.minecraftVersion, manifest) }
        guard !urls.isEmpty else {
            throw MyLocalizedError(reason: "无法获取 \(task.minecraftVersion.displayName) 的 assetIndex 下载 URL。")
        }
        let destination: URL = task.minecraftDirectory.assetsURL.appendingPathComponent("indexes").appendingPathComponent("\(assetIndex.id).json")
        try await downloadSingleFile(task: task, urls: urls, destination: destination, replaceMethod: .skip, expectedSHA1: assetIndex.sha1, stage: parallel ? .clientIndex : nil)
        do {
            let data = try Data(contentsOf: destination)
            task.assetIndex = try .parse(data)
        } catch {
            err("在解析 JSON 时发生错误: \(error.localizedDescription)")
        }
        if parallel { await task.finishParallelStage(.clientIndex) }
    }
    
    // MARK: 下载散列资源文件
    /// 访问级别为 internal：安装编排链（MinecraftInstaller.swift）调用。
    static func downloadHashResourcesFiles(_ task: MinecraftInstallTask, parallel: Bool = false) async throws {
        if parallel { await task.beginParallelStage(.clientResources) }
        else { task.updateStage(.clientResources) }
        guard let assetIndex = task.assetIndex else {
            err("资源索引未就绪，跳过散列资源下载")
            if parallel { await task.finishParallelStage(.clientResources) }
            return
        }
        let objects = assetIndex.objects
        
        // asset 以 hash 命名，直接用 hash 作为校验：已存在且匹配 → 引擎内跳过，损坏 → 重下
        var items: [DownloadItem] = []
        
        for object in objects {
            let dest = object.appendTo(task.minecraftDirectory.assetsURL.appendingPathComponent("objects"))
            // 多源构造（主源 + 互补备用源）：官方失败自动切镜像，镜像失败自动切官方。
            // 旧实现硬编码官方 CDN（resources.download.minecraft.net），官方不可用时全部失败。
            // getAssetURL 仅在 hash 不足 2 字符时返回 nil，asset hash 恒为 40 位十六进制，! 安全
            items.append(.init(
                DownloadSourceManager.shared.getDownloadSource(),
                { $0.getAssetURL(hash: object.hash) ?? URL(string: "https://resources.download.minecraft.net/\(object.hash.prefix(2))/\(object.hash)")! },
                destination: dest,
                sha1: object.hash
            ))
        }
        
        try await MultiFileDownloader(task: task, items: items, stage: parallel ? .clientResources : nil).start()
        if parallel { await task.finishParallelStage(.clientResources) }
    }
    
    // MARK: 下载依赖项
    /// 访问级别为 internal：安装编排链（MinecraftInstaller.swift）调用。
    static func downloadLibraries(_ task: MinecraftInstallTask, parallel: Bool = false) async throws {
        if parallel { await task.beginParallelStage(.clientLibraries) }
        else { task.updateStage(.clientLibraries) }
        guard let manifest = task.manifest else {
            throw MyLocalizedError(reason: "客户端清单未就绪，无法下载依赖项")
        }

        var libraryNames: [String] = []
        var items: [DownloadItem] = []

        for library in manifest.getNeededLibraries() {
            if let artifact = library.artifact {
                let dest = task.minecraftDirectory.librariesURL.appendingPathComponent(artifact.path)
                if CacheStorage.default.copy(name: library.name, to: dest) {
                    continue
                }
                
                // 缺失预分析（PCL2 McLibFix）：本地已存在且 sha1 匹配 → 不进下载列表，进度按缺失数计算
                if FileChecker(hash: artifact.sha1).check(dest) == nil {
                    continue
                }
                
                libraryNames.append(library.name)
                items.append(.init(DownloadSourceManager.shared.getDownloadSource(), { $0.getLibraryURL(library)! }, destination: dest, sha1: artifact.sha1))
            }
        }
        
        try await MultiFileDownloader(task: task, items: items, stage: parallel ? .clientLibraries : nil).start()
        
        for library in manifest.getNeededLibraries() {
            if libraryNames.contains(library.name), let artifact = library.artifact {
                CacheStorage.default.add(name: library.name, path: task.minecraftDirectory.librariesURL.appendingPathComponent(artifact.path))
            }
        }
        if parallel { await task.finishParallelStage(.clientLibraries) }
    }

    // MARK: 下载本地库
    /// 访问级别为 internal：安装编排链（MinecraftInstaller.swift）调用。
    static func downloadNatives(_ task: MinecraftInstallTask, parallel: Bool = false) async throws {
        if parallel { await task.beginParallelStage(.natives) }
        else { task.updateStage(.natives) }
        guard let manifest = task.manifest else {
            throw MyLocalizedError(reason: "客户端清单未就绪，无法下载本地库")
        }

        var libraryNames: [String] = []
        var items: [DownloadItem] = []

        for (library, artifact) in manifest.getNeededNatives() {
            let dest = task.minecraftDirectory.librariesURL.appendingPathComponent(artifact.path)
            if CacheStorage.default.copy(name: library.name, to: dest) {
                continue
            }
            
            // 缺失预分析：已存在且 sha1 匹配 → 跳过
            if FileChecker(hash: artifact.sha1).check(dest) == nil {
                continue
            }
            
            libraryNames.append(library.name)
            items.append(.init(DownloadSourceManager.shared.getDownloadSource(), { $0.getLibraryURL(library)! }, destination: dest, sha1: artifact.sha1))
        }
        
        try? FileManager.default.createDirectory(at: task.versionURL.appendingPathComponent("natives"), withIntermediateDirectories: true)
        // 批量：保持旧后端，理由见 `MultiFileDownloader.start()` 的迁移记录。
        try await MultiFileDownloader(task: task, items: items, stage: parallel ? .natives : nil).start()
        
        for (library, artifact) in manifest.getNeededNatives() {
            if libraryNames.contains(library.name) {
                CacheStorage.default.add(name: library.name, path: task.minecraftDirectory.librariesURL.appendingPathComponent(artifact.path))
            }
        }
        if parallel { await task.finishParallelStage(.natives) }
    }
}
