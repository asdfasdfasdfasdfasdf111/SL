import Foundation

// MARK: - 常见项目名内置翻译表（快速匹配，避免重复请求）
private let BuiltinProjectTranslation: [String: String] = [
    // slug / project_id -> 中文名称或描述
    "fabric-api": "Fabric API 是 Fabric 工具链提供的轻量级模块化 API，为模组提供通用钩子与兼容方案。",
    "P7dR8mSH": "Fabric API 是 Fabric 工具链提供的轻量级模块化 API，为模组提供通用钩子与兼容方案。",
    "sodium": "钠（Sodium）——现代渲染引擎优化模组，大幅提升游戏帧率。",
    "AANobbMI": "钠（Sodium）——现代渲染引擎优化模组，大幅提升游戏帧率。",
    "iris": "Iris 光影加载器——兼容 Sodium 的现代光影加载器。",
    "YL57xq9U": "Iris 光影加载器——兼容 Sodium 的现代光影加载器。",
    "lithium": "锂（Lithium）——服务端/客户端性能优化模组。",
    "gvQqBUqZ": "锂（Lithium）——服务端/客户端性能优化模组。",
    "phosphor": "磷（Phosphor）——光照引擎优化模组。",
    "hEOCdDgO": "磷（Phosphor）——光照引擎优化模组。",
    "modmenu": "模组菜单——为 Fabric 添加模组列表管理界面。",
    "mOgUt4GM": "模组菜单——为 Fabric 添加模组列表管理界面。",
    "cloth-config": "Cloth Config——通用配置界面库。",
    "9s6osm5g": "Cloth Config——通用配置界面库。",
    "architectury-api": "Architectury API——跨加载器开发兼容层。",
    "lhGA9TYQ": "Architectury API——跨加载器开发兼容层。",
    "create": "机械动力（Create）——围绕建筑与装饰的科技类模组。",
    "LZmaPXh4": "机械动力（Create）——围绕建筑与装饰的科技类模组。",
    "jei": "JEI——物品与配方查看器。",
    "fnYWtaPL": "JEI——物品与配方查看器。",
    "rei": "REI——物品与配方查看器（Roughly Enough Items）。",
    "nfn13Yns": "REI——物品与配方查看器（Roughly Enough Items）。",
    "emi": "EMI——高效物品与配方管理界面。",
    "fRiHVvFU": "EMI——高效物品与配方管理界面。",
    "xmmod": "Xaero 的小地图模组。"
]

// MARK: - 翻译服务（重构：使用 CacheManager + 非阻塞读取）

final class TranslationService {
    static let shared = TranslationService()

    /// 全局翻译并发上限（最多 24 个同时翻译）
    private static let concurrencyLimit = 24
    private static let translationSemaphore = DispatchSemaphore(value: concurrencyLimit)

    private let cache = AppContext.shared.cacheManager
    private let session = AppContext.shared.translateSession
    private let lock = NSLock()
    private var inFlight: Set<String> = []

    private struct TranslationResponse: Decodable {
        let project_id: String
        let translated: String
        let original: String
        let translated_at: String
    }

    private init() {}

    /// 判断字符串是否包含中文字符
    private func containsChinese(_ s: String) -> Bool {
        s.range(of: "\\p{Han}", options: .regularExpression) != nil
    }

    /// 翻译文本（内置表 → 缓存 → 并行[Modrinth API + 镜像翻译] → MyMemory 在线翻译）
    func translateText(text: String, projectId: String) async throws -> String {
        // 1. 若原文已是中文，直接返回
        if !text.isEmpty && containsChinese(text) {
            return text
        }

        // 2. 内置翻译表快速匹配
        if let builtin = BuiltinProjectTranslation[projectId] ?? BuiltinProjectTranslation[projectId.lowercased()] {
            cache.setObject(builtin, forKey: "tr_\(projectId)")
            return builtin
        }

        // 3. 检查缓存 — 只接受含中文的缓存
        if let cached: String = cache.object(String.self, forKey: "tr_\(projectId)") {
            if !cached.isEmpty && containsChinese(cached) {
                return cached
            }
        }

        // 4. 去重
        lock.lock()
        if inFlight.contains(projectId) {
            lock.unlock()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let cached: String = cache.object(String.self, forKey: "tr_\(projectId)") {
                if !cached.isEmpty && containsChinese(cached) { return cached }
            }
            return text
        } else {
            inFlight.insert(projectId)
            lock.unlock()
        }
        defer {
            lock.lock(); inFlight.remove(projectId); lock.unlock()
        }

        // 4a. 全局并发限制（最多 24 个同时翻译）
        Self.translationSemaphore.wait()
        defer { Self.translationSemaphore.signal() }

        // 5. 并行请求 Modrinth 项目详情 + 镜像翻译，减少等待时间
        async let modrinthResult = fetchModrinthProject(projectId: projectId, fallback: text)
        async let mirrorResult = fetchMirrorTranslation(projectId: projectId)

        let (modrinthDesc, mirrorTranslated) = await (modrinthResult, mirrorResult)

        // 5a. Modrinth 返回了中文 → 直接用
        if let result = modrinthDesc, !result.isEmpty, containsChinese(result) {
            cache.setObject(result, forKey: "tr_\(projectId)")
            return result
        }

        // 5b. 镜像翻译返回了中文 → 直接用
        if let result = mirrorTranslated, !result.isEmpty, containsChinese(result) {
            cache.setObject(result, forKey: "tr_\(projectId)")
            return result
        }

        // 5c. Modrinth 返回了英文原文 → 用 MyMemory 在线翻译
        if let englishText = modrinthDesc, !englishText.isEmpty, !containsChinese(englishText) {
            if let translated = await fetchMyMemoryTranslation(text: englishText) {
                cache.setObject(translated, forKey: "tr_\(projectId)")
                return translated
            }
        }

        // 5d. 用输入的原始 text 最后尝试 MyMemory
        if !text.isEmpty, !containsChinese(text) {
            if let translated = await fetchMyMemoryTranslation(text: text) {
                cache.setObject(translated, forKey: "tr_\(projectId)")
                return translated
            }
        }

        return text
    }

    private func fetchModrinthProject(projectId: String, fallback: String) async -> String? {
        guard let url = URL(string: "https://api.modrinth.com/v2/project/\(projectId)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8

        guard let (data, response) = try? await session.data(for: req),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let title = json["title"] as? String ?? ""
        let desc = json["description"] as? String ?? ""
        let titleHasChinese = containsChinese(title)
        let descHasChinese = containsChinese(desc)

        // 先用内置表尝试 title 匹配作为名称提示
        var nameHint = ""
        if !title.isEmpty {
            for (_, value) in BuiltinProjectTranslation {
                if value.contains(title) {
                    nameHint = value
                    break
                }
            }
        }

        if !nameHint.isEmpty {
            return nameHint
        }
        if descHasChinese && !desc.isEmpty {
            return desc
        }
        if titleHasChinese && !title.isEmpty && !desc.isEmpty {
            return "[\(title)] \(desc)"
        }
        if titleHasChinese && !title.isEmpty {
            return title
        }
        return desc.isEmpty ? fallback : desc
    }

    private func fetchMirrorTranslation(projectId: String) async -> String? {
        guard let url = URL(string: "https://mod.mcimirror.top/translate/modrinth?project_id=\(projectId)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8

        guard let (data, response) = try? await session.data(for: req),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let result = try? JSONDecoder().decode(TranslationResponse.self, from: data) else { return nil }
        return result.translated
    }

    /// MyMemory 在线翻译（免费，en→zh-CN，作为最后兜底）
    private func fetchMyMemoryTranslation(text: String) async -> String? {
        let maxLen = 500
        let source = text.count > maxLen ? String(text.prefix(maxLen)) : text
        guard let encoded = source.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.mymemory.translated.net/get?q=\(encoded)&langpair=en|zh-CN") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6

        guard let (data, response) = try? await session.data(for: req),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let respData = json["responseData"] as? [String: Any],
              let translated = respData["translatedText"] as? String,
              !translated.isEmpty, containsChinese(translated) else { return nil }
        return translated
    }

    /// 检查缓存（非阻塞）— 仅返回含中文的缓存
    func cachedTranslation(for projectId: String) -> String? {
        // 先查内置表再查缓存
        if let builtin = BuiltinProjectTranslation[projectId] ?? BuiltinProjectTranslation[projectId.lowercased()] {
            return builtin
        }
        if let cached: String = cache.object(String.self, forKey: "tr_\(projectId)"),
           !cached.isEmpty, containsChinese(cached) {
            return cached
        }
        return nil
    }

    /// 仅查内存缓存（不触碰磁盘），用于全量批量扫描场景，避免海量磁盘 IO
    func cachedTranslationInMemory(for projectId: String) -> String? {
        if let builtin = BuiltinProjectTranslation[projectId] ?? BuiltinProjectTranslation[projectId.lowercased()] {
            return builtin
        }
        if let cached: String = cache.memoryObject(String.self, forKey: "tr_\(projectId)"),
           !cached.isEmpty, containsChinese(cached) {
            return cached
        }
        return nil
    }
}