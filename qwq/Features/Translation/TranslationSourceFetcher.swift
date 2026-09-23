import Foundation

/// 翻译源竞速获取（Modrinth 详情 / 镜像翻译 / MyMemory 兜底），供 TranslationService 调用。
/// 拆自 TranslationService.swift 私有方法：三个源 + 竞速编排，显式传 session，零共享状态。
enum TranslationSourceFetcher {
    /// 镜像翻译接口的响应体。四个字段里实际只用了 `translated` ——
    /// 其余三个是接口固有字段，保留是为了让解码契约完整（少写字段会解码失败）。
    private struct TranslationResponse: Decodable {
        let project_id: String
        let translated: String
        let original: String
        let translated_at: String
    }

    /// 竞速两个翻译源：Modrinth 详情 与 镜像翻译，返回 (Modrinth 结果, 镜像结果)。
    /// 任一源先返回含中文的结果就立即取消另一个，避免被慢/超时的源拖垮整体翻译速度。
    /// 竞速两个翻译源，返回 (Modrinth 结果, 镜像结果)。
    /// **任一源先返回含中文的结果就立即 cancelAll 并采用**，其余不再等 ——
    /// 避免被慢源（或超时源）拖住整体翻译速度。
    /// ⚠️ 元组里两个位置都会填：调用方拿到的可能是「一边有值一边 nil」。
    /// - Parameter fallback: Modrinth 那边 title / description 都为空时的兜底文案。
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
            // `done < 2` 是防止 cancelAll 之后 group 仍继续 yield 已取消任务的结果 ——
            // 最多只处理两个源的结果，处理完就退出循环。
            var done = 0
            while let (tag, value) = await group.next(), done < 2 {
                done += 1
                if tag == 0 { modrinth = value } else { mirror = value }
                // 拿到含中文的可用结果 → 取消另一个源，立即采用
                // 判据是「含中文」而不是「非空」：镜像/接口可能只返回英文原文，
                // 那不算翻译成功，还得继续等另一个源。
                if let value = value, !value.isEmpty, ChineseText.contains(value) {
                    group.cancelAll()
                    break
                }
            }
            return (modrinth, mirror)
        }
    }

    /// 源一：Modrinth 官方项目详情（取 `title` / `description`）。
    /// ⚠️ 严格检查 `statusCode == 200`，非 200 直接返回 nil。
    /// ⚠️ URL 里的 `projectId` **未做百分号编码**；Modrinth 的 id 是固定字符集，暂时安全。
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
        // 优先级：内置译名表 > 中文简介 > 「[标题] 简介」> 中文标题 > 简介原文 / fallback。
        // 逐级回落的目的是尽量给出**含中文**的结果（调用方据此判定成功）。
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

    /// 源二：国内镜像的翻译接口（mod.mcimirror.top，比直连官方快）。
    /// 用 `JSONDecoder` + 上面的 Decodable 解码（而不是 JSONSerialization）——
    /// 因此响应多一个字段、少一个字段都会解码失败并返回 nil。
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

    /// MyMemory 在线翻译（免费，en→zh-CN），第三级兜底。
    /// ⚠️ 会**静默截断输入**：只取前 500 个字符，超出部分直接丢弃（长简介的尾部永远翻不到）。
    /// ⚠️ 输入用 `.urlQueryAllowed` 编码 —— 该字符集包含 `&` 与 `=`，理论上会破坏 query 串；
    /// 当前传入的文本不会出现这两个字符，暂未触发。
    static func fetchMyMemoryTranslation(text: String, session: URLSession) async -> String? {
        // 500 字符是 MyMemory 的免费额度限制；超长输入在这里被截断而不是报错。
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
