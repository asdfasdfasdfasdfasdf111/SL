//
//  SkinPatchCatalog.swift
//  皮肤补丁（CustomSkinLoader）的取数入口
//
//  为什么不自己写 HTTP：工程里已有 `ModDownloader`，其 `resolveLatestVersion` 实现了
//  多级降级匹配（L1 API 精确过滤 → L2 本地精确 → L3 主版本前缀），且带 HTTP 状态码校验
//  与 sha1 校验。这里只做三件事：**钉住项目 id**、**下发加载器过滤**、**把结果审计一遍**。
//
//  ⚠️ 两个过滤维度缺一不可，且都在这里定死：
//  - **游戏版本**：Modrinth 要的是**纯游戏版本**（`1.21.1`），不是版本 id（`1.21.1-Fabric`）——
//    调用方必须先用 `SkinVersionIdentity.minecraftVersion(from:)` 转换，见 `SkinPatchCoordinator`。
//  - **加载器**：同样必须下发，否则请求退化成「只按游戏版本过滤」。本文件的 `latest` 把
//    `loader` 声明为**非可选**，并额外做一次结果审计（见 `supports`）。
//
//  实测口径（2026-09-24，`api.modrinth.com`，game_versions=["1.21.1"]）：
//    loaders=["fabric"]→12 条 / ["forge"]→14 条 / ["neoforge"]→14 条 / ["quilt"]→11 条 /
//    **不传 loaders→24 条** —— 命中数不同即证明上游确实按加载器筛，不是白传；
//    四者「最新」都落在同一个 `15.0.1-Universal`（loaders = fabric+forge+neoforge+quilt，
//    单文件 `CustomSkinLoader_Universal-15.0.1.jar`），即上游只发 Universal 单包、不做分家包。
//

import Foundation

/// 皮肤补丁（CustomSkinLoader / 万用皮肤补丁）的目录信息。
enum SkinPatchCatalog {

    /// Modrinth 项目 id（`CustomSkinLoader`，作者 xfl03）。
    /// 实测：加载器覆盖 fabric / forge / neoforge / quilt，且提供 **Universal** 单包
    /// （一个 jar 同时支持四种加载器），因此按加载器过滤总能命中同一个文件。
    static let projectID = "idMHQ4n2"

    /// 项目 slug（仅用于日志/排查，取数走 projectID）
    static let slug = "customskinloader"

    /// 英文名（界面与日志用）
    static let displayName = "CustomSkinLoader"

    /// 中文名 —— 社区通用叫法「万用皮肤补丁」，界面上与英文名并列展示，便于用户认出来
    static let chineseName = "万用皮肤补丁"

    /// 一个可安装的补丁版本（只保留界面与下载需要的字段）。
    struct Patch {
        /// 如 `15.0.1-Universal`
        let versionNumber: String
        /// 主文件名，如 `CustomSkinLoader_Universal-15.0.1.jar`
        let filename: String
        /// 该版本声明的游戏版本列表（展示与排查用）
        let gameVersions: [String]
        /// 该版本支持的加载器（`fabric` / `forge` / `neoforge` / `quilt`）
        let loaders: [String]
        /// 该版本**已被核验**支持的目标加载器 —— 由 `latest` 写入、`install` 落盘前复查。
        /// 让「这份补丁是给哪个加载器的」随数据一起走，而不是靠调用方另存一个变量记住。
        let verifiedLoader: ModLoader
        /// 原始版本对象 —— 交给 `ModDownloader.downloadMod` 下载（主文件地址与 sha1 都在里面）
        let version: ModrinthVersion
    }

    /// 查询适配「指定游戏版本 + 加载器」的最新补丁版本。
    ///
    /// ⚠️ `loader` 是**非可选**的（2026-09-24 收严）。这个参数一旦漏传，`resolveLatestVersion`
    /// 会走「只按 game_versions 过滤」那条分支 —— 拿回来的可能是**别的加载器专用的构建**，
    /// 装进当前实例里游戏直接报错。用非可选类型让「漏传加载器」变成**编译错误**，
    /// 而不是一个要靠人记得的约定。
    ///
    /// - Throws: `ModDownloader.ModError.noCompatibleVersion`（没有匹配版本：快照版
    ///   （该补丁只发正式版）、或该加载器没有被覆盖）；以及 `ModError.httpStatus` 等网络错误。
    static func latest(gameVersion: String, loader: ModLoader) async throws -> Patch {
        let version = try await ModDownloader().resolveLatestVersion(
            modId: projectID,
            gameVersion: gameVersion,
            loader: loader
        )
        // 结果审计 —— 不能只信「查询参数传了」就完事。`resolveLatestVersion` 内部有 L1/L2/L3
        // 三级降级，任何一级将来被改坏（或有人放宽过滤），错误的构建就会**静默**流进 mods 目录，
        // 表现为「装上了但游戏起不来」。这里是最后一道闸门：拿到的版本必须**自己声明支持**
        // 目标加载器，否则一律当作「没有可用版本」，让卡片如实告诉用户，而不是赌一把。
        guard supports(version, loader: loader) else {
            throw ModDownloader.ModError.noCompatibleVersion
        }
        // 主文件优先，缺失时退回第一个（与 downloadMod 的取文件口径一致）
        let file = version.files.first(where: { $0.primary }) ?? version.files.first
        return Patch(
            versionNumber: version.version_number,
            filename: file?.filename ?? "",
            gameVersions: version.game_versions,
            loaders: version.loaders,
            verifiedLoader: loader,
            version: version
        )
    }

    /// 把补丁安装到「指定版本」的 mods 目录。
    ///
    /// 落盘前**再核验一次加载器**：`latest` 已审过一遍，但 `install` 是唯一真正往玩家游戏目录里
    /// 写东西的地方 —— 在这一步把闸门关死，代价是一次数组 `contains`，收益是「错误加载器的 jar
    /// 绝不可能落到 mods 里」变成结构性保证，而不是依赖上游那条链路一直没被人改坏。
    ///
    /// ⚠️ 目录口径与 `DownloadFileResolver` / `ModDownloader.autoDownloadMod` 一致：
    /// `<gameRoot>/versions/<版本>/mods` —— 游戏的 `game_directory` 指向
    /// `<gameRoot>/versions/<版本>`，放到游戏根目录**不会被加载**。
    /// - Returns: 落盘后的 jar 路径
    @discardableResult
    static func install(_ patch: Patch, gameRoot: String, versionID: String) async throws -> URL {
        guard supports(patch.version, loader: patch.verifiedLoader) else {
            throw ModDownloader.ModError.noCompatibleVersion
        }
        let modsDir = URL(fileURLWithPath: gameRoot)
            .appendingPathComponent("versions/\(versionID)/mods", isDirectory: true)
        return try await ModDownloader().downloadMod(version: patch.version, destination: modsDir)
    }

    /// 判定一个上游版本是否真的支持目标加载器 —— 即它自己声明的 `loaders` 里有没有这一项。
    ///
    /// 抽成纯函数是为了**可单测**：这是「不把别的加载器专用包装进当前实例」的最后一道闸门，
    /// 它必须有一条测试盯着，不能只靠 `resolveLatestVersion` 内部实现碰巧正确。
    static func supports(_ version: ModrinthVersion, loader: ModLoader) -> Bool {
        version.loaders.contains(loader.rawValue)
    }
}
