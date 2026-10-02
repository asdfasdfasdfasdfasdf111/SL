//
//  ModpackDownloader.swift
//  整合包（Modrinth 形态）的版本列表 / 文件下载。
//  走国内镜像 mod.mcimirror.top（代理 Modrinth v2 接口），比直连官方更快更稳。
//

import Foundation

/// 整合包的一个具体版本（对应 `/project/{id}/version` 的元素）。
/// `game_versions` 与 `loaders` 是筛选/分组的主要依据；`files` 通常把主文件排在首位
/// —— 本模块的下载逻辑全部取 `files.first`，不区分主文件与附带文件。
public struct ModpackVersion: Codable {
    public let id: String
    public let name: String
    /// 整合包自身的版本号（给人看的，如 `1.2.3`）。
    /// 与 `id` 的区别：id 是稳定标识，本字段只用于展示与外键引用。
    public let version_number: String
    public let game_versions: [String]
    public let loaders: [String]
    public let files: [ModFile]
    
    /// 该版本下的一个文件。
    /// `hashes` 形如 `["sha1": "...", "sha512": "..."]`；本类的下载解析服务
    /// （`resolveFile`）不在此做完整性校验 —— 该校验由下载引擎的 `ValidateSHA1`
    /// 阶段负责。该字段缺失时**跳过校验**，而不是报错。
    public struct ModFile: Codable {
        public let url: String
        public let filename: String
        public let size: Int
        public let hashes: [String: String]?
    }
    
    /// ⚠️ 下面这份 CodingKeys 里的键与属性名**完全一致**，它并没有做任何字段名映射 ——
    /// 上一行「兼容不同字段名」的说法与代码不符，属遗留注释（以代码为准）。
    /// 它实际的作用只是**显式列出参与编解码的键**，避免将来给类型加无关属性时被自动编码进去。
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case version_number
        case game_versions
        case loaders
        case files
    }
}

/// 整合包下载器。无状态（只有镜像地址常量），可以自由创建多个实例。
/// 网络请求统一走 `AppContext.shared.apiSession`（会话级超时与连接复用策略）。
public class ModpackDownloader {
    // 国内镜像站（McIMirror），对国内网络下载更快更稳定
    /// ⚠️ 注意路径里带 `/modrinth/v2`：镜像代理的是 Modrinth **v2** 接口，
    /// 端点路径（`/search`、`/project/...`）与官方一致，换镜像站时只改域名前缀即可。
    /// ⚠️ 本节曾存在的 `search` → `downloadLatest` → `downloadFirst` 三条 public API
    /// 构成互调死链（外部零调用、零测试），2026-10-02 已随判据 C 清理删除。
    private let base = "https://mod.mcimirror.top/modrinth/v2"

    private var session: URLSession { AppContext.shared.apiSession }

    public init() {}
    
    /// 取某整合包的全部版本列表。**不做缓存**：每次调用都会真实发一次请求。
    public func versions(packId: String) async throws -> [ModpackVersion] {
        guard let url = URL(string: "\(base)/project/\(packId)/version") else { throw ModpackError.invalidURL }
        var req = URLRequest(url: url)
        req.setValue(SharedConstants.shared.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode([ModpackVersion].self, from: data)
    }

    /// 解析指定整合包版本的主文件下载地址与文件名（供下载详情页任务使用，不在本方法内下载）。
    /// - Parameter versionId: 用户选中的版本 id（ModpackVersion.id）；找不到时回退到最新版本
    /// ⚠️ 指定的 `versionId` 不存在时，会**静默回退到版本列表的第一项**而不是报错 ——
    /// 调用方从返回值看不出「你要的版本没有，我给了你另一个」。
    public func resolveFile(packId: String, versionId: String) async throws -> (url: URL, filename: String) {
        let versions = try await versions(packId: packId)
        guard let target = versions.first(where: { $0.id == versionId }) ?? versions.first,
              let file = target.files.first,
              let url = URL(string: file.url) else {
            throw ModpackError.noFile
        }
        return (url, file.filename)
    }

    /// 整合包链路的错误。`LocalizedError` 的文案会**直接展示给用户**，
    /// 所以每条都是完整句子，不出现错误码或英文标识。
    public enum ModpackError: Error, LocalizedError {
        case noFile, invalidURL
        public var errorDescription: String? {
            switch self {
            case .noFile: return "整合包版本没有可下载的文件"
            case .invalidURL: return "整合包文件下载地址无效"
            }
        }
    }
}
