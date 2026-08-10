//
//  LoaderVersionResolver.swift
//  游戏版本页（loaderSelector）点下载时，解析所选加载器的最新可用版本号。
//  版本来源对标 PCL.Mac LoaderCard.loadVersions：
//    - Fabric:    meta.fabricmc.net/v2/versions/loader/{mc}（优先最新稳定版）
//    - Forge:     bmclapi2.bangbang93.com/forge/minecraft/{mc}
//    - NeoForge:  bmclapi2.bangbang93.com/neoforge/list/{mc}
//    - Quilt:     meta.quiltmc.org/v3/versions/loader/{mc}
//

import Foundation
import SwiftyJSON

enum LoaderVersionResolver {
    /// 获取某 Minecraft 版本所支持加载器的最新版本号（自动选最新；fabric 优先最新稳定版）
    /// - Parameters:
    ///   - loader: 加载器名（不区分大小写：fabric / forge / neoforge / neoforged / quilt）
    ///   - mcVersion: Minecraft 版本号（如 1.20.1）
    static func latestVersion(loader: String, mcVersion: String) async throws -> String {
        let lower = loader.lowercased()
        let encoded = mcVersion.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mcVersion

        switch lower {
        case "fabric":
            let resp = await Requests.get("https://meta.fabricmc.net/v2/versions/loader/\(encoded)")
            let array = try resp.getJSONOrThrow().arrayValue
            // 优先最新稳定版（PCL.Mac 列表排序后用户可选稳定/测试版，这里交互省去选择 → 自动取稳定版）
            if let stable = array.first(where: { $0["loader"]["stable"].boolValue }),
               !stable["loader"]["version"].stringValue.isEmpty {
                return stable["loader"]["version"].stringValue
            }
            guard let first = array.first, !first["loader"]["version"].stringValue.isEmpty else {
                throw MyLocalizedError(reason: "未获取到 Fabric 加载器版本（\(mcVersion) 可能不支持 Fabric）")
            }
            return first["loader"]["version"].stringValue

        case "forge":
            let resp = await Requests.get("https://bmclapi2.bangbang93.com/forge/minecraft/\(encoded)")
            let array = try resp.getJSONOrThrow().arrayValue
            guard let first = array.first, !first["version"].stringValue.isEmpty else {
                throw MyLocalizedError(reason: "未获取到 Forge 加载器版本（\(mcVersion) 可能不支持 Forge）")
            }
            return first["version"].stringValue

        case "neoforge", "neoforged":
            let resp = await Requests.get("https://bmclapi2.bangbang93.com/neoforge/list/\(encoded)")
            let array = try resp.getJSONOrThrow().arrayValue
            guard let first = array.first, !first["version"].stringValue.isEmpty else {
                throw MyLocalizedError(reason: "未获取到 NeoForge 加载器版本（\(mcVersion) 可能不支持 NeoForge）")
            }
            return first["version"].stringValue

        case "quilt":
            let resp = await Requests.get("https://meta.quiltmc.org/v3/versions/loader/\(encoded)")
            let array = try resp.getJSONOrThrow().arrayValue
            if let stable = array.first(where: { $0["loader"]["stable"].boolValue }),
               !stable["loader"]["version"].stringValue.isEmpty {
                return stable["loader"]["version"].stringValue
            }
            guard let first = array.first, !first["loader"]["version"].stringValue.isEmpty else {
                throw MyLocalizedError(reason: "未获取到 Quilt 加载器版本（\(mcVersion) 可能不支持 Quilt）")
            }
            return first["loader"]["version"].stringValue

        default:
            throw MyLocalizedError(reason: "不支持的加载器: \(loader)")
        }
    }
}