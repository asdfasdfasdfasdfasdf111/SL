import Foundation

// MARK: - Modrinth 搜索（纯数据获取，自 GameViews 拆出）

enum ModrinthSearcher {
    /// 按类型搜索 Modrinth 项目（mod/resourcepack/shader/modpack）。
    /// - Returns: (items, totalHits)，网络失败或解析失败返回 ([], 0)。
    static func search(
        type: String,
        label: String,
        query: String = "",
        offset: Int = 0,
        limit: Int = 30
    ) async -> (items: [DownloadedItem], totalHits: Int) {
        var components = URLComponents(string: "https://api.modrinth.com/v2/search")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "facets", value: "[[\"project_type:\(type)\"]]")
        ]
        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return ([], 0) }
        var req = URLRequest(url: url)
        req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await AppContext.shared.apiSession.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]] else {
            return ([], 0)
        }
        let totalHits = json["total_hits"] as? Int ?? hits.count
        let items = hits.map { hit in
            let projectId = hit["project_id"] as? String ?? hit["slug"] as? String ?? UUID().uuidString
            let categories = hit["categories"] as? [String] ?? []
            return DownloadedItem(
                id: projectId,
                name: hit["title"] as? String ?? "未知\(label)",
                subtitle: hit["description"] as? String ?? "",
                iconURL: hit["icon_url"] as? String,
                tags: categories
            )
        }
        return (items, totalHits)
    }
}
