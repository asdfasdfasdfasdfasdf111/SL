//
//  DefaultLaunchPreflightImplementations.swift
//  启动用例层：`LaunchPreflight` 协议族的默认实现（P2-1 接线）
//
//  四段逻辑自 `SLCore/Minecraft/Launch/LaunchFix.swift` 逐行迁移（P3-3 拆分出的
//  collectMissingLibraries / collectMissingAssets / download / ensureNatives 语义），
//  迁移目标是把「启动前补全」从 SLCore 上帝对象挪到用例层可替换协议。
//  行为等价依据（LAUNCH_FLOW 不变）：
//  - 下载仍走 `MultiFileDownloader`（NetManager 引擎），并发 32、多源回退不变；
//  - 进度映射由编排层（`DefaultLaunchPreflight`）负责，与 `LaunchFix.perform` 原口径一致：
//    支持库占前 0.5（每项推进，含跳过），资源占后 0.5（仅跳过项推进）；
//  - 「补不了的项」逐条 err 进日志 + 末尾一次汇总提示（文案与 LaunchFix 一致）。
//
//  本文件只放协议族默认实现与编排方法；跨层桥（instance → context 抽取）在
//  `LaunchPreflightBridge.swift`。

import Foundation

// MARK: - 客户端 JAR 校验

/// 客户端 JAR 存在性 + 非空校验（minSize 1）。
/// 判据与桥接层 `slLaunchInternal` 开头的 FileChecker(minSize: 1) 一致：
/// 作为 preflight 的二道防线，正常启动时必过（同判据、同文件、同时间点）。
public struct DefaultClientFileVerifier: ClientFileVerifier {

    public init() {}

    public func verify(_ context: LaunchPreflightContext) async throws {
        let checker = FileChecker(minSize: 1)
        if let reason = checker.check(context.clientJAR) {
            throw MyLocalizedError(reason: "客户端 JAR 缺失或损坏：\(context.clientJAR.path)（\(reason)）。请在「下载」页重新安装该版本。")
        }
    }
}

// MARK: - 支持库校验（PCL2 McLibFix）

/// 按 sha1 找出缺失/损坏的支持库并下载（`LaunchFix.collectMissingLibraries` + download 迁移）。
/// 进度：每项推进 `(i+1)/total`（含跳过项——跳过也要推进，否则进度条停在原地），
/// 由编排层映射到全局前 0.5 区间。
public struct DefaultLibraryFileVerifier: LibraryFileVerifier {

    /// 「补不了的项」收集器：缺库但解析不出下载地址时记入，编排层末尾统一提示。
    private let unrepairableSink: UnrepairableSink

    public init(unrepairableSink: UnrepairableSink) {
        self.unrepairableSink = unrepairableSink
    }

    public func verify(_ context: LaunchPreflightContext, progress: LaunchProgressHandler?) async throws {
        var items: [DownloadItem] = []
        let total = max(1, context.libraries.count)
        for (i, artifact) in context.libraries.enumerated() {
            let step = Double(i + 1) / Double(total)
            let dest = context.librariesRoot.appendingPathComponent(artifact.path)
            if fileIsValid(dest, hash: artifact.sha1) { progress?(step); continue }
            if let url = artifact.downloadURL {
                items.append(.init(url, dest, sha1: artifact.sha1))
            } else {
                err("启动前补全：库 \(artifact.path) 缺失但无法解析下载地址，已跳过（\(dest.path)）")
                unrepairableSink.append("库 \(artifact.path)")
            }
            progress?(step)
        }
        if !items.isEmpty {
            try await download(items, progress: progress)
        }
    }

    private func download(_ items: [DownloadItem], progress: LaunchProgressHandler?) async throws {
        try await MultiFileDownloader(items: items, concurrentLimit: 32) { p, _ in
            progress?(p)
        }.start()
    }
}

// MARK: - 资源校验（PCL2 McAssetsFixList）

/// 资源索引缺失先补索引，再按 hash 校验 objects（`LaunchFix.collectMissingAssets` 迁移）。
/// 主循环：仅跳过项推进 `(i+1)/total`（缺项由下载推进），由编排层映射到全局后 0.5 区间。
/// 索引刚下载完后的补漏循环**不推进度**（全局进度已到 1，继续推会越界）——与 LaunchFix 一致。
public struct DefaultAssetFileVerifier: AssetFileVerifier {

    private let unrepairableSink: UnrepairableSink

    public init(unrepairableSink: UnrepairableSink) {
        self.unrepairableSink = unrepairableSink
    }

    public func verify(_ context: LaunchPreflightContext, progress: LaunchProgressHandler?) async throws {
        // 1) 资源索引：缺失或损坏时先补索引，再按索引分析缺失资源
        var items: [DownloadItem] = []
        var assetObjects = context.assetObjects
        if let assetIndexInfo = context.assetIndex {
            let indexPath = context.assetsRoot.appendingPathComponent("indexes").appendingPathComponent("\(assetIndexInfo.id).json")
            if !fileIsValid(indexPath, hash: assetIndexInfo.sha1) {
                if let url = URL(string: assetIndexInfo.url ?? "") {
                    items.append(.init(url, indexPath, sha1: assetIndexInfo.sha1))
                } else {
                    err("启动前补全：资源索引 URL 非法，已跳过：\(assetIndexInfo.url ?? "<nil>")")
                    unrepairableSink.append("资源索引 \(assetIndexInfo.id)")
                }
            }
            // 索引本地可用时立即解析，否则等下载完成后统一补资源（见下）
            if fileIsValid(indexPath, hash: assetIndexInfo.sha1),
               let data = try? Data(contentsOf: indexPath),
               let index = try? AssetIndex.parse(data) {
                assetObjects = index.objects.map { AssetObject(hash: $0.hash, downloadURL: nil) }
            }
        }

        // 2) 缺失资源分析：asset 以 hash 命名，直接用 hash 校验；缺项收集下载
        items += collectMissingAssets(assetObjects, context: context, progressOnSkip: { p in progress?(p) }, unrepairable: unrepairableSink)

        // 3) 下载缺失项（NetManager 引擎）
        if !items.isEmpty {
            try await download(items, progress: progress)
            // 若资源索引是本次刚下载的，现在补上资源分析
            if assetObjects.isEmpty, let assetIndexInfo = context.assetIndex {
                let indexPath = context.assetsRoot.appendingPathComponent("indexes").appendingPathComponent("\(assetIndexInfo.id).json")
                if let data = try? Data(contentsOf: indexPath),
                   let index = try? AssetIndex.parse(data) {
                    let assetItems = collectMissingAssets(
                        index.objects.map { AssetObject(hash: $0.hash, downloadURL: nil) },
                        context: context,
                        // 补漏场景：索引刚下载完，不推进度（全局进度已到 1，继续推会越界）
                        progressOnSkip: nil,
                        unrepairable: unrepairableSink
                    )
                    if !assetItems.isEmpty {
                        try await download(assetItems, progress: progress)
                    }
                }
            }
        }
    }

    private func collectMissingAssets(_ objects: [AssetObject], context: LaunchPreflightContext, progressOnSkip: ((Double) -> Void)?, unrepairable: UnrepairableSink) -> [DownloadItem] {
        var items: [DownloadItem] = []
        let assetTotal = max(1, objects.count)
        for (i, object) in objects.enumerated() {
            let dest = assetDestURL(object.hash, assetsRoot: context.assetsRoot)
            if fileIsValid(dest, hash: object.hash) {
                progressOnSkip?(Double(i + 1) / Double(assetTotal))
                continue
            }
            if let resolvedAssetURL = object.downloadURL ?? assetURL(hash: object.hash) {
                items.append(.init(resolvedAssetURL, dest, sha1: object.hash))
            } else {
                err("启动前补全：资源 \(object.hash) 的下载地址非法，已跳过")
                unrepairable.append("资源 \(object.hash)")
            }
        }
        return items
    }

    private func download(_ items: [DownloadItem], progress: LaunchProgressHandler?) async throws {
        try await MultiFileDownloader(items: items, concurrentLimit: 32) { p, _ in
            progress?(p)
        }.start()
    }

    private func assetDestURL(_ hash: String, assetsRoot: URL) -> URL {
        assetsRoot
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(hash)
    }

    private func assetURL(hash: String) -> URL? {
        URL(string: "https://resources.download.minecraft.net/\(String(hash.prefix(2)))/\(hash)")
    }
}

// MARK: - natives 安装（PCL2 McLaunchNatives 语义）

/// 缺失 natives 时重新解压（`MinecraftInstaller.ensureNatives` 的 context 直入版）。
/// 判据与 SLCore 原实现一致：已有与目标架构匹配的 dylib/jnilib 则跳过。
public struct DefaultNativeInstaller: NativeInstaller {

    public init() {}

    public func install(_ context: LaunchPreflightContext) async throws {
        try MinecraftInstaller.ensureNatives(nativesDirectory: context.nativesDirectory, nativeLibraryPaths: context.nativeLibraryPaths, librariesRoot: context.librariesRoot)
    }
}

// MARK: - unrepairable 汇总（P2-1 接线：原 LaunchFix 的末尾汇总提示保留）

/// 「补不了的项」线程安全收集器。校验器逐条写入，编排层末尾统一提示：
/// 逐条 err 进日志 + 一次汇总 hint（与 LaunchFix.perform 末尾行为一致）。
public final class UnrepairableSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    public init() {}

    public func append(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    public func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let result = items
        items = []
        return result
    }
}

// MARK: - 工具

/// 文件存在且（有 hash 时）hash 匹配 → true（与 LaunchFix 原判据一致）
private func fileIsValid(_ url: URL, hash: String?) -> Bool {
    FileChecker(hash: hash).check(url) == nil
}
