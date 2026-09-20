//
//  ModInstallUseCase.swift
//  模块化拆分：ModBrowser 用例层（安装准备）
//
//  职责边界：本用例只做"选版本 + 定文件 + 定目标路径"，产出 `ModInstallPlan`；
//  真正的字节传输由 `qwq/Core/Download` 的下载引擎在接线层执行（本模块不依赖那套引擎，
//  避免浏览与下载两个模块互相引用）。校验信息（sha1 / 字节数）随计划一并带出。
//

import Foundation

// MARK: - 安装请求

/// 一次模组安装的输入。
struct ModInstallRequest: Sendable, Hashable {

    /// Modrinth 项目 ID
    let projectID: String

    /// 目标游戏版本（如 "1.20.1"）
    let gameVersion: String

    /// 加载器过滤（取 `ModLoader.rawValue`）；空数组表示不按加载器过滤
    let loaders: [String]

    /// 落盘目录（既有实现为 `<gameRoot>/versions/<version>/mods`）
    let destinationDirectory: URL

    init(projectID: String, gameVersion: String, loaders: [String] = [], destinationDirectory: URL) {
        self.projectID = projectID
        self.gameVersion = gameVersion
        self.loaders = loaders
        self.destinationDirectory = destinationDirectory
    }
}

// MARK: - 安装计划

/// 安装计划：已解析的版本、主文件与目标路径。
struct ModInstallPlan: Sendable, Hashable {

    let projectID: String
    let version: ModProjectVersion
    let file: ModProjectFile

    /// 目标路径：落盘目录 + 主文件名
    let destinationURL: URL
}

// MARK: - 安装用例

/// 安装准备用例。
struct ModInstallUseCase: Sendable {

    private let service: ModBrowserService

    init(service: ModBrowserService) {
        self.service = service
    }

    /// 解析出可直接交由下载引擎执行的安装计划。
    func makePlan(_ request: ModInstallRequest) async throws -> ModInstallPlan {
        let versions = try await service.versions(
            of: request.projectID,
            loaders: request.loaders.isEmpty ? nil : request.loaders,
            gameVersions: [request.gameVersion]
        )
        guard let version = Self.select(versions, gameVersion: request.gameVersion) else {
            throw ModBrowserError.noCompatibleVersion(projectID: request.projectID)
        }
        guard let file = version.primaryFile else {
            throw ModBrowserError.noDownloadableFile(projectID: request.projectID)
        }
        return ModInstallPlan(
            projectID: request.projectID,
            version: version,
            file: file,
            destinationURL: request.destinationDirectory.appendingPathComponent(file.filename)
        )
    }

    /// 选版本：先精确匹配目标游戏版本，再放宽到主版本前缀匹配。
    ///
    /// 匹配规则与 `ModDownloader.bestMatch(_:gameVersion:loader:prefixMatch:)` 一致，
    /// 列表顺序沿用接口返回的发布时间降序，因此取首个命中项。
    /// 历史教训（`ModDownloader` 注释中的 L4/L5）：不再放宽到"取最新版本"，
    /// 否则会把不兼容的文件装进目录。
    private static func select(_ versions: [ModProjectVersion], gameVersion: String) -> ModProjectVersion? {
        if let exact = versions.first(where: { $0.gameVersions.contains(gameVersion) }) {
            return exact
        }
        return versions.first { version in
            version.gameVersions.contains { candidate in
                candidate.hasPrefix(gameVersion + ".")
                    || (gameVersion.contains(".") && gameVersion.hasPrefix(candidate + "."))
            }
        }
    }
}
