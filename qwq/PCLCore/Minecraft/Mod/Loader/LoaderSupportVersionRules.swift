//
//  LoaderSupportVersionRules.swift
//  PCL.Mac
//
//  加载器候选与版本比较规则（从 LoaderSupportChecker.swift 逐字搬移，规则与常量未变）：
//  - versionAtLeast / isSnapshotVersion：MC 版本号形态与下限比较
//  - candidateDisplayNames：某版本应检测的候选加载器显示名（按版本剔除明确不可能的项）
//  - isFullyResolved：缓存是否已覆盖全部候选（全部定论则无需联网）
//  - orderIndex / displayName(for:)：显示名排序与反查
//

import Foundation

extension LoaderSupportChecker {

    /// 该版本应检测的候选加载器显示名（按 MC 版本剔除明确不可能的项）：
    /// - 快照（`24w14a` 形态）：周号与正式版号之间不存在单调映射（`12w41a` 早于 Fabric 支持的 1.14，
    ///   而 `24w14a` 晚于 1.20），无法用数值下限推断候选 → 沿用既有行为「不推断、不联网」
    /// - 远古版（< 1.0 且非快照，如 2point0_blue / old_alpha / old_beta）无任何加载器 → 不联网检测
    /// - Forge 从 1.1 起；Fabric / Quilt 从 1.14 起；NeoForge 从 1.20.1 起
    public static func candidateDisplayNames(for version: String) -> [String] {
        guard !isSnapshotVersion(version) else { return [] }
        guard versionAtLeast(version, min: "1.0") else { return [] }
        var names: [String] = []
        if versionAtLeast(version, min: "1.1") { names.append("Forge") }
        if versionAtLeast(version, min: "1.14") { names.append("Fabric"); names.append("Quilt") }
        if maySupportNeoForge(version) { names.append("NeoForged") }
        return names
    }

    /// 缓存是否已覆盖全部候选（无 missing / checking / unavailable 项）—— 全部定论则无需联网。
    /// 注意：`.checking` 是 UI 层未定论占位，绝不能视为「已定论」——
    /// 否则首次无缓存时 `fetchLoaderSupport` 会误判全定论并短路 return，卡片永远停在转圈。
    public static func isFullyResolved(_ states: [String: LoaderState], for version: String) -> Bool {
        for name in candidateDisplayNames(for: version) {
            switch states[name] {
            case .supported, .notSupported: continue
            default: return false   // nil / checking / unavailable 均未定论
            }
        }
        return true
    }

    // MARK: - 按 MC 版本剔除明确不可能的候选（减少无谓请求 + 避免误判）

    private static func maySupportNeoForge(_ version: String) -> Bool {
        if version.range(of: #"^\d{2}w\d{2}"#, options: .regularExpression) != nil { return false }
        return versionAtLeast(version, min: "1.20.1")
    }

    /// 访问级别为 internal：缓存层 TTL 规则与探测层的快照结论抑制均需调用。
    static func isSnapshotVersion(_ version: String) -> Bool {
        version.range(of: #"^\d{2}w\d{2}[a-z]?$"#, options: .regularExpression) != nil
    }

    /// 版本号下限比较（`version >= min`）。
    ///
    /// 依据一（优先级）：SemVer 2.0.0 规定预发布版本的优先级低于其对应正式版
    /// （`1.0.0-alpha < 1.0.0`），且主/次/补丁号始终按数值比较。
    /// 官方链接：https://semver.org/
    /// 依据二（形态）：Minecraft Java 版版本 ID 有三类写法——正式版 `1.21` / `1.21.4`、
    /// 预发布与候选版 `1.21-pre1` / `1.21.4-rc1`（启动器内 ID 即 `-preN` / `-rcN`）、
    /// 快照 `24w14a`。来源：Minecraft Wiki「Java Edition version history」
    /// https://minecraft.wiki/w/Java_Edition_version_history
    ///
    /// 本方法只回答「是否达到加载器的支持下限」，而全部下限（1.1 / 1.14 / 1.20.1）都是正式版号，
    /// 故比较对象取版本号基数（主/次/补丁，忽略 `-preN` / `-rcN` 后缀）：
    /// `1.21-pre1` 按 1.21 参与比较——预发布虽低于对应正式版，但高于所有更早的正式版，
    /// 仍落在 1.14 / 1.20.1 之上；`1.20.2-rc1` 按 1.20.2 参与比较，因而 NeoForged 候选不被剔除。
    /// 原实现以 `compactMap` 丢弃无法解析的段，会让 `1.21-pre1` 退化为 `[1]`、低于全部下限，
    /// 候选集变空并导致整个版本被跳过检测。
    static func versionAtLeast(_ version: String, min: String) -> Bool {
        let a = versionBase(version), b = versionBase(min)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// 版本号三向比较（`a < b` 返回负数、相等返回 0、`a > b` 返回正数），供模组版本区间判定使用。
    ///
    /// 与 `versionAtLeast` 共用同一 `versionBase` 解析口径（按版本号基数比较，忽略 `-preN` / `-rcN` 后缀），
    /// 避免再出现第二套解析规则。原调用点 `ModVersionDetector.compareVersions` 走
    /// `GameVersionHelper.compare`，后者以 `compactMap` 丢弃非数字段：`1.21-pre1` 退化为 `[1]`，
    /// 低于 `1.20.1`，使预发布 / 候选版的区间判定与排序错位。
    /// 依据一（形态）：Minecraft Java 版版本 ID 含 `1.21-pre1` / `1.21.4-rc1` 这类写法。
    /// 来源：Minecraft Wiki「Java Edition version history」
    /// https://minecraft.wiki/w/Java_Edition_version_history
    /// 依据二（优先级）：SemVer 2.0.0 —— 预发布版本优先级低于其对应正式版，主/次/补丁号按数值比较。
    /// 官方链接：https://semver.org/
    static func versionCompare(_ a: String, _ b: String) -> Int {
        let pa = versionBase(a), pb = versionBase(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    /// 版本号基数：首段必须整体为数字（否则判定为远古编号，如 a1.2.6 / b1.7.3 / 2point0_blue → 空），
    /// 其后逐段取「前导数字」，遇到不以数字开头的段即停止（`1.21-pre1` → [1, 21]，
    /// `1.20.2-rc1` → [1, 20, 2]）。返回值恒不含空段，保证候选集不会因解析失败而意外变空。
    private static func versionBase(_ version: String) -> [Int] {
        let segments = version.split(separator: ".")
        guard let head = segments.first, head.allSatisfy({ $0.isNumber }), let major = Int(head) else { return [] }
        var base = [major]
        for segment in segments.dropFirst() {
            let digits = segment.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, let value = Int(digits) else { break }
            base.append(value)
        }
        return base
    }

    /// 访问级别为 internal：缓存层与兼容聚合入口的排序均需调用。
    static func orderIndex(_ name: String) -> Int {
        loaderOrder.firstIndex(of: name) ?? 99
    }

    /// 端点 key → 显示名。注意：当前无调用方（`key(for:)` 只提供显示名→key 的正向映射），保留待清理。
    private static func displayName(for key: String) -> String {
        switch key {
        case "fabric": return "Fabric"
        case "forge": return "Forge"
        case "neoforge": return "NeoForged"
        case "quilt": return "Quilt"
        default: return key
        }
    }
}
