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

import Foundation
import SwiftyJSON

extension ClientManifest {
    public class Arguments {
        public var game: [GameArgument]
        public var jvm: [JvmArgument]

        public init(json: JSON) {
            game = json["game"].arrayValue.map { GameArgument(json: $0) }
            jvm = json["jvm"].arrayValue.map { JvmArgument(json: $0) }
        }
        
        init(game: [GameArgument], jvm: [JvmArgument]) {
            self.game = game
            self.jvm = jvm
        }
        
        public func getAllowedGameArguments() -> [String] {
            let filtered = game.filter { $0.match() }
            var arguments: [String] = []
            for arg in filtered {
                arguments.append(contentsOf: arg.values())
            }
            return arguments
        }
        public func getAllowedJVMArguments() -> [String] {
            let filtered = jvm.filter { $0.match() }
            var arguments: [String] = []
            for arg in filtered { arguments.append(contentsOf: arg.values()) }
            return arguments
        }

        public class GameArgument {
            public let string: String?
            public let rules: RuleTag?

            public init(json: JSON) {
                if let str = json.string { string = str; rules = nil }
                else { string = nil; rules = RuleTag(json: json) }
            }
            public func match() -> Bool { rules?.match() ?? true }
            public func values() -> [String] {
                if let string { return [string] }
                if let rules, rules.match() { return rules.value }
                return []
            }
        }

        /// game / jvm 参数结构完全相同（string 或 规则组），共用一类
        public typealias JvmArgument = GameArgument
        
        public class RuleTag {
            public let rules: [Rule]
            public let value: [String]
            public init(json: JSON) {
                rules = json["rules"].arrayValue.map { Rule(json: $0) }
                if let str = json["value"].string {
                    value = [str]
                } else if let arr = json["value"].array {
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
