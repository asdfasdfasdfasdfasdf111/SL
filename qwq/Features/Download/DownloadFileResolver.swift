//
//  DownloadFileResolver.swift
//  模块化拆分：下载目标文件解析（从 ModDetailView.swift 拆出）
//  按页面类型解析 URL/文件名/目标目录/标题；静态方法 + 显式参数，
//  避免后台 Task 隐式捕获视图 struct（@State 指针悬垂 = UAF）
//

import Foundation

enum DownloadFileResolver {

    /// 解析本次下载的目标文件信息（URL/文件名/目标目录/标题），供下载详情页任务使用。
    /// 返回后由 ModFileDownloadTask 负责带进度下载（SingleFileDownloader → NetManager）。
    static func resolve(
        pageType: DetailPageType,
        item: DownloadedItem,
        selectedVersion: String,
        selectedLoader: String,
        selectedModpackVersionId: String,
        settings: LauncherSettings
    ) async throws -> (url: URL, filename: String, destination: URL, title: String) {
        let gameVersion = selectedVersion
        let gameRoot = settings.selectedGameRoot

        guard !gameVersion.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未选择游戏版本"]) }
        guard !gameRoot.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未设置游戏根目录"]) }

        // 内容类型名（用于错误文案）：ModDownloader 是通用下载器，不知道当前页面的类型，
        // 它统一抛「未找到兼容的模组版本」——资源包/光影页把「模组」字样套在资源包/光影上
        // 是明显错误（用户报告「文案都不改一下」）。此处按页面类型改写同类错误。
        let typeName: String
        switch pageType {
        case .mod: typeName = "模组"
        case .shader: typeName = "光影"
        case .resourcePack: typeName = "资源包"
        case .modpack: typeName = "整合包"
        case .loaderSelector: typeName = "内容"
        }

        switch pageType {
        case .mod:
            guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "模组 ID 为空"]) }
            // 游戏启动时 game_directory 指向 <gameRoot>/versions/<version>，
            // mods 必须放在版本文件夹内才会被游戏加载
            let modsDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("versions/\(gameVersion)/mods")
            try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
            let loader: ModLoader
            switch selectedLoader.lowercased() {
            case "fabric": loader = .fabric
            case "forge": loader = .forge
            case "neoforge", "neoforged": loader = .neoforge
            case "quilt": loader = .quilt
            default: loader = .fabric
            }
            do {
                let (url, filename) = try await ModDownloader().resolveLatestFile(modId: item.id, gameVersion: gameVersion, loader: loader)
                return (url, filename, modsDir, item.name)
            } catch ModDownloader.ModError.noCompatibleVersion {
                throw Self.noCompatibleError(typeName: typeName)
            }

        case .shader:
            guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "光影 ID 为空"]) }
            // 光影放在版本文件夹的 shaderpacks（游戏 gameDir = versions/<version>）
            let shaderDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("versions/\(gameVersion)/shaderpacks")
            try FileManager.default.createDirectory(at: shaderDir, withIntermediateDirectories: true)
            // 光影项目版本的 loaders 字段通常是 ["minecraft"] 或空，不能按 fabric 模组过滤
            do {
                let (url, filename) = try await ModDownloader().resolveLatestFile(modId: item.id, gameVersion: gameVersion)
                return (url, filename, shaderDir, item.name)
            } catch ModDownloader.ModError.noCompatibleVersion {
                throw Self.noCompatibleError(typeName: typeName)
            }

        case .resourcePack:
            guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "资源包 ID 为空"]) }
            // 资源包放在版本文件夹的 resourcepacks（游戏 gameDir = versions/<version>）
            let resourcePackDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("versions/\(gameVersion)/resourcepacks")
            try FileManager.default.createDirectory(at: resourcePackDir, withIntermediateDirectories: true)
            // 资源包项目版本的 loaders 字段通常是 ["minecraft"] 或空，不能按 fabric 模组过滤
            do {
                let (url, filename) = try await ModDownloader().resolveLatestFile(modId: item.id, gameVersion: gameVersion)
                return (url, filename, resourcePackDir, item.name)
            } catch ModDownloader.ModError.noCompatibleVersion {
                throw Self.noCompatibleError(typeName: typeName)
            }

        case .modpack:
            guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "整合包 ID 为空"]) }
            guard !selectedModpackVersionId.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未选择整合包版本"]) }
            // 整合包下载到版本目录
            let versionDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("versions/\(selectedModpackVersionId)")
            try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
            do {
                let (url, filename) = try await ModpackDownloader().resolveFile(packId: item.id, versionId: selectedModpackVersionId)
                return (url, filename, versionDir, item.name)
            } catch {
                // 整合包解析失败：错误已带类型化文案（ModpackError），不做二次改写。
                throw error
            }

        case .loaderSelector:
            // 兜底：正常流程已在 startDownload() 提前走 startGameVersionDownload()，不会走到这里
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "游戏版本下载请使用右下角下载按钮"])
        }
    }

    /// 无兼容版本错误的类型化文案。此前 ModDownloader 统一报「未找到兼容的模组版本」，
    /// 对资源包/光影/整合包是张冠李戴（用户报告）；按页面类型给出「未找到兼容的<类型>版本」。
    private static func noCompatibleError(typeName: String) -> NSError {
        NSError(domain: "DownloadFileResolver", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "未找到兼容的\(typeName)版本（可尝试其他版本，或选择受支持版本）"])
    }
}
