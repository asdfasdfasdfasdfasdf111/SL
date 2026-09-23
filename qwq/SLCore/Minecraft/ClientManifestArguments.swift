//
//  ClientManifestArguments.swift
//  SL启动器
//
//  ClientManifest 的启动参数模型（从 ClientManifest.swift 逐字搬移，逻辑与文案未变）：
//  - Arguments：game / jvm 参数集合与规则过滤（getAllowedGameArguments / getAllowedJVMArguments）
//  - GameArgument（JvmArgument 为其 typealias）/ RuleTag：字符串参数与规则组
//
//  嵌套类型经扩展声明于本文件（同 ClientManifestModels.swift 依据）。
//
//  ── 这套结构在描述什么 ─────────────────────────────────────
//  两代格式混在一起，`Arguments` 就是要同时吃下它们：
//  - **新版**（1.13+）：`arguments.game` / `arguments.jvm` 两个数组，元素**要么是裸字符串**
//    （无条件生效），**要么是 `{rules:…, value:…}` 规则组**（按平台/特性决定是否生效）。
//  - **旧版**（1.12-）：没有 `arguments`，只有一行 `minecraftArguments` 字符串。
//    那条路径由 `ClientManifest.getArguments()` 兜底转换成本类型的对象 —— 注意它是把
//    空格切分后的每个 token 包成 `GameArgument(json: JSON(stringLiteral:))`，
//    所以旧版的 jvm 参数是**硬编码**的一组（G1GC + natives 目录相关 -D 参数）。
//
//  ── 规则的判定入口只有一处 ─────────────────────────────────
//  真正判定「这条参数要不要用」的是 `Rule.check(rules)`（见 `RuleTag.match()`）。
//  `getAllowedGameArguments` / `getAllowedJVMArguments` 只是「先筛、再把 value 摊平」
//  的便捷层，别在这里再叠一层判断 —— 会出两个判定入口（`ClientManifest.getAllowedLibraries`
//  的注释里对同一问题有更详细的说明）。
//

import Foundation
import SwiftyJSON

extension ClientManifest {
    /// 一个版本的完整启动参数集合。
    public class Arguments {
        /// 游戏参数（`` --username `` 这类，注入到 mainClass 之后）。
        public var game: [GameArgument]
        /// JVM 参数（内存、natives 目录、classpath 等，注入到 java 之前/之后由调用方定序）。
        public var jvm: [JvmArgument]

        /// 从新版清单的 `arguments` 字段构造。
        public init(json: JSON) {
            game = json["game"].arrayValue.map { GameArgument(json: $0) }
            jvm = json["jvm"].arrayValue.map { JvmArgument(json: $0) }
        }
        
        /// 直接给定数组构造。**访问级别是 internal**：唯一调用方是同文件属主的
        /// `ClientManifest.getArguments()`（旧版 `minecraftArguments` 兜底路径），
        /// 不对外开放 —— 外部要造参数请走 JSON 入口。
        init(game: [GameArgument], jvm: [JvmArgument]) {
            self.game = game
            self.jvm = jvm
        }
        
        /// 返回本机生效的游戏参数字符串数组（已按 `rules` 筛过、已摊平）。
        public func getAllowedGameArguments() -> [String] {
            let filtered = game.filter { $0.match() }
            var arguments: [String] = []
            for arg in filtered {
                arguments.append(contentsOf: arg.values())
            }
            return arguments
        }
        /// 返回本机生效的 JVM 参数字符串数组。语义与 `getAllowedGameArguments` 完全一致。
        public func getAllowedJVMArguments() -> [String] {
            let filtered = jvm.filter { $0.match() }
            var arguments: [String] = []
            for arg in filtered { arguments.append(contentsOf: arg.values()) }
            return arguments
        }

        /// 单条参数。两种形态二选一：裸字符串，或「规则组 + 值」。
        public class GameArgument {
            /// 裸字符串形态的值。规则组形态下为 `nil`。
            public let string: String?
            /// 规则组。裸字符串形态下为 `nil`。
            public let rules: RuleTag?

            /// 按 JSON 的实际类型分派：是字符串走 `string`，是对象就走 `rules`。
            /// —— 这也意味着**畸形输入**（例如数字）会被当成规则组解析，
            /// 结果是一个 rules 为空、value 为空的组（等价于不生效），不会崩。
            public init(json: JSON) {
                if let str = json.string { string = str; rules = nil }
                else { string = nil; rules = RuleTag(json: json) }
            }
            /// 裸字符串恒为真；规则组走 `Rule.check`。
            public func match() -> Bool { rules?.match() ?? true }
            /// 取值（可能多个）。**任何形态下都不会返回崩溃**，最差是空数组。
            ///
            /// 注意这里**又判了一次** `rules.match()`：调用方（`getAllowed*Arguments`）
            /// 已经先用 `match()` 筛过一遍，这里是防御性重复。两层判定都走同一个
            /// `Rule.check`，所以结果一致、不会互相打架。
            public func values() -> [String] {
                if let string { return [string] }
                if let rules, rules.match() { return rules.value }
                return []
            }
        }

        /// game / jvm 参数结构完全相同（string 或 规则组），共用一类
        public typealias JvmArgument = GameArgument
        
        /// 「规则 + 该规则命中时采用的参数值」。
        ///
        /// `value` 在官方清单里**既可能是字符串也可能是数组**，这里统一归一成数组 ——
        /// 否则调用方每次都要处理两种类型。
        public class RuleTag {
            public let rules: [Rule]
            public let value: [String]
            public init(json: JSON) {
                rules = json["rules"].arrayValue.map { Rule(json: $0) }
                if let str = json["value"].string {
                    value = [str]
                } else if let arr = json["value"].array {
                    // `compactMap`：数组里混进非字符串元素时静默丢弃，而不是整体失败。
                    value = arr.compactMap { $0.string }
                } else {
                    value = []
                }
            }
            /// 与 PCL2 一致：规则组整体按顺序叠加判定（allow 置命中、disallow 置否决）
            public func match() -> Bool {
                Rule.check(rules)
            }
        }
    }
}
