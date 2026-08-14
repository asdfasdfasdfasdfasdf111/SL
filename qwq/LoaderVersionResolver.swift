//
//  LoaderVersionResolver.swift
//  游戏版本页（loaderSelector）点下载时，解析所选加载器的最新可用版本号。
//  版本来源对标 PCL.Mac LoaderCard.loadVersions：
//    - Fabric:    meta.fabricmc.net/v2/versions/loader/{mc}（优先最新稳定版）
//    - Forge:     bmclapi2.bangbang93.com/forge/minecraft/{mc}，网络失败回退官方 index_{mc}.json
//    - NeoForge:  bmclapi2.bangbang93.com/neoforge/list/{mc}，网络失败回退官方 Maven metadata.xml
//    - Quilt:     meta.quiltmc.org/v3/versions/loader/{mc}
//  双源语义：请求成功但结果为空 = 「明确不支持」立即抛错（镜像与官方结论一致，不重复请求）；
//  仅当网络失败（error != nil）才切到官方兜底源，避免国内直连官方不稳导致下载解析失败。
//

import Foundation
import SwiftyJSON

enum LoaderVersionResolver {
    /// 获取某 Minecraft 版本所支持加载器的最新版本号（自动选最新；fabric/quilt 优先最新稳定版）
    /// - Parameters:
    ///   - loader: 加载器名（不区分大小写：fabric / forge / neoforge / neoforged / quilt）
    ///   - mcVersion: Minecraft 版本号（如 1.20.1）
    static func latestVersion(loader: String, mcVersion: String) async throws -> String {
        let lower = loader.lowercased()
        let encoded = mcVersion.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mcVersion

        switch lower {
        case "fabric":
            return try await fabricVersion(encoded: encoded, mcVersion: mcVersion)

        case "forge":
            return try await forgeVersion(encoded: encoded, mcVersion: mcVersion)

        case "neoforge", "neoforged":
            return try await neoforgeVersion(encoded: encoded, mcVersion: mcVersion)

        case "quilt":
            return try await quiltVersion(encoded: encoded, mcVersion: mcVersion)

        default:
            throw MyLocalizedError(reason: "不支持的加载器: \(loader)")
        }
    }

    // MARK: - 各加载器解析

    private static func fabricVersion(encoded: String, mcVersion: String) async throws -> String {
        // 复用加载器支持检测阶段的响应数组（同会话免二次请求；检测与解析共用同一端点）
        if let data = LoaderSupportChecker.cachedVersionList(loader: "fabric", mc: mcVersion),
           let json = try? JSON(data: data) {
            let array = json.arrayValue
            if let stable = array.first(where: { $0["loader"]["stable"].boolValue }),
               !stable["loader"]["version"].stringValue.isEmpty {
                return stable["loader"]["version"].stringValue
            }
            if let first = array.first, !first["loader"]["version"].stringValue.isEmpty {
                return first["loader"]["version"].stringValue
            }
        }
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
    }

    private static func quiltVersion(encoded: String, mcVersion: String) async throws -> String {
        // 复用加载器支持检测阶段的响应数组（检测与解析共用同一端点，同会话免二次请求）
        if let data = LoaderSupportChecker.cachedVersionList(loader: "quilt", mc: mcVersion),
           let json = try? JSON(data: data) {
            let array = json.arrayValue
            if let stable = array.first(where: { $0["loader"]["stable"].boolValue }),
               !stable["loader"]["version"].stringValue.isEmpty {
                return stable["loader"]["version"].stringValue
            }
            if let first = array.first, !first["loader"]["version"].stringValue.isEmpty {
                return first["loader"]["version"].stringValue
            }
        }
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
    }

    /// Forge：BMCLAPI 数组主源；请求成功但空数组 = 明确不支持；仅网络失败切入官方 index JSON（promos）
    private static func forgeVersion(encoded: String, mcVersion: String) async throws -> String {
        // 复用加载器支持检测阶段的响应数组（同会话免二次请求）
        if let data = LoaderSupportChecker.cachedVersionList(loader: "forge", mc: mcVersion),
           let json = try? JSON(data: data) {
            let array = json.arrayValue
            if let first = array.first, !first["version"].stringValue.isEmpty {
                return first["version"].stringValue
            }
        }
        let primary = await Requests.get("https://bmclapi2.bangbang93.com/forge/minecraft/\(encoded)")
        if primary.error == nil, let data = primary.data, !data.isEmpty, let json = try? JSON(data: data) {
            let array = json.arrayValue
            if let first = array.first, !first["version"].stringValue.isEmpty {
                return first["version"].stringValue
            }
            throw MyLocalizedError(reason: "未获取到 Forge 加载器版本（\(mcVersion) 可能不支持 Forge）")
        }
        // 主源网络失败 → 官方 files.minecraftforge.net 索引兜底（重试 1 次）
        let fallback = await Requests.get(
            "https://files.minecraftforge.net/net/minecraftforge/forge/index_\(encoded).json"
        )
        if let data = fallback.data, !data.isEmpty, let json = try? JSON(data: data) {
            if let recommended = json["promos"]["\(mcVersion)-recommended"].string, !recommended.isEmpty {
                return recommended
            }
            if let latest = json["promos"]["\(mcVersion)-latest"].string, !latest.isEmpty {
                return latest
            }
            throw MyLocalizedError(reason: "未获取到 Forge 加载器版本（\(mcVersion)）")
        }
        throw MyLocalizedError(reason: "网络异常，未能获取 Forge 加载器版本（\(mcVersion)），请重试")
    }

    /// NeoForge：BMCLAPI list 主源；仅网络失败切入官方 Maven metadata.xml（按 MC→版本前缀过滤取最新）
    private static func neoforgeVersion(encoded: String, mcVersion: String) async throws -> String {
        // 复用加载器支持检测阶段的响应数组（同会话免二次请求）
        if let data = LoaderSupportChecker.cachedVersionList(loader: "neoforge", mc: mcVersion),
           let json = try? JSON(data: data) {
            let array = json.arrayValue
            if let first = array.first, !first["version"].stringValue.isEmpty {
                return first["version"].stringValue
            }
        }
        let primary = await Requests.get("https://bmclapi2.bangbang93.com/neoforge/list/\(encoded)")
        if primary.error == nil, let data = primary.data, !data.isEmpty, let json = try? JSON(data: data) {
            let array = json.arrayValue
            if let first = array.first, !first["version"].stringValue.isEmpty {
                return first["version"].stringValue
            }
            throw MyLocalizedError(reason: "未获取到 NeoForge 加载器版本（\(mcVersion) 可能不支持 NeoForge）")
        }
        // 官方 Maven metadata XML 兜底：<version>20.1.0-beta</version> 按前缀过滤，取最后一个（最新）
        let fallback = await Requests.get("https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml")
        if let data = fallback.data, let xml = String(data: data, encoding: .utf8) {
            let prefix = neoforgePrefix(for: mcVersion)
            let pattern = "<version>\(NSRegularExpression.escapedPattern(for: prefix))[^<]*</version>"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
                let versions = regex.matches(in: xml, range: range).compactMap { m -> String? in
                    guard let r = Range(m.range(at: 0), in: xml) else { return nil }
                    return String(xml[r]).replacingOccurrences(of: "<version>", with: "")
                        .replacingOccurrences(of: "</version>", with: "")
                }
                if let latest = versions.last, !latest.isEmpty {
                    return latest
                }
            }
            throw MyLocalizedError(reason: "未获取到 NeoForge 加载器版本（\(mcVersion)）")
        }
        throw MyLocalizedError(reason: "网络异常，未能获取 NeoForge 加载器版本（\(mcVersion)），请重试")
    }

    /// MC 版本 → NeoForge 版本前缀（官方 Maven 布局：1.20.1→20.1，1.21→21.0，1.21.4→21.4）。
    /// NeoForge 未覆盖的版本（如 1.20.3）无匹配项，自然返回「未获取到」，行为正确。
    private static func neoforgePrefix(for mc: String) -> String {
        let parts = mc.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2, parts[0] == 1 else { return "20." }
        let year = parts[1]  // 1.20.x → 20，1.21.x → 21
        if parts.count >= 3 { return "\(year).\(parts[2])" }
        return "\(year).0"
    }
}