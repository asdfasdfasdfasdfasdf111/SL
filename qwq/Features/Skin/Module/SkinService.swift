//
//  SkinService.swift
//  模块化拆分：Skin 模块对外服务协议与默认实现
//
//  上层（皮肤选择面板、启动前注入、头像展示）不再直接调用
//  `MinecraftSkinManager` / `SkinAvatarCropper` / `SkinExtractor` / `SkinResourcePackApplier`，
//  统一经由此协议。
//
//  现状说明：现有的皮肤应用入口 `OfflineSkinService.selectSkinImage(settings:)` 会在
//  流程中弹出 `NSOpenPanel` 并展示 `NSAlert`，属交互职责。本模块**不接管交互**：
//  协议只覆盖「校验 → 落盘 → 生成资源包」这三步数据操作，面板与提示留在 UI 层。
//

import Foundation

// MARK: - 服务协议

/// 皮肤能力的唯一入口。
protocol SkinService: Sendable {

    /// 读取并校验皮肤图像（像素尺寸 + 合法性），不落盘。
    func inspectSkin(at url: URL) throws -> SkinImageInfo

    /// 把皮肤文件保存到持久化目录。
    /// - Parameters:
    ///   - sourceURL: 皮肤源文件
    ///   - uuid: 离线账号 UUID（既有实现按 32 位无连字符小写形式命名文件）
    /// - Returns: 持久化后的文件路径
    func saveSkin(from sourceURL: URL, forUUID uuid: String) throws -> URL

    /// 读取指定 UUID 已持久化的皮肤数据；不存在时返回 nil。
    func skinData(forUUID uuid: String) -> Data?

    /// 生成（并按既有幂等规则复用）离线皮肤资源包。
    @discardableResult
    func applyResourcePack(skinImageURL: URL, minecraftVersion: String, gameDirectory: URL) async throws -> URL

    /// 移除离线皮肤资源包及其在 options.txt 中的引用。
    func removeResourcePack(from gameDirectory: URL) async throws
}

// MARK: - 默认实现

/// 组合解码器、资源包构建器与既有持久化能力，不做二次实现。
///
/// 持久化部分复用 `MinecraftSkinManager`（皮肤写入磁盘，不再塞 UserDefaults）：
/// 其目录约定为 `~/Library/Application Support/SL启动器/Skins/<uuid>.png`。
struct DefaultSkinService: SkinService {

    private let decoder: SkinDecoder
    private let packBuilder: SkinResourcePackBuilder

    init(
        decoder: SkinDecoder = DefaultSkinDecoder(),
        packBuilder: SkinResourcePackBuilder = DefaultSkinResourcePackBuilder()
    ) {
        self.decoder = decoder
        self.packBuilder = packBuilder
    }

    func inspectSkin(at url: URL) throws -> SkinImageInfo {
        guard let data = try? Data(contentsOf: url) else {
            throw SkinError.unreadableImage
        }
        return try decoder.inspect(data)
    }

    func saveSkin(from sourceURL: URL, forUUID uuid: String) throws -> URL {
        try MinecraftSkinManager.shared.saveSkin(sourceURL, forUUID: uuid)
    }

    func skinData(forUUID uuid: String) -> Data? {
        MinecraftSkinManager.shared.getSkinData(forUUID: uuid)
    }

    @discardableResult
    func applyResourcePack(skinImageURL: URL, minecraftVersion: String, gameDirectory: URL) async throws -> URL {
        try await packBuilder.build(
            skinImageURL: skinImageURL,
            minecraftVersion: minecraftVersion,
            gameDirectory: gameDirectory
        )
    }

    func removeResourcePack(from gameDirectory: URL) async throws {
        try await packBuilder.removeResourcePack(from: gameDirectory)
    }
}
