//
//  ModSearchUseCase.swift
//  模块化拆分：ModBrowser 用例层（检索与详情）
//
//  用例层只依赖 `ModBrowserService` 协议，不接触 `ModDownloader` / `ModrinthSearcher` /
//  `LocalModCatalog` 等具体实现，便于替换与单测。
//

import Foundation

// MARK: - 详情页数据

/// 详情页一次性取回的数据：项目本身 + 全部版本。
///
/// 既有 `ModDetailView` 需要分别取项目、版本、加载器，这里把两次往返收进一个用例，
/// 版本过滤留在本结构上做纯函数计算。
struct ModProjectDetail: Sendable, Hashable {

    let project: ModProject
    let versions: [ModProjectVersion]

    /// 按加载器与游戏版本过滤版本。
    /// - Parameters:
    ///   - loader: 加载器名称（取 `ModLoader.rawValue`）；nil 表示不过滤
    ///   - gameVersion: 游戏版本；nil 表示不过滤
    /// 过滤只做包含匹配，不做范围解析（既有 `ModVersionDetector.versionMatches` 支持的范围表达式
    /// 尚未接入本用例层，属后续工作）。
    func versions(matchingLoader loader: String?, gameVersion: String?) -> [ModProjectVersion] {
        versions.filter { version in
            if let loader, !version.loaders.contains(loader) { return false }
            if let gameVersion, !version.gameVersions.contains(gameVersion) { return false }
            return true
        }
    }
}

// MARK: - 检索用例

/// 检索与详情读取。
struct ModSearchUseCase: Sendable {

    private let service: ModBrowserService

    init(service: ModBrowserService) {
        self.service = service
    }

    /// 检索项目。
    func search(_ request: ModSearchRequest) async -> ModSearchResult {
        await service.search(request)
    }

    /// 读取详情页数据（项目 + 全部版本）。
    func detail(projectID: String) async throws -> ModProjectDetail {
        let project = try await service.projectDetail(id: projectID)
        let versions = try await service.versions(of: projectID, loaders: nil, gameVersions: nil)
        return ModProjectDetail(project: project, versions: versions)
    }
}
