//
//  ForgeInstaller.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/8/15.
//
//  Forge / NeoForge 安装器的骨架与安装编排。本文件保留：
//  - 实例状态与 init
//  - 下载段：单文件下载（经 DownloadEngine 提交，后端仍为 NetManager，逐字未改）、
//    DOWNLOAD_MOJMAPS 任务改写、安装器下载、加载器依赖下载
//  - install：安装入口与阶段顺序
//  - getInstallerDownloadURL / getGroupId：子类（NeoforgeInstaller）可覆盖的地址与 groupId 规则
//  - 进度累加与上报
//  安装流程（install_profile.json 解析、处理器执行、清单拷贝）按职责拆分在同目录，
//  逻辑、常量与日志文案均与原实现逐字一致（仅物理搬移）：
//  - ForgeInstallerInstallFlow.swift
//
//  跨文件访问级别说明（依据 references/swift-language/access-control.md 与 extensions.md，
//  官方链接 https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/
//  与 .../extensions/）：`private` 仅对「同一封闭声明及其同文件扩展」可见，且扩展不能声明存储属性，
//  故拆分后仅有下列成员的访问级别由 private 提升为 internal，其余成员一律保持 private：
//  minecraftDirectory / versionPath / manifest / temp / installProfile / values / isOld、
//  patchMojangMappingsDownloadTask、copyManifest、parseValues、replaceWithValue、
//  executeProcessors、increaseProgress。对外接口与子类可覆盖点均无变化。
//

import Foundation
import ZIPFoundation
import SwiftyJSON

public class ForgeInstaller {
    let minecraftDirectory: MinecraftDirectory
    let versionPath: URL
    let manifest: ClientManifest
    let temp: TemperatureDirectory
    var installProfile: ForgeInstallProfile?
    var values: [String: String] = [:]
    var isOld: Bool = false
    private var updateProgress: ((Double) -> Void)?
    private var progress: Double = 0
    
    public init(_ minecraftDirectory: MinecraftDirectory, _ versionPath: URL, _ manifest: ClientManifest, updateProgress: ((Double) -> Void)? = nil) {
        self.minecraftDirectory = minecraftDirectory
        self.versionPath = versionPath
        self.manifest = manifest
        self.updateProgress = updateProgress
        self.temp = .init(name: "ForgeInstall")
    }
    
    // MARK: - 单文件下载（经 DownloadEngine 提交，后端仍为 NetManager）

    /// 单文件下载，替代原 `SingleFileDownloader.download(url:destination:)` 调用点。
    ///
    /// 行为等价要点：
    /// - 候选源固定为传入的单个 URL：旧调用只传一个 URL，此处用无备用源的顺序解析器，
    ///   不因 `fileDownloadSource == .both` 额外追加镜像源，源尝试顺序与旧链路一致；
    /// - 进度回调口径为 0…1 比例；下载成功与「已存在且校验通过而跳过」两条分支均回调 `1.0`，
    ///   与旧引擎一致；
    /// - 覆盖策略由调用方显式传入，与旧调用点逐一对应；
    /// - 失败时抛出携带旧链路原始描述的错误，调用侧取 `error.localizedDescription` 的文案不变。
    private func downloadSingleFile(
        from url: URL,
        to destination: URL,
        replaceMethod: ReplaceMethod,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver())
        let request = DownloadRequest(url: url, destinationURL: destination)
        let handle = try await engine.submit(request, replaceMethod: replaceMethod)

        for await state in engine.observe(taskID: handle.taskID) {
            switch state {
            case .downloading(let snapshot):
                progress?(snapshot.fraction)
            case .completed:
                // 旧链路在成功路径末尾固定回调 progress(1.0)，此处保持终值一致。
                progress?(1.0)
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

    // MARK: - 修改 DOWNLOAD_MOJMAPS 任务
    /// 访问级别为 internal：处理器循环（ForgeInstallerInstallFlow.swift）调用。
    func patchMojangMappingsDownloadTask(_ processor: ForgeInstallProfile.Processor) async throws -> Bool {
        // 若参数中不存在 --output，或 --output 后没有参数，返回
        guard let index = processor.args.firstIndex(of: "--output"),
              index + 1 < processor.args.count else {
            return false
        }
        
        // 若实例的 client_mappings 下载项不存在，跳过
        guard let clientMappingsDownload = manifest.clientMappingsDownload else {
            return false
        }
        
        // 下载 mappings
        let url = clientMappingsDownload.url
        let destination = URL(fileURLWithPath: replaceWithValue(processor.args[index + 1]))
        
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await downloadSingleFile(from: url.url, to: destination, replaceMethod: .replace)
        debug("已修改 DOWNLOAD_MOJMAPS 任务")
        
        return true
    }
    
    // MARK: - 下载安装器
    private func downloadInstaller(minecraftVersion: MinecraftVersion, version: String) async throws {
        let installerPath = temp.getURL(path: "installer.jar")
        // 如果 CacheStorage 中不存在安装器，下载
        let name = "\(getGroupId()):installer:\(minecraftVersion.displayName)-\(version)"
        if !CacheStorage.default.copy(name: name, to: installerPath) {
            let url = getInstallerDownloadURL(minecraftVersion, version)
            let dest = temp.getURL(path: "installer.jar")
            log("正在下载安装器 \(url.lastPathComponent)")
            // 覆盖策略沿用旧链路缺省值 .skip；进度按 0.2 折算，下载占整体进度的 20%。
            try await downloadSingleFile(from: url, to: dest, replaceMethod: .skip) { progress in
                Task { @MainActor in self.setProgress(progress * 0.2) }
            }
            log("安装器下载完成")
            CacheStorage.default.add(name: name, path: dest)
        }
        await setProgress(0.2)
    }
    
    // MARK: - 下载安装器与加载器依赖
    private func downloadDependencies() async throws {
        log("正在下载依赖项")
        var libraries: [ClientManifest.Library] = []
        if isOld {
            if let manifest = try ClientManifest.parse(url: temp.getURL(path: "manifest.json")) {
                libraries.append(contentsOf: manifest.libraries)
            }
        } else {
            guard let installProfile else {
                throw MyLocalizedError(reason: "installProfile 为空")
            }
            libraries.append(contentsOf: installProfile.libraries)
        }
        
        let artifacts = libraries.compactMap { $0.artifact }
        
        let downloader = MultiFileDownloader(
            urls: libraries.compactMap(DownloadSourceManager.shared.getLibraryURL(_:)),
            destinations: artifacts.map { minecraftDirectory.librariesURL.appendingPathComponent($0.path) },
            replaceMethod: .skip
        ) { progress, _ in
            Task { @MainActor in
                self.setProgress(0.3 + progress * 0.3)
            }
        }
        
        try await downloader.start()
    }
    
    // MARK: - 安装函数
    public func install(minecraftVersion: MinecraftVersion, forgeVersion: String) async throws {
        try await downloadInstaller(minecraftVersion: minecraftVersion, version: forgeVersion)
        try copyManifest(version: minecraftVersion)
        try await parseValues()
        try await downloadDependencies()
        
        if !isOld {
            try await executeProcessors()
        }
        
        await setProgress(1.0)
        temp.free()
    }
    
    
    func getInstallerDownloadURL(_ minecraftVersion: MinecraftVersion, _ version: String) -> URL {
        return URL(string: "https://bmclapi2.bangbang93.com/forge/download"
            + "?mcversion=\(minecraftVersion.displayName)"
            + "&version=\(version)"
            + "&category=installer"
            + "&format=jar"
        )!
    }
    
    func getGroupId() -> String { "net.minecraftforge" }
    
    /// 访问级别为 internal：安装流程（ForgeInstallerInstallFlow.swift）逐项累加进度时调用。
    @MainActor
    func increaseProgress(_ value: Double) {
        setProgress(progress + value)
    }
    
    @MainActor
    private func setProgress(_ value: Double) {
        progress = value
        updateProgress?(progress)
    }
}
