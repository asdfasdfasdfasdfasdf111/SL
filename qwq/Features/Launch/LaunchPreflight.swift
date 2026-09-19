//
//  LaunchPreflight.swift
//  启动用例层：启动前校验的职责拆分
//
//  `PCLCore/Minecraft/Launch/LaunchFix.swift` 当前一个函数承担 client / library / asset / natives
//  四类校验与安装（PCL2 DlClientFix 移植）。本文件只做**职责边界的定义**，不修改 LaunchFix，
//  供后续接线阶段把 LaunchFix.perform 的四段逻辑分别落到四个实现里。
//
//  上下文类型刻意不直接持有 `MinecraftInstance`（非 Sendable 的引用类型）：
//  由接线层从 instance / manifest 抽取为下方位值类型，再交给各校验器，
//  这样校验器本身可独立测试、可并发调用。
//

import Foundation

// MARK: - 上下文

/// 单个支持库的产物信息：对应 `ClientManifest.getNeededLibraries()` 中 `library.artifact`
public struct LibraryArtifact: Sendable, Equatable, Hashable {
    /// 相对 `librariesRoot` 的相对路径（`artifact.path`）
    public let path: String
    /// 期望 sha1（`artifact.sha1`），nil 表示只校验存在性
    public let sha1: String?

    public init(path: String, sha1: String?) {
        self.path = path
        self.sha1 = sha1
    }
}

/// 资源索引信息：对应 `ClientManifest.assetIndex`
public struct AssetIndexReference: Sendable, Equatable, Hashable {
    /// 索引 id（如 "1.20.1"），索引文件名为 <id>.json
    public let id: String
    /// 索引文件期望 sha1
    public let sha1: String?
    /// 索引下载 URL 字符串
    public let url: String?

    public init(id: String, sha1: String?, url: String?) {
        self.id = id
        self.sha1 = sha1
        self.url = url
    }
}

/// 单个资源对象：对应 `AssetIndex.Object`
public struct AssetObject: Sendable, Equatable, Hashable {
    /// 对象 hash（同时作为存储名与前两位目录名）
    public let hash: String

    public init(hash: String) {
        self.hash = hash
    }
}

/// 启动前校验所需的全部输入（值类型快照）
public struct LaunchPreflightContext: Sendable, Equatable {
    /// 版本号
    public var version: String
    /// 版本运行目录（`MinecraftInstance.runningDirectory`）
    public var runningDirectory: URL
    /// 客户端 JAR 路径（= runningDirectory/<version>.jar）
    public var clientJAR: URL
    /// 客户端 JAR 期望 sha1（无则为 nil）
    public var clientSHA1: String?
    /// 支持库根目录（`MinecraftDirectory.librariesURL`）
    public var librariesRoot: URL
    /// 需要的支持库列表
    public var libraries: [LibraryArtifact]
    /// 资源根目录（`MinecraftDirectory.assetsURL`）
    public var assetsRoot: URL
    /// 资源索引（版本无资源索引时为 nil）
    public var assetIndex: AssetIndexReference?
    /// 资源对象列表（索引尚未落地时可为空，由 AssetFileVerifier 自行补齐）
    public var assetObjects: [AssetObject]
    /// natives 解压目录（= runningDirectory/natives）
    public var nativesDirectory: URL

    public init(
        version: String,
        runningDirectory: URL,
        clientJAR: URL,
        clientSHA1: String?,
        librariesRoot: URL,
        libraries: [LibraryArtifact],
        assetsRoot: URL,
        assetIndex: AssetIndexReference?,
        assetObjects: [AssetObject],
        nativesDirectory: URL
    ) {
        self.version = version
        self.runningDirectory = runningDirectory
        self.clientJAR = clientJAR
        self.clientSHA1 = clientSHA1
        self.librariesRoot = librariesRoot
        self.libraries = libraries
        self.assetsRoot = assetsRoot
        self.assetIndex = assetIndex
        self.assetObjects = assetObjects
        self.nativesDirectory = nativesDirectory
    }

    /// 资源索引文件路径：assetsRoot/indexes/<id>.json
    public var assetIndexFileURL: URL? {
        guard let assetIndex else { return nil }
        return assetsRoot
            .appendingPathComponent("indexes", isDirectory: true)
            .appendingPathComponent("\(assetIndex.id).json")
    }
}

// MARK: - 校验职责

/// 客户端 JAR 校验：存在性与（有 sha1 时）完整性
public protocol ClientFileVerifier: Sendable {
    func verify(_ context: LaunchPreflightContext) async throws
}

/// 支持库校验：按 sha1 找出缺失/损坏项并补全（对应 PCL2 McLibFix）
public protocol LibraryFileVerifier: Sendable {
    /// - Parameter progress: 0~1 局部进度，由编排层映射到全局区间
    func verify(_ context: LaunchPreflightContext, progress: LaunchProgressHandler?) async throws
}

/// 资源文件校验：索引缺失先补索引，再按 hash 校验 objects（对应 PCL2 McAssetsFixList）
public protocol AssetFileVerifier: Sendable {
    func verify(_ context: LaunchPreflightContext, progress: LaunchProgressHandler?) async throws
}

/// natives 安装：缺失时重新解压（对应 `MinecraftInstaller.ensureNatives`）
public protocol NativeInstaller: Sendable {
    func install(_ context: LaunchPreflightContext) async throws
}

/// 启动前置流程总入口
public protocol LaunchPreflight: Sendable {
    func prepare(_ request: LaunchRequest) async throws
}

// MARK: - 编排实现

/// 按 client → libraries → assets → natives 顺序执行的编排器。
///
/// 顺序与 `LaunchFix.perform` 现有实现一致（资源索引缺失时需先于资源对象校验），
/// 但把四段拆给四个可替换的实现，便于单独测试与后续替换下载引擎。
public struct DefaultLaunchPreflight: LaunchPreflight {

    private let contextResolver: @Sendable (LaunchRequest) throws -> LaunchPreflightContext
    private let clientVerifier: ClientFileVerifier
    private let libraryVerifier: LibraryFileVerifier
    private let assetVerifier: AssetFileVerifier
    private let nativeInstaller: NativeInstaller
    /// 全局进度回调（0~1）
    private let progress: LaunchProgressHandler?

    public init(
        contextResolver: @escaping @Sendable (LaunchRequest) throws -> LaunchPreflightContext,
        clientVerifier: ClientFileVerifier,
        libraryVerifier: LibraryFileVerifier,
        assetVerifier: AssetFileVerifier,
        nativeInstaller: NativeInstaller,
        progress: LaunchProgressHandler? = nil
    ) {
        self.contextResolver = contextResolver
        self.clientVerifier = clientVerifier
        self.libraryVerifier = libraryVerifier
        self.assetVerifier = assetVerifier
        self.nativeInstaller = nativeInstaller
        self.progress = progress
    }

    public func prepare(_ request: LaunchRequest) async throws {
        guard !request.skipResourceCheck else { return }

        let context = try contextResolver(request)

        try await clientVerifier.verify(context)

        // 进度区间沿用 LaunchFix.perform：支持库占前 0.5，资源占后 0.5
        try await libraryVerifier.verify(context) { p in
            progress?(p * 0.5)
        }
        try await assetVerifier.verify(context) { p in
            progress?(0.5 + p * 0.5)
        }

        try await nativeInstaller.install(context)
        progress?(1.0)
    }
}
