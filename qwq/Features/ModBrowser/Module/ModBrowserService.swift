//
//  ModBrowserService.swift
//  模块化拆分：ModBrowser 模块对外服务协议与默认实现
//
//  设计约定：
//  - 协议为 `Sendable`，实现必须以值类型或不可变引用形态提供，可跨任务传递；
//  - 默认实现是既有代码的**适配器**，不二次实现检索/版本解析逻辑
//    （对应 `JavaRepository` → `DefaultJavaRepository` 的做法）。
//

import Foundation

// MARK: - 模块错误

/// ModBrowser 模块的失败原因。
///
/// 与 `ModDownloader.ModError` 职责分开：后者是下载器内部错误，
/// 本类型是模块对外契约的一部分，供 UI / 用例层区分处理。
enum ModBrowserError: LocalizedError {

    /// 上游 Modrinth 请求失败（网络不可达或响应无法解码）
    case requestFailed(String)

    /// 没有任何版本同时满足目标游戏版本与加载器
    case noCompatibleVersion(projectID: String)

    /// 选中的版本不含可下载文件
    case noDownloadableFile(projectID: String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let reason):
            return "Modrinth 请求失败：\(reason)"
        case .noCompatibleVersion(let projectID):
            return "项目 \(projectID) 没有兼容当前游戏版本与加载器的版本。"
        case .noDownloadableFile(let projectID):
            return "项目 \(projectID) 的版本中没有可下载文件。"
        }
    }
}

// MARK: - 服务协议

/// Modrinth 项目浏览的唯一入口。
///
/// 上层（分类页、详情页、安装流程）不再各自调用 `ModDownloader` / `ModrinthSearcher` / `LocalModCatalog`，
/// 统一经由此协议获取项目、版本与检索结果。
protocol ModBrowserService: Sendable {

    /// 按关键词与项目类型检索。
    ///
    /// 不抛错：底层 `ModrinthSearcher.search` 在网络失败或解析失败时返回空结果
    /// （`([], 0)`），本方法保持该语义。调用方不得把空结果当作错误处理。
    func search(_ request: ModSearchRequest) async -> ModSearchResult

    /// 取项目详情。
    func projectDetail(id: String) async throws -> ModProject

    /// 取项目的版本列表。
    /// - Parameters:
    ///   - loaders: 加载器名称过滤（取 `ModLoader.rawValue`）；nil 表示不过滤
    ///   - gameVersions: 游戏版本过滤；nil 表示不过滤
    func versions(of projectID: String, loaders: [String]?, gameVersions: [String]?) async throws -> [ModProjectVersion]
}

// MARK: - 默认实现

/// 复用既有实现的适配器。
///
/// 依赖的既有类型：
/// - `ModrinthSearcher.search`：分类页当前使用的检索管线（支持四种 project_type，返回命中总数）
/// - `ModDownloader.getProject` / `getVersions`：项目详情与版本列表
///
/// `ModDownloader` 是带搜索结果缓存的引用类型且未声明 `Sendable`，
/// 因此不放入实例属性；以静态 let 复用同一实例（其缓存内部由 `os_unfair_lock` 保护）。
/// 本类型自身无可变状态。
struct DefaultModBrowserService: ModBrowserService {

    private static let downloader = ModDownloader()

    init() {}

    func search(_ request: ModSearchRequest) async -> ModSearchResult {
        let (items, totalHits) = await ModrinthSearcher.search(
            type: request.projectType.rawValue,
            label: request.projectType.displayName,
            query: request.query,
            offset: request.offset,
            limit: request.limit
        )
        return ModSearchResult(
            items: items.map { ModProject($0, projectType: request.projectType) },
            totalHits: totalHits,
            offset: request.offset,
            limit: request.limit
        )
    }

    func projectDetail(id: String) async throws -> ModProject {
        do {
            let project = try await Self.downloader.getProject(modId: id)
            return ModProject(project)
        } catch {
            throw ModBrowserError.requestFailed(error.localizedDescription)
        }
    }

    func versions(of projectID: String, loaders: [String]?, gameVersions: [String]?) async throws -> [ModProjectVersion] {
        // 协议用字符串表达加载器（与 Modrinth 的 loaders 字段同形态），
        // 而 `ModDownloader.getVersions` 收 `ModLoader`，此处做一次显式映射；
        // 无法识别的名称直接丢弃，不改变过滤语义。
        let loaderFilters = loaders?.compactMap { ModLoader(rawValue: $0) }
        do {
            let versions = try await Self.downloader.getVersions(
                modId: projectID,
                loaders: loaderFilters,
                gameVersions: gameVersions
            )
            return versions.map(ModProjectVersion.init)
        } catch {
            throw ModBrowserError.requestFailed(error.localizedDescription)
        }
    }
}
