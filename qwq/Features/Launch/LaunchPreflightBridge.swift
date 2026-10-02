//
//  LaunchPreflightBridge.swift
//  启动前补全跨层桥（P2-1 接线）
//
//  背景：`LaunchPreflight` 协议族在启动用例层（Features/Launch），而启动实现
//  （`SLLaunchBridge.slLaunchInternal`）在 SLCore。用例层通过本桥调用 preflight：
//  本桥只做「instance / manifest → 值类型 context」的抽取与四个默认校验器的组装，
//  不包含任何校验/下载逻辑（那些在 `DefaultLaunchPreflightImplementations.swift`）。
//
//  抽取完整映射（对照 LaunchFix.perform 的输入）：
//  - libraries           ← manifest.getNeededLibraries()，downloadURL 用 DownloadSourceManager 预解析
//    （`getLibraryURL` 需要 ClientManifest.Library，属非 Sendable 引用，故在桥内解析，
//     校验器只持有 (path, sha1, downloadURL) 值类型——遵守协议的「值类型快照」约定）
//  - assetIndex/object   ← manifest.assetIndex + 本地索引解析
//  - nativeLibraryPaths  ← manifest.getNeededNatives().values.map(\.path)
//
//  本桥是 SLCore → Features 的唯一启动前补全入口（与 JavaResolverBridge 同模式）：
//  SLLaunchBridge 只调 `LaunchPreflightBridge.prepare(instance:onProgress:)`。

import Foundation

/// 启动前补全跨层桥：SLCore 的 `slLaunchInternal` 经此调用用例层 `DefaultLaunchPreflight`。
public enum LaunchPreflightBridge {

    /// 执行启动前补全（替代原 `LaunchFix.perform(instance:onProgress:)` 调用点）。
    /// 行为等价：下载仍走 MultiFileDownloader（NetManager 引擎），进度 0~1 单调，
    /// 「补不了的项」逐条 err + 末尾一次汇总提示。
    public static func prepare(instance: MinecraftInstance, onProgress: @escaping (Double) -> Void) async throws {
        let context = try makeContext(instance)
        let unrepairable = UnrepairableSink()
        // 入参 onProgress 为桥接层非隔离闭包（slLaunch 签名：`progressHandler: @escaping (Double) -> Void`），
        // 协议 `LaunchProgressHandler` 要求 @Sendable。桥内包一层 Sendable 中转：
        // 校验与下载全部在 `DefaultLaunchPreflight.prepare` 的异步上下文执行，闭包跨调查用是稳定的。
        let sendableProgress: LaunchProgressHandler = { p in onProgress(p) }
        let preflight = DefaultLaunchPreflight(
            contextResolver: { _ in context },
            clientVerifier: DefaultClientFileVerifier(),
            libraryVerifier: DefaultLibraryFileVerifier(unrepairableSink: unrepairable),
            assetVerifier: DefaultAssetFileVerifier(unrepairableSink: unrepairable),
            nativeInstaller: DefaultNativeInstaller(),
            progress: sendableProgress
        )
        try await preflight.prepare(context: context, unrepairable: unrepairable)
    }

    // MARK: - instance → context 抽取

    private static func makeContext(_ instance: MinecraftInstance) throws -> LaunchPreflightContext {
        guard let manifest = instance.manifest else {
            // 无 manifest 无法分析缺失项，跳过补全（启动流程自身会报错）——与 LaunchFix 原语义一致
            return LaunchPreflightContext(
                version: instance.version?.displayName ?? instance.name,
                runningDirectory: instance.runningDirectory,
                clientJAR: instance.runningDirectory.appendingPathComponent("\(instance.name).jar"),
                clientSHA1: nil,
                librariesRoot: instance.minecraftDirectory.librariesURL,
                libraries: [],
                assetsRoot: instance.minecraftDirectory.assetsURL,
                assetIndex: nil,
                assetObjects: [],
                nativesDirectory: instance.runningDirectory.appendingPathComponent("natives"),
                nativeLibraryPaths: []
            )
        }
        let dir = instance.minecraftDirectory

        // 支持库：逐项预解析下载地址（getLibraryURL 需要 Library 引用，只能在桥内做）
        let libraries: [LibraryArtifact] = manifest.getNeededLibraries().compactMap { library in
            guard let artifact = library.artifact else { return nil }
            return LibraryArtifact(
                path: artifact.path,
                sha1: artifact.sha1,
                downloadURL: DownloadSourceManager.shared.getLibraryURL(library)
            )
        }

        // 资源索引
        let assetIndexRef = manifest.assetIndex.map {
            AssetIndexReference(id: $0.id, sha1: $0.sha1, url: $0.url)
        }

        // 资源对象：索引本地可用时立即解析（否则留空，由 AssetFileVerifier 等下载后补漏）
        var assetObjects: [AssetObject] = []
        if let assetIndexRef, let indexPath = assetIndexRef.indexFileURL(for: dir.assetsURL),
           FileChecker(hash: assetIndexRef.sha1).check(indexPath) == nil,
           let data = try? Data(contentsOf: indexPath),
           let index = try? AssetIndex.parse(data) {
            assetObjects = index.objects.map { AssetObject(hash: $0.hash, downloadURL: nil) }
        }

        // natives jar 坐标（getNeededNatives 值是 DownloadInfo，path 即相对 libraries 的坐标）
        let nativePaths = manifest.getNeededNatives().values.map(\.path)

        return LaunchPreflightContext(
            version: instance.version?.displayName ?? instance.name,
            runningDirectory: instance.runningDirectory,
            clientJAR: instance.runningDirectory.appendingPathComponent("\(instance.name).jar"),
            clientSHA1: nil,
            librariesRoot: dir.librariesURL,
            libraries: libraries,
            assetsRoot: dir.assetsURL,
            assetIndex: assetIndexRef,
            assetObjects: assetObjects,
            nativesDirectory: instance.runningDirectory.appendingPathComponent("natives"),
            nativeLibraryPaths: nativePaths
        )
    }
}

// MARK: - AssetIndexReference 辅助（值类型 → 索引文件 URL）

extension AssetIndexReference {
    /// 索引文件路径：assetsRoot/indexes/<id>.json（值类型版，不依赖 LaunchPreflightContext）
    func indexFileURL(for assetsRoot: URL) -> URL? {
        assetsRoot
            .appendingPathComponent("indexes", isDirectory: true)
            .appendingPathComponent("\(id).json")
    }
}