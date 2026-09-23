//
//  GameLanguageSetter.swift
//  SL启动器
//
//  ── 本文件职责 ─────────────────────────────────────────────
//  启动游戏前，把 `<版本隔离目录>/options.txt` 里的 `lang:` 写成 `zh_cn`，
//  保证每次启动进游戏都是中文界面。
//
//  ── 为什么需要它 ──────────────────────────────────────────
//  `options.txt` 是游戏自己维护的配置，不写它就跟着上次的残留走；
//  而 1.13+ 的语言标识**必须是小写 `zh_cn`** —— 写成大写 `zh_CN` 会被游戏
//  判为无效值并自动切回英文，症状是「明明设了中文却进游戏变英文」。
//
//  ── 边界与失败策略 ────────────────────────────────────────
//  - 只碰 `lang:` 这一个键，其余内容原样保留。
//  - 读失败（文件不存在/编码异常）按空文件处理；写失败（`try?`）**静默忽略** ——
//    语言设置不是启动的必要条件，不能因为它失败就让整条启动链断掉。
//  - 因此本文件**永远不抛错、也不返回成功与否**，调用方无法得知是否真的写成功。
//
//  ── 调用点 ────────────────────────────────────────────────
//  `Features/Launch/LaunchCoordinator.swift:257`，在正式拉起游戏进程之前。
//

import Foundation

/// 启动前把游戏语言强制设为中文（上游 PCL2 `ModLaunch.vb` 的 lang 逻辑移植）。
/// 写 `{gameDir}/options.txt` 的 lang:zh_cn —— 1.13+ 必须用小写 zh_cn，
/// 大写 zh_CN 反而会被游戏自动切换为英文（见上游版本差异注释）。
enum GameLanguageSetter {
    /// 把 `gameDir` 下 `options.txt` 的 `lang:` 改成 `zh_cn`。
    ///
    /// 三种情况都会得到正确结果：
    /// - 文件已存在且有 `lang:` 行 → 就地替换该行（正则 `lang:[^\n]*` 只吃到行尾，
    ///   不会误伤后面的键）；
    /// - 文件存在但没有 `lang:` 行 → 追加一行（前面补一个换行，避免和原末行粘连）；
    /// - 文件不存在或为空 → 直接写出 `lang:zh_cn\n`（相当于替游戏建档，
    ///   游戏首次启动时会用默认值补齐其余键）。
    ///
    /// `atomically: true` 保证不会写出半截文件 —— 游戏与启动器可能同时读写这个文件。
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