import Foundation

/// 启动前把游戏语言强制设为中文（PCL2 ModLaunch.vb 的 lang 逻辑移植）。
/// 写 `{gameDir}/options.txt` 的 lang:zh_cn —— 1.13+ 必须用小写 zh_cn，
/// 大写 zh_CN 反而会被游戏自动切换为英文（见 PCL2 版本差异注释）。
enum GameLanguageSetter {
    static func applyChinese(gameDir: URL) {
        let optionsURL = gameDir.appendingPathComponent("options.txt")
        let content = (try? String(contentsOf: optionsURL, encoding: .utf8)) ?? ""
        let newContent: String
        if let range = content.range(of: "lang:[^\n]*", options: .regularExpression) {
            newContent = content.replacingCharacters(in: range, with: "lang:zh_cn")
        } else {
            newContent = content.isEmpty ? "lang:zh_cn\n" : content + "\nlang:zh_cn\n"
        }
        try? newContent.write(to: optionsURL, atomically: true, encoding: .utf8)
    }
}