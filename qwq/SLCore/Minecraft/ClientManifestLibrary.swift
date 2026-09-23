//
//  ClientManifestLibrary.swift
//  SL启动器
//
//  ClientManifest 的依赖库模型（从 ClientManifest.swift 逐字搬移，逻辑与文案未变）：
//  - Library：maven 坐标解析、osx natives 分类器选取与 Hashable 去重键
//
//  嵌套类型经扩展声明于本文件（同 ClientManifestModels.swift 依据）。
//
//  ── 关键点：`name` 是可变的，坐标各段是它的派生视图 ─────────────
//  `name` 带 `didSet`，一改就把 `split` 重建；`groupId` / `artifactId` / `version` /
//  `classifier` 都从 `split` 现切。这样 `ArtifactVersionMapper` 只写 `name` 一处，
//  其余字段自动跟着变 —— 反过来说，**不要直接改那些派生字段**（它们是只读的，改不了）。
//
//  ── `init?` 的三条分支（对应官方清单的三种历史形态）───────────
//  1. **没有 `downloads` 字段**（很老的清单）：只有 `name` + 一个来源基址 `url`，
//     按 maven 坐标拼出路径挂上去。基址缺失时硬编码回落到 BMCLAPI 镜像 ——
//     这是唯一一处「默认走镜像」的兜底。
//  2. **`launchwrapper`**（1.6 之前的老加载器）：官方清单里它的地址不可用，
//     这里硬编码改指 `libraries.minecraft.net`。
//  3. **常规情况**：先看 `natives` 里有没有 `osx` 分类器 —— 有就从
//     `downloads.classifiers[<该分类器>]` 取 macOS 专用的 natives 包，
//     并把 `isNativeLibrary` 置真；否则退回 `downloads.artifact`。
//
//  ── 判等/哈希只认 `name` ───────────────────────────────────
//  `==` 与 `hash` 都只比 `name`（完整 maven 坐标）。所以 `Set<Library>` 是「按坐标去重」，
//  但注意 `ClientManifest.deduplicateLibraries` 用的其实是下面另建的 `HashableLibrary`
//  （按 groupId+artifactId+classifier 去重、忽略版本），两者粒度不同，别混。
//

import Foundation
import SwiftyJSON

extension ClientManifest {
    /// 清单里的一条依赖库。
    ///
    /// 注意这是 **class**（引用类型）：`ArtifactVersionMapper` 依赖这一点做就地改写，
    /// 且 `getNeededNatives()` 能拿它当字典 key（哈希取 `name`）。
    public class Library: Hashable {
        /// 完整 maven 坐标，形如 `org.lwjgl:lwjgl:3.3.3:natives-macos-arm64`。
        /// **唯一的可变字段** —— 改它会自动重建下面所有派生字段。
        public var name: String {
            didSet {
                split = name.split(separator: ":").map(String.init)
            }
        }
        /// `name` 按 `:` 切开的缓存。避免每次读 groupId 都重新切一遍字符串。
        private var split: [String]
        /// 以下四个都是 `split` 的派生视图。
        /// 段数不足时返回空串 / nil 而不是越界崩溃 —— 这是修过的缺陷：
        /// 旧实现直接 `split[0]/[1]/[2]`，遇到畸形坐标（非官方源损坏清单）会崩。
        public var groupId: String { split.count >= 1 ? split[0] : "" }
        public var artifactId: String { split.count >= 2 ? split[1] : "" }
        public var version: String { split.count >= 3 ? split[2] : "" }
        /// 第 4 段，即 natives 分类器；常规库没有这一段。
        public var classifier: String? { split.count >= 4 ? split[3] : nil }
        /// 生效规则（`allow` / `disallow`）。**在清单解析期就已按它筛过一遍**
        /// （`ClientManifest.init(json:)` 的 `Rule.check`），这里保留原文只是为了后续判定。
        public let rules: [Rule]
        /// natives 映射表，形如 `["osx": "natives-macos", "windows": "natives-windows"]`。
        /// 启动器只关心 `"osx"` 这一项。
        public let natives: [String: String]
        /// 本库该下载的东西。`nil` 表示清单里没给下载信息（例如纯父级引用占位）。
        public let artifact: DownloadInfo?
        /// 是否 macOS natives 包（决定它进 classpath 还是进解压流程）。
        public let isNativeLibrary: Bool

        /// 解析一条库条目。**返回 nil 的唯一条件是坐标切不出任何段**（`name` 为空）。
        ///
        /// 三条分支的说明见文件头。注意分支 1 与分支 2 都在内部
        /// `return`/落到末尾把 `isNativeLibrary` 置假，只有分支 3 命中 osx 分类器时才为真。
        public init?(json: JSON) {
            self.name = json["name"].stringValue
            self.split = name.split(separator: ":").map(String.init)
            if split.isEmpty {
                return nil
            }
            
            if !json["downloads"].exists() {
                // 老清单形态：没有 downloads，只有 name + 一个来源基址。
                self.rules = []
                self.natives = [:]
                let path = Util.toPath(mavenCoordinate: name)
                self.artifact = DownloadInfo(
                    path: path,
                    url: (URL(string: json["url"].stringValue) ?? URL(string: "https://bmclapi2.bangbang93.com/maven")!).appendingPathComponent(path).absoluteString
                )
            } else {
                if split.count >= 2 && split[1] == "launchwrapper" {
                    // launchwrapper 是加载器而非游戏依赖，官方清单里的地址不可用，硬指到官方库仓库。
                    self.rules = []
                    self.natives = [:]
                    let path = Util.toPath(mavenCoordinate: name)
                    self.artifact = DownloadInfo(path: path, url: URL(string: "https://libraries.minecraft.net")!.appendingPathComponent(path).absoluteString)
                } else {
                    self.rules = json["rules"].arrayValue.map { Rule(json: $0) }
                    self.natives = json["natives"].dictionaryObject as? [String: String] ?? [:]
                    
                    // macOS natives 的选取：清单用「逻辑名 → 分类器」的映射描述，
                    // 我们要的是 natives["osx"] 对应的那一份。
                    // 命中即提前 return（isNativeLibrary = true，不再走下面的赋值）。
                    if let classifiers = json["downloads"]["classifiers"].dictionary,
                       let key = natives["osx"],
                       let json = classifiers[key] {
                        self.artifact = DownloadInfo(json: json)
                        self.isNativeLibrary = true
                        return
                    } else {
                        self.artifact = json["downloads"]["artifact"].exists() ? DownloadInfo(json: json["downloads"]["artifact"]) : nil
                    }
                }
            }
            
            self.isNativeLibrary = false
        }
        
        /// 按完整坐标判等 —— 见文件头「判等/哈希只认 name」。
        public static func == (lhs: Library, rhs: Library) -> Bool { lhs.name == rhs.name }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
        }
    }
}
