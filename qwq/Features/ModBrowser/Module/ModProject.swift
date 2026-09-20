//
//  ModProject.swift
//  模块化拆分：ModBrowser 模块的统一项目模型
//
//  现状（`qwq/Features/ModBrowser/`）里同一个 Modrinth 项目有四种并存的表达：
//  - `ModrinthMod`（`ModrinthModels.swift`）：搜索接口 `hits` 的元素，带 downloads / slug
//  - `ModrinthProject`（`ModrinthModels.swift`）：`/project/{id}` 的响应，只有 id / title / game_versions / loaders
//  - `LocalModCatalog.Item`（`LocalModCatalog.swift`）：crawl_modrinth.py 生成的全量本地目录条目
//  - `DownloadedItem`（`Models/GameModels.swift`）：分类页网格实际渲染的单元
//
//  本文件把它们收敛为一个值类型。字段只覆盖上述来源中真实存在的字段：
//  某个来源没有的字段一律建模为可选 / 空数组，不做臆测填充。
//

import Foundation

// MARK: - 项目类型

/// Modrinth 的 `project_type` 取值。
///
/// 取值字符串与 `ModrinthSectionType.type(for:)`（分类侧边栏 → project_type 映射）
/// 以及 `LocalModCatalog.Item.projectType` 完全一致，可直接互转。
enum ModProjectType: String, Sendable, Hashable, CaseIterable {
    case mod
    case resourcepack
    case shader
    case modpack

    /// 展示名。取值与 `LocalModCatalog.preTranslateAll` 中的中文分类名保持一致。
    var displayName: String {
        switch self {
        case .mod: return "模组"
        case .resourcepack: return "资源包"
        case .shader: return "光影"
        case .modpack: return "整合包"
        }
    }
}

// MARK: - 项目版本文件

/// 项目版本中的一个可下载文件，对应 `ModrinthVersion.ModrinthFile`。
struct ModProjectFile: Sendable, Hashable {

    /// 下载地址
    let url: String

    /// 文件名（落盘时的建议文件名）
    let filename: String

    /// 是否为该版本的主文件
    let isPrimary: Bool

    /// 文件字节数
    let size: Int

    /// 哈希表，键为算法名（sha1 / sha512），值为十六进制摘要；接口未返回时为空
    let hashes: [String: String]

    /// sha1 摘要，供下载完成后校验
    var sha1: String? { hashes["sha1"] }
}

extension ModProjectFile {
    init(_ file: ModrinthVersion.ModrinthFile) {
        self.init(
            url: file.url,
            filename: file.filename,
            isPrimary: file.primary,
            size: file.size,
            hashes: file.hashes ?? [:]
        )
    }
}

// MARK: - 项目版本

/// 项目版本摘要，对应 `ModrinthVersion`。
///
/// 接口按发布时间降序返回版本列表，本结构保持返回顺序不变，
/// 版本选取（精确匹配 / 主版本前缀匹配）由 `ModInstallUseCase` 负责。
struct ModProjectVersion: Sendable, Hashable, Identifiable {

    let id: String
    let name: String
    let versionNumber: String
    let gameVersions: [String]
    let loaders: [String]
    let files: [ModProjectFile]

    /// 主文件。取值顺序与 `ModDownloader.resolveLatestFile` 一致：优先 `primary`，否则取首个文件。
    var primaryFile: ModProjectFile? {
        files.first(where: { $0.isPrimary }) ?? files.first
    }
}

extension ModProjectVersion {
    init(_ version: ModrinthVersion) {
        self.init(
            id: version.id,
            name: version.name,
            versionNumber: version.version_number,
            gameVersions: version.game_versions,
            loaders: version.loaders,
            files: version.files.map(ModProjectFile.init)
        )
    }
}

// MARK: - 项目

/// 统一的 Modrinth 项目模型。
///
/// 构造入口见下方扩展：不同数据源携带的字段不同，转换结果中缺失字段保持可选 / 空，
/// 调用方需自行判断可得性，不要假定某字段一定有值。
struct ModProject: Sendable, Hashable, Identifiable {

    let id: String

    /// 项目短名，仅搜索接口（`ModrinthMod.slug`）提供
    let slug: String?

    let title: String

    /// 简介，仅搜索接口与本地目录提供
    let description: String?

    let iconURL: String?

    /// 下载量，仅搜索接口与本地目录提供
    let downloads: Int?

    /// 分类标签（`DownloadedItem.tags` / `LocalModCatalog.Item.categories` 同源）
    let categories: [String]

    /// 适用的 Minecraft 版本，仅 `/project/{id}` 接口提供
    let gameVersions: [String]

    /// 适用的加载器名称（`ModLoader.rawValue` 取值），仅 `/project/{id}` 接口提供
    let loaders: [String]

    /// 版本 ID 列表（`ModrinthMod.versions`），仅搜索接口提供
    let versionIDs: [String]

    /// 项目类型，来源未携带时为 nil
    let projectType: ModProjectType?
}

// MARK: - 由既有数据模型转换

extension ModProject {

    /// 由搜索接口的 `hits` 元素（`ModrinthMod`）转换。
    /// `ModrinthMod` 不携带分类，因此 `categories` 为空数组。
    init(_ mod: ModrinthMod, projectType: ModProjectType? = nil) {
        self.init(
            id: mod.id,
            slug: mod.slug,
            title: mod.title,
            description: mod.description,
            iconURL: mod.icon_url,
            downloads: mod.downloads,
            categories: [],
            gameVersions: [],
            loaders: [],
            versionIDs: mod.versions,
            projectType: projectType
        )
    }

    /// 由 `/project/{id}` 响应（`ModrinthProject`）转换。
    /// 该接口不返回简介、图标与下载量，相应字段为空。
    init(_ project: ModrinthProject) {
        self.init(
            id: project.id,
            slug: nil,
            title: project.title ?? project.id,
            description: nil,
            iconURL: nil,
            downloads: nil,
            categories: [],
            gameVersions: project.game_versions ?? [],
            loaders: project.loaders ?? [],
            versionIDs: [],
            projectType: nil
        )
    }

    /// 由全量本地目录条目（`LocalModCatalog.Item`）转换。
    /// 本地目录不含 slug，`versionIDs` 为空数组。
    init(_ item: LocalModCatalog.Item) {
        self.init(
            id: item.projectID,
            slug: nil,
            title: item.title,
            description: item.description,
            iconURL: item.iconURL,
            downloads: item.downloads,
            categories: item.categories,
            gameVersions: [],
            loaders: [],
            versionIDs: [],
            projectType: ModProjectType(rawValue: item.projectType)
        )
    }

    /// 由分类页渲染单元（`DownloadedItem`）转换。
    /// `DownloadedItem` 由搜索或本地目录映射而来，下载量与版本列表已丢失。
    init(_ item: DownloadedItem, projectType: ModProjectType?) {
        self.init(
            id: item.id,
            slug: nil,
            title: item.name,
            description: item.subtitle,
            iconURL: item.iconURL,
            downloads: nil,
            categories: item.tags,
            gameVersions: [],
            loaders: [],
            versionIDs: [],
            projectType: projectType
        )
    }
}
