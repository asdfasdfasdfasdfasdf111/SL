//
//  DownloadSourceManager.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/8/20.
//

import Foundation

public class DownloadSourceManager: DownloadSource {
    public static let shared: DownloadSourceManager = .init()
    
    private let official: OfficialDownloadSource = .init()
    private let bmclapi: BMCLAPIDownloadSource = .init()
    
    private var lastTestDate: Date = .init(timeIntervalSince1970: 0)
    
    /// 测速节流：与 sourceLock 共用同一把锁（getDownloadSource 与 testSpeed 不同时持有重锁），
    /// 旧实现 lastTestDate 无锁读写 → 数据竞争（多线程并发调 getDownloadSource 时 Date 撕裂）。
    private var shouldThrottleSpeedTest: Bool {
        sourceLock.lock(); defer { sourceLock.unlock() }
        if Date().timeIntervalSince(lastTestDate) > 1 * 60 {
            lastTestDate = Date()
            return false
        }
        return true
    }

    // MARK: 源状态（NSLock 保护：getDownloadSource 在任意线程读、testSpeed 在后台 Task 写，
    // 旧实现无保护 → 数据竞争；下载项构造时也不再能看到「写一半」的中间态）
    private let sourceLock = NSLock()
    private var _fileDownloadSource: DownloadSource
    private var fileDownloadSource: DownloadSource {
        get { sourceLock.lock(); defer { sourceLock.unlock() }; return _fileDownloadSource }
        set { sourceLock.lock(); defer { sourceLock.unlock() }; _fileDownloadSource = newValue }
    }
    private var versionManifestSource: DownloadSource
    
    public func getDownloadSource() -> DownloadSource {
        if AppSettings.shared.fileDownloadSource == .both {
            if !shouldThrottleSpeedTest {
                Task {
                    log("正在进行官方源测速")
                    await testSpeed("https://libraries.minecraft.net/net/java/dev/jna/jna/5.15.0/jna-5.15.0.jar")
                }
            }
            return fileDownloadSource
        } else {
            // 用户手动限定单源时必须返回该源的**常量对象**，而不是可被 testSpeed 改写的
            // fileDownloadSource（它初值为 official，只在「自动切换」模式下的测速里被改成 bmclapi）。
            // 原实现「仅官方」也返回 fileDownloadSource：若此前处于 .both 并测速切到了镜像，
            // 用户再切到「仅官方」仍会请求镜像域名——与本文件 downloadURLs 声明的
            // 「手动限定单源不做悄悄跨源兜底」矛盾，也违背用户显式选择。
            return AppSettings.shared.fileDownloadSource == .mirror ? bmclapi : official
        }
    }

    /// 返回与给定源互补的备用源（官方↔镜像），供 DownloadItem 多源失败切换构造 fallback。
    /// 任意方向失败都能切到另一个源——旧实现 hardcode 官方源时「官方失败切镜像」永远不存在。
    public func alternateSource(of source: DownloadSource) -> DownloadSource {
        if source is BMCLAPIDownloadSource { return official }
        return bmclapi
    }

    /// 取「主源 URL + 备用源 URL」去重数组，供单文件多源下载（SLNetFile.urls 顺序失败切换）。
    /// 单文件（json/index/jar）旧实现只有 1 个 URL → 失败即无源可用；现在两个源都进数组，
    /// NetManager 按顺序自动切换，任一个成功即完成。
    /// 仅「自动切换（both）」模式追加互补源；用户手动限定单源（仅官方/仅镜像）时只返回该源的 URL，
    /// 不做悄悄跨源兜底——否则「仅官方」也会请求镜像站域名，破坏设置语义。
    public func downloadURLs(_ provider: (DownloadSource) -> URL?) -> [URL] {
        let primary = getDownloadSource()
        var urls: [URL] = []
        if let u = provider(primary) { urls.append(u) }
        if AppSettings.shared.fileDownloadSource == .both {
            let backup = alternateSource(of: primary)
            if let u = provider(backup), !urls.contains(u) { urls.append(u) }
        }
        return urls
    }
    
    public func getVersionManifestURL() -> URL {
        versionManifestSource.getVersionManifestURL()
    }
    
    public func getClientManifestURL(_ version: MinecraftVersion) -> URL? {
        getDownloadSource().getClientManifestURL(version)
    }
    
    public func getAssetIndexURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        getDownloadSource().getAssetIndexURL(version, manifest)
    }
    
    public func getClientJARURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        getDownloadSource().getClientJARURL(version, manifest)
    }
    
    public func getLibraryURL(_ library: ClientManifest.Library) -> URL? {
        getDownloadSource().getLibraryURL(library)
    }
    
    public func getAssetURL(hash: String) -> URL? {
        getDownloadSource().getAssetURL(hash: hash)
    }
    
    /// 官方源测速：下载一个固定测试文件，按墙钟耗时与文件大小判定主源。
    ///
    /// 迁移状态：内部**保持旧链路**（`SingleFileDownloader` → `NetManager.shared.download`），
    /// 不切换 `DownloadEngine`。两条不可等价的原因：
    /// 1. 本方法由 `getDownloadSource()` 派发，而缺省下载源解析器 `DefaultDownloadSourceResolver`
    ///    又委托 `DownloadSourceManager.getDownloadSource()`，改走引擎会形成
    ///    「测速 → 下载 → 解析源 → 测速」的重入（判据见 MIGRATION.md 第二节 #12）；
    /// 2. 本方法的结果就是 `before` 之后的墙钟差，属「输出即耗时」的调用方，而引擎以 `Task.detached`
    ///    承载下载并经 `AsyncStream` 逐元素投递状态，这些调度跳步会落在计时窗口内。
    /// 完整依据与行号记录在 `SingleFileDownloader.swift` 的类注释上。
    private func testSpeed(_ url: URLConvertible) async {
        // 不再预先强制切回官方源：上次测速切到镜像后，60s 后的再次测速会把源重置回官方，
        // 若官方仍然不可用，用户中途切换到的新源又被丢弃（旧实现的切换是「一次性」的）
        let before = Date()
        
        let data: Data
        do {
            let testPath = "/tmp/testspeed_\(UUID().uuidString)"
            try await SingleFileDownloader.download(url: url.url, destination: URL(fileURLWithPath: testPath), replaceMethod: .replace)
            data = try FileHandle(forReadingFrom: URL(fileURLWithPath: testPath)).readToEnd().unwrap()
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: testPath))
        } catch {
            // 官方源连测试文件都下载失败 → 视为不可用，立即切镜像源（用户期望的核心行为：
            // 「下载失败后自己切换下载源」——测速失败本身就是源不可用的强信号）
            fileDownloadSource = bmclapi
            debug("官方源测速下载失败，已切换至镜像源")
            return
        }
        
        let timeUsed: Double = Date().timeIntervalSince(before)
        let speed = Double(data.count) / timeUsed / 1024 / 1024
        debug(String(format: "\(url.url.lastPathComponent) 下载耗时 %.2fs (%.2f MB/s)", timeUsed, speed))
        fileDownloadSource = speed < 1 ? bmclapi : official
        if speed < 1 { // 1 MB
            debug("已切换至镜像源")
        } else {
            debug("官方源速度正常，保持官方源")
        }
    }
    
    private init() {
        self._fileDownloadSource = official
        self.versionManifestSource = AppSettings.shared.versionManifestSource == .mirror ? bmclapi : official
    }
}