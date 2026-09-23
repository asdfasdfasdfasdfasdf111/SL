//
//  SkinResourcePackBuilder.swift
//  模块化拆分：离线皮肤资源包构建协议与适配实现
//
//  既有实现 `SkinResourcePackApplier`（PCL2 资源包方案）：生成
//  `<gameDir>/resourcepacks/SL 皮肤.zip` 并注入 `options.txt` 的 resourcePacks。
//  该实现需要 `LauncherSettings`（幂等标记 `appliedSkinHash` 写在这里）并会改写 options.txt，
//  因此本协议把「构建」声明为异步，由适配实现在主线程执行。
//

import Foundation

// MARK: - 构建协议

/// 离线皮肤资源包构建。
///
/// 与启动模块的 `GameProcessController` 不同，这里的既有实现形态与协议完全吻合
/// （输入皮肤文件 + 版本 + 游戏目录，输出资源包路径），因此提供适配实现而非空协议。
protocol SkinResourcePackBuilder: Sendable {

    /// 生成离线皮肤资源包。
    /// - Parameters:
    ///   - skinImageURL: 皮肤原图（64×64 / 64×32；Java 版不接受 128×128）
    ///   - minecraftVersion: 目标版本号，用于定位版本 JAR 以决定资源包 pack_format
    ///   - gameDirectory: 版本运行目录（`<gameRoot>/versions/<版本>`，即游戏的 game_directory）。
    /// - Returns: 生成的资源包 zip 路径
    @discardableResult
    func build(skinImageURL: URL, minecraftVersion: String, gameDirectory: URL) async throws -> URL

    /// 移除已生成的资源包，并从 `options.txt` 的 resourcePacks 摘除引用。
    func removeResourcePack(from gameDirectory: URL) async throws
}

// MARK: - 适配实现

/// 适配既有 `SkinResourcePackApplier`，不二次实现打包逻辑。
///
/// 说明：既有实现的幂等判断依赖 `LauncherSettings.appliedSkinHash`，
/// 因此这里传入 `LauncherSettings.shared`，行为与现状一致（同一版本 + 同一皮肤只构建一次）。
/// 该单例与 options.txt 写入都属 UI 进程状态，统一在主线程执行。
struct DefaultSkinResourcePackBuilder: SkinResourcePackBuilder {

    func build(skinImageURL: URL, minecraftVersion: String, gameDirectory: URL) async throws -> URL {
        do {
            try await MainActor.run {
                try SkinResourcePackApplier.apply(
                    skinURL: skinImageURL,
                    toVersion: minecraftVersion,
                    gameDir: gameDirectory,
                    settings: LauncherSettings.shared
                )
            }
        } catch {
            throw SkinError.resourcePackFailed(error.localizedDescription)
        }
        return Self.packURL(in: gameDirectory)
    }

    func removeResourcePack(from gameDirectory: URL) async throws {
        do {
            try await MainActor.run {
                try SkinResourcePackApplier.remove(gameDir: gameDirectory)
            }
        } catch {
            throw SkinError.resourcePackFailed(error.localizedDescription)
        }
    }

    /// 资源包路径。文件名取 `SkinResourcePackApplier.packFileName`，避免两处各写一份字面量。
    static func packURL(in gameDirectory: URL) -> URL {
        gameDirectory
            .appendingPathComponent("resourcepacks", isDirectory: true)
            .appendingPathComponent(SkinResourcePackApplier.packFileName)
    }
}
