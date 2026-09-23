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
        public let hashes: [String: String]?
    }
}

/// 上游（Modrinth 官方 / 国内镜像）返回**非 2xx** 时的错误响应体。
///
/// 为什么需要它：本工程原先所有取数点都写成 `let (data, _) = try await session.data(for: req)`，
/// **HTTP 状态码被 `_` 丢弃**。于是 404 / 429 / 5xx 的错误体被当作成功响应喂给
/// `JSONDecoder().decode(ModrinthProject.self, ...)`，抛出的文案是
/// 「The data couldn't be read because it isn't in the correct format.」——
/// 把「这个资源不存在」误报成「数据格式不正确」，用户与开发者都被引向错误方向。
/// 现在由 `ModDownloader.validate(_:_:)` / `ModpackDownloader.validate(_:_:)` 先校验状态码，
/// 再用本结构取出上游给的说明文字拼进错误文案。
///
/// **两套上游的字段名不同，故两个键都收**（2026-09-23 实测）：
/// - 官方 `api.modrinth.com`：`{"error":"not_found","description":"..."}`
///   ⚠️ 但实测中官方对不存在的项目返回 **404 + 响应体为空**，此时本结构解码失败，
///   调用方退化为「只报状态码」——这是预期路径，不是异常。
/// - 国内镜像 `mod.mcimirror.top`：`{"error":"Not Found","code":404,"detail":"..."}`
///   （键名是 `detail`，没有 `description`）。
public struct ModrinthAPIError: Decodable {
    /// 上游的错误码字符串（官方如 `"not_found"`，镜像如 `"Not Found"`）
    public let error: String?
    /// 人类可读的说明，已把官方 `description` 与镜像 `detail` 归一。
    public let detail: String?
    /// 数字错误码；官方不带此字段，镜像会带。
    public let code: Int?

    private enum CodingKeys: String, CodingKey {
        case error
        case detail
        case code
        /// 官方用的键名。映射进同一个 `detail` 属性，让调用方不必区分上游。
        case description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        code = try c.decodeIfPresent(Int.self, forKey: .code)
        // 官方的 `description` 优先，镜像的 `detail` 兜底；两者都缺则为 nil
        let officialDetail = try c.decodeIfPresent(String.self, forKey: .description)
        let mirrorDetail = try c.decodeIfPresent(String.self, forKey: .detail)
        detail = officialDetail ?? mirrorDetail
    }
}
