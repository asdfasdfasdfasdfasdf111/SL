import Foundation

/// 翻译源竞速获取（Modrinth 详情 / 镜像翻译 / MyMemory 兜底），供 TranslationService 调用。
/// 拆自 TranslationService.swift 私有方法：三个源 + 竞速编排，显式传 session，零共享状态。
enum TranslationSourceFetcher {
    private struct TranslationResponse: Decodable {
        let project_id: String
        let translated: String
        let original: String
        let translated_at: String
    }

    /// 竞速两个翻译源：Modrinth 详情 与 镜像翻译，返回 (Modrinth 结果, 镜像结果)。
    /// 任一源先返回含中文的结果就立即取消另一个，避免被慢/超时的源拖垮整体翻译速度。
    static func raceSources(projectId: String, fallback: String, session: URLSession) async -> (String?, String?) {
        await withTaskGroup(of: (Int, String?).self) { group in
            var modrinth: String?
            var mirror: String?
            group.addTask {
                (0, await fetchModrinthProject(projectId: projectId, fallback: fallback, session: session))
            }
            group.addTask {
                (1, await fetchMirrorTranslation(projectId: projectId, session: session))
            }
            var done = 0
            while let (tag, value) = await group.next(), done < 2 {
                done += 1
                if tag == 0 { modrinth = value } else { mirror = value }
                // 拿到含中文的可用结果 → 取消另一个源，立即采用
                if let value = value, !value.isEmpty, ChineseText.contains(value) {
                    group.cancelAll()
                    break
                }
            }
            return (modrinth, mirror)
        }
    }

    private static func fetchModrinthProject(projectId: String, fallback: String, session: URLSession) async -> String? {
        guard let url = URL(string: "https://api.modrinth.com/v2/project/\(projectId)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8

        guard let (data, response) = try? await session.data(for: req),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let title = json["title"] as? String ?? ""
        let desc = json["description"] as? String ?? ""
        let titleHasChinese = ChineseText.contains(title)
        let descHasChinese = ChineseText.contains(desc)

        // 先用内置表尝试 title 匹配作为名称提示
        if !title.isEmpty, let hint = ProjectTranslationTable.hint(forTitle: title) {
            return hint
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

    private static func fetchMirrorTranslation(projectId: String, session: URLSession) async -> String? {
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
    static func fetchMyMemoryTranslation(text: String, session: URLSession) async -> String? {
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
              !translated.isEmpty, ChineseText.contains(translated) else { return nil }
        return translated
    }
}
