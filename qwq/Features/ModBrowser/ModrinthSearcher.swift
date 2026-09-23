import Foundation

// MARK: - Modrinth 搜索（纯数据获取，自 GameViews 拆出）
//
//  ⚠️ 这里直连 **api.modrinth.com**，而 ModpackDownloader 走的是国内镜像
//  mod.mcimirror.top —— 两个模块的网络策略不一致，改动前先确认是否有意为之。
//
//  失败策略是「静默降级」：网络异常、超时、JSON 结构不符**一律返回 ([], 0)**，
//  不抛错、也不区分原因。于是界面上「搜索失败」与「确实没有结果」长得一样。

/// Modrinth 项目搜索（全部静态方法，无状态、无缓存）。
enum ModrinthSearcher {
    /// 按类型搜索 Modrinth 项目（mod/resourcepack/shader/modpack）。
    /// - Parameter type: 项目类型，直接拼进 facets 过滤（`project_type:<type>`）。
    /// - Parameter label: 只用于「名字取不到时的兜底文案」（`未知<label>`），不参与请求。
    /// - Parameter query: 为空则**不附带** `query` 参数 —— 此时是一次「按类型浏览」而非搜索。
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
        // Modrinth 要求带标识性的 User-Agent（URLSession 的默认 UA 会被限流甚至拒绝）。
        req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await AppContext.shared.apiSession.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]] else {
            return ([], 0)
        }
        // `total_hits` 才是本次搜索的总量（用于算分页），`hits.count` 只是本页条数 ——
        // 字段缺失时回落成 hits.count，会让分页因为「总数比实际少」而提前结束。
        let totalHits = json["total_hits"] as? Int ?? hits.count
        let items = hits.map { hit in
            // id 三级兜底：project_id → slug → **随机 UUID**。
            // ⚠️ 最后那级意味着「同一个项目两次搜索会得到不同的 id」——
            // 依赖 id 做去重或列表 identity 的逻辑在这条兜底路径下会失效。
            let projectId = hit["project_id"] as? String ?? hit["slug"] as? String ?? UUID().uuidString
            // 分类标签，供列表页展示与过滤（缺失时是空数组，不是 nil）。
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
