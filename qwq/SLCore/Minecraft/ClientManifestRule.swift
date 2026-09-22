//
//  ClientManifestRule.swift
//  SL启动器
//
//  ClientManifest 的清单规则模型（从 ClientManifest.swift 逐字搬移，逻辑与文案未变）：
//  - Rule：allow / disallow 顺序叠加判定（Rule.check）
//  - OSRule：系统名匹配（当前仅 osx / unknown）
//  - Features：demo 用户、自定义分辨率、快速游玩等特性开关
//
//  嵌套类型经扩展声明于本文件（同 ClientManifestModels.swift 依据）。
//

import Foundation
import SwiftyJSON

extension ClientManifest {
    public class Rule {
        public let action: String
        public let os: OSRule?
        public let features: Features?
        public init(json: JSON) {
            action = json["action"].stringValue
            os = json["os"].exists() ? OSRule(json: json["os"]) : nil
            features = json["features"].exists() ? Features(json: json["features"]) : nil
        }
        /// 单条规则「条件是否匹配」（不含 action 判断，与 PCL2 McJsonRuleCheck 单条 IsRightRule 对应）
        public func conditionsMatch() -> Bool {
            (os?.match() ?? true) && (features?.match() ?? true)
        }
        /// PCL2 McJsonRuleCheck 顺序叠加语义：逐条规则处理——
        /// allow 且条件匹配 → 命中；disallow 且条件匹配 → 否决；后续规则覆盖先前的结论。
        /// 注意：不能写成 allSatisfy（那会把含 disallow 规则的库无条件排除，
        /// 例如 disallow: windows 的库在 macOS 上本应保留，allSatisfy 会误删导致缺库）。
        public static func check(_ rules: [Rule]) -> Bool {
            guard !rules.isEmpty else { return true }
            var required = false
            for rule in rules {
                if rule.action == "allow" {
                    if rule.conditionsMatch() { required = true }
                } else {
                    if rule.conditionsMatch() { required = false }
                }
            }
            return required
        }
        public class OSRule {
            public let name: String?
            public let arch: String?
            public init(json: JSON) {
                name = json["name"].string
                arch = json["arch"].string
            }
            public func match() -> Bool {
                // 当前系统 macOS（osx）。与 PCL2 只在 Windows 上匹配 "windows" 同理，
                // 本启动器只匹配 osx；"unknown" 视为通用（无系统限制）。
                if let name {
                    if name == "unknown" { return true }
                    if name != "osx" { return false }
                }
                // TODO: 处理 arch（官方 macOS JSON 基本不含 arch 规则，风险低）
                return true
            }
        }
        
        public class Features {
            public let isDemoUser: Bool?
            public let hasCustomResolution: Bool?
            public let hasQuickPlaysSupport: Bool?
            public let isQuickPlaySingleplayer: Bool?
            public let isQuickPlayMultiplayer: Bool?
            public let isQuickPlayRealms: Bool?
            public init(json: JSON) {
                isDemoUser = json["is_demo_user"].bool
                hasCustomResolution = json["has_custom_resolution"].bool
                hasQuickPlaysSupport = json["has_quick_plays_support"].bool
                isQuickPlaySingleplayer = json["is_quick_play_singleplayer"].bool
                isQuickPlayMultiplayer = json["is_quick_play_multiplayer"].bool
                isQuickPlayRealms = json["is_quick_play_realms"].bool
            }
            public func match() -> Bool {
                if isDemoUser == true { return false }
                if hasCustomResolution == true { return false }
                if hasQuickPlaysSupport == true { return false }
                if isQuickPlaySingleplayer == true { return false }
                if isQuickPlayMultiplayer == true { return false }
                if isQuickPlayRealms == true { return false }
                return true
            }
        }
    }
}
