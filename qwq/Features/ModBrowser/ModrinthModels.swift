import Foundation

/// Modrinth API v2 响应模型族（ModDownloader 与翻译/详情页共享）。
/// 按「一个文件一个顶层声明」原则拆自 ModDownloader.swift；纯搬移零行为变更。

public struct ModrinthMod: Identifiable, Codable {
    public let id: String
    public let slug: String
    public let title: String
    public let description: String?
    public let icon_url: String?
    public let downloads: Int
    public let versions: [String]

    public var identifier: String { id }
}

public struct ModrinthProject: Codable {
    public let id: String
    public let title: String?
    public let game_versions: [String]?
    public let loaders: [String]?
}

public struct ModrinthVersion: Codable {
    public let id: String
    public let name: String
    public let version_number: String
    public let game_versions: [String]
    public let loaders: [String]
    public let files: [ModrinthFile]

    public struct ModrinthFile: Codable {
        public let url: String
        public let filename: String
        public let primary: Bool
        public let size: Int
    }
}
