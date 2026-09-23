//
//  VersionManifest.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/5/20.
//
//  ── 本文件职责 ─────────────────────────────────────────────
//  版本清单：Mojang 官方那份「游戏有哪些版本、各自类型、各自的清单 URL」的列表，
//  外加一份**官方清单里没有的版本**（愚人节快照等，俗称 unlisted）。
//
//  ── 数据来源与合并方式（`getVersionManifest()`）──────────────
//  1. 主清单从 `DownloadSourceManager.shared.getVersionManifestURL()` 取
//     —— 也就是说**官方源还是镜像源由下载源设置决定**，本文件不关心；
//  2. 再从第三方 alist 镜像取 unlisted 清单；
//  3. unlisted 条目的 `url` 会被**改写**：原本指向 zkitefly.github.io，
//     改写成 alist 镜像地址（`Util.replaceRoot`）。这一步不做的话，
//     点下载这些版本会去访问 GitHub Pages —— 在国内是必失败的；
//  4. 合并后按 `releaseTime` **倒序**重排一次，保证新旧夹杂的 unlisted 条目回到正确位置。
//
//  失败策略：任何一步失败都返回 `nil`（并打日志）。而 unlisted 那一步是
//  `if let ... { }` —— **它失败不影响主清单**，只是少一批冷门版本。
//
//  ── 一个值得知道的性能事实 ─────────────────────────────────
//  `getReleaseDate` 每次调用都要在 `versions` 里**线性扫一遍**（源码里那句
//  「需要缓存」就是作者留下的提示），而它被 `MinecraftVersion.releaseDate` 的懒加载调用，
//  后者又是版本排序的比较依据 —— 排序 N 个版本会触发 O(N log N) 次查找、
//  每次 O(N)。版本总数是数百量级，所以实际是一处**平方级**开销。
//  这也是它必须在 `versions` 内先排好序（而不是每次重排）的原因之一。
//

import Foundation
import SwiftyJSON

/// 版本清单。包含「最新正式版/快照」指针与全部版本条目。
public class VersionManifest: Codable {
    /// 会被 `isAprilFoolVersion` 命中的「已知愚人节版本」白名单。
    /// 名单里的字符串是**小写**形式，比较时调用方会把 id 也转小写。
    /// 官方清单把这些版本标成普通 snapshot，靠类型判不出来，所以只能列名单。
    private static let aprilFoolVersions: [String] = ["15w14a", "1.rv-pre1", "3d shareware v1.34", "20w14infinite", "22w13oneblockatatime", "23w13a_or_b", "24w14potato", "25w14craftmine"]
    /// 「最新正式版 / 最新快照」的版本号，用于界面上那两个快捷入口。
    public let latest: LatestVersions
    /// 全部版本。`fileprivate(set)`：只有本文件能改（合并 unlisted 时要 append/sort）。
    public fileprivate(set) var versions: [GameVersion]
    
    public init(_ json: JSON) {
        self.latest = LatestVersions(json["latest"])
        self.versions = json["versions"].arrayValue.map(GameVersion.init)
    }
    
    /// 清单顶部的 `latest` 字段。
    public struct LatestVersions: Codable {
        public let release: String
        public let snapshot: String
        
        public init(_ json: JSON) {
            self.release = json["release"].stringValue
            self.snapshot = json["snapshot"].stringValue
        }
    }
    
    /// 清单里的一条版本条目。
    ///
    /// 是 `class` 而非 struct：合并 unlisted 清单时要在原地改写 `url`（见 `getVersionManifest`）。
    /// `fileprivate(set)` 保证这种改写只可能发生在本文件内。
    public class GameVersion: Codable, Hashable {
        /// 版本号。**解析时会被规范化**：`" Pre-Release "` 被替换成 `"-pre"`（见 `init`），
        /// 且 `isAprilFoolVersion` 会把 `point` 替换成 `.`（见该方法）。
        /// 也就是说这里存的不一定等于清单原文。
        public fileprivate(set) var id: String
        /// 版本类型。来源有二：清单的 `"type"` 字段，以及下面的愚人节判定（后者优先）。
        public fileprivate(set) var type: VersionType
        /// 该版本自身清单（version json）的 URL。unlisted 条目的这个字段会被改写。
        public fileprivate(set) var url: String
        /// 该版本**入库**时间。
        public let time: Date
        /// 该版本**发布**时间。排序与界面显示都用它。
        public let releaseTime: Date
        
        public init(_ json: JSON) {
            let formatter = ISO8601DateFormatter()
            // 官方的 Pre-Release 版本号写作 "1.21 Pre-Release 1"，这里规范成 "1.21-pre1"，
            // 以便与其他地方（以及美术资源名）统一。
            self.id = json["id"].stringValue.replacingOccurrences(of: " Pre-Release ", with: "-pre")
            // 类型字符串认不出来时回落 .release —— 保守选择：正式版图标一定存在。
            self.type = .init(rawValue: json["type"].stringValue) ?? .release
            self.url = json["url"].stringValue
            // 第三方清单（unlisted 源等）的 time/releaseTime 可能缺失或格式异常，强解包会崩；
            // 失败回退到 distantPast（排序时自然沉底），不中断版本列表加载
            self.time = formatter.date(from: json["time"].stringValue) ?? .distantPast
            self.releaseTime = formatter.date(from: json["releaseTime"].stringValue) ?? .distantPast
            
            // 愚人节判定放在最后，因为它会**覆盖**上面从清单读到的 type
            // （官方把这些版本标成 snapshot，类型字段本身看不出问题）。
            if VersionManifest.isAprilFoolVersion(self) {
                self.type = .aprilFool
            }
        }
        
        /// 转成轻量的 `MinecraftVersion` 标识（把已解析好的 `type` 一并带上，
        /// 避免对方再去反查清单 —— 那正是 `VersionType.parse` 的慢路径）。
        public func parse() -> MinecraftVersion {
            MinecraftVersion(displayName: id, type: type)
        }
        
        /// 按版本号判等 —— 同一个 id 只应出现一条。
        public static func == (lhs: GameVersion, rhs: GameVersion) -> Bool { lhs.id == rhs.id }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }
    
    /// 拉取并合并版本清单。**失败返回 `nil`**（已打日志），调用方负责把
    /// `DataManager.shared.versionManifest` 保持为 nil 并给出「清单不可用」的界面。
    ///
    /// unlisted 那一步用 `if let` 包着，是**有意的容忍**：那个第三方镜像不稳定，
    /// 但它只贡献冷门版本，不该因为它挂掉就让整个版本列表不可用。
    public static func getVersionManifest() async -> VersionManifest? {
        debug("正在获取版本清单")
        do {
            let versions = VersionManifest(try await Requests.get(DownloadSourceManager.shared.getVersionManifestURL()).getJSONOrThrow())
            if let unlistedVersions = await Requests.get("https://alist.8mi.tech/d/mirror/unlisted-versions-of-minecraft/Auto/version_manifest.json").json.map(VersionManifest.init(_:)) {
                for version in unlistedVersions.versions {
                    // 把 zkitefly.github.io 前缀换成 alist 镜像前缀。GitHub Pages 在国内直连
                    // 基本不可用，不改写就等于这批版本「看得见、下不动」。
                    // `replaceRoot` 返回可选 URL，拼不出来时保留原 url（宁可慢也不要丢掉条目）。
                    version.url = Util.replaceRoot(
                        url: version.url,
                        root: "https://zkitefly.github.io/unlisted-versions-of-minecraft",
                        target: "https://alist.8mi.tech/d/mirror/unlisted-versions-of-minecraft/Auto"
                    ).url?.absoluteString ?? version.url
                }
                versions.versions.append(contentsOf: unlistedVersions.versions)
                // 必须重排：unlisted 条目是整批追加到末尾的，不排的话它们会全挤在列表底部。
                versions.versions.sort { $0.releaseTime > $1.releaseTime }
            }
            return versions
        } catch {
            err("无法获取版本清单: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 反查某个版本的发布时间。**线性扫全表，没有缓存**（见文件头的性能说明）。
    ///
    /// 返回 `nil` 的两种情况都会走到：清单还没加载完（此时会打一条 warn），
    /// 或者清单里没有这个版本号（**不打日志**，静默返回 nil）。
    public static func getReleaseDate(_ version: MinecraftVersion) -> Date? {
        if let manifest = DataManager.shared.versionManifest {
            return manifest.versions.first { $0.id == version.displayName }?.releaseTime // 需要缓存
        } else {
            warn("正在获取 \(version.displayName) 的发布日期，但版本清单未初始化完成") // 哦天呐，不会吧哥们
        }
        return nil
    }
    
    /// 判断一个版本是不是「愚人节版本」。
    ///
    /// **注意：本方法会改写传入对象** —— 第一行把 id 里的 `point` 换成 `.`
    /// （官方有 `2.0point0` 这类写法）。所以它虽然长得像个纯判定函数，
    /// 实际是个有副作用的规范化步骤；`GameVersion.init` 正是靠它顺手完成规范化的。
    ///
    /// 判定分两条路：
    /// 1. 命中 `aprilFoolVersions` 白名单（先转小写比较）；
    /// 2. 启发式：**是快照** 且 **不符合标准快照格式 `NNwNNa`** 且 **含字母**
    ///    （筛掉 `1.21` 这类纯数字版本号）且 **不是 `-pre` / `-rc`**。
    ///    最后两条是为了不把正式预发布版误判成愚人节版本。
    public static func isAprilFoolVersion(_ version: GameVersion) -> Bool {
        version.id = version.id.replacingOccurrences(of: "point", with: ".")
        if aprilFoolVersions.contains(version.id.lowercased()) { return true }
        return version.type == .snapshot // 是快照
            && version.id.range(of: #"^[0-9]{2}w[0-9]{2}.{1}$"#, options: .regularExpression) == nil // 且不是标准快照格式 (如 23w33a)
            && version.id.rangeOfCharacter(from: .letters) != nil // 至少有一个字母 (筛掉 1.x 与 1.x.x)
            && !version.id.contains("-pre") && !version.id.contains("-rc") // 不是 Pre Release 或 Release Candidate
    }
    
    /// 给愚人节版本配一句官方宣传语（界面上的彩蛋文案）。
    ///
    /// 与 `aprilFoolVersions` 白名单一样，这里是**硬编码**的：文案是每年一次性的，
    /// 没有可提取的规律。返回值 `""` 表示「认不出来」，调用方应自行决定不显示。
    ///
    /// 注意 `2.0` 那组要处理 `red` / `blue` / `purple` 三个后缀版本
    /// （同一年的愚人节 jeb_ 版），所以先按前缀匹配再按后缀细分。
    public static func getAprilFoolDescription(_ name: String) -> String {
        let name = name.lowercased()
        var tag = ""
        if name.hasPrefix("2.0") || name.hasPrefix("2point0") {
            if name.hasSuffix("red") {
                tag = "（红色版本）"
            } else if name.hasSuffix("blue") {
                tag = "（蓝色版本）"
            } else if name.hasSuffix("purple") {
                tag = "（紫色版本）"
            }
            return "2013 | 这个秘密计划了两年的更新将游戏推向了一个新高度！" + tag
        } else if name == "15w14a" {
            return "2015 | 作为一款全年龄向的游戏，我们需要和平，需要爱与拥抱。"
        } else if name == "1.rv-pre1" {
            return "2016 | 是时候将现代科技带入 Minecraft 了！"
        } else if name == "3d shareware v1.34" {
            return "2019 | 我们从地下室的废墟里找到了这个开发于 1994 年的杰作！"
        } else if name.hasPrefix("20w14inf") || name == "20w14∞" {
            return "2020 | 我们加入了 20 亿个新的维度，让无限的想象变成了现实！"
        } else if name == "22w13oneblockatatime" {
            return "2022 | 一次一个方块更新！迎接全新的挖掘、合成与骑乘玩法吧！"
        } else if name == "23w13a_or_b" {
            return "2023 | 研究表明：玩家喜欢作出选择——越多越好！"
        } else if name == "24w14potato" {
            return "2024 | 毒马铃薯一直都被大家忽视和低估，于是我们超级加强了它！"
        } else if name == "25w14craftmine" {
            return "2025 | 你可以合成任何东西——包括合成你的世界！"
        } else {
            return ""
        }
    }
}
