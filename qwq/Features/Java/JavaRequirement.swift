import Foundation

/// Java 版本需求描述。
///
/// 调用方只需声明"要什么"，不再关心去哪套数据源找；
/// 具体选取由 `JavaResolver` 完成。
struct JavaRequirement: Sendable {

    /// 最低可接受的主版本号，不满足即视为不可用于本次启动。
    let minimumMajor: Int

    /// 期望的主版本号（可选）。存在满足该版本的 Java 时优先采用，否则退化为"取最高可用版本"。
    let preferredMajor: Int?

    /// 关联的 Minecraft 版本号（如 "1.20.1"、快照如 "24w14a"），仅用于追溯与日志，不参与选取。
    let mcVersion: String?

    /// 需求来源备注（如 "manifest.javaVersion=21"、"用户手动指定"）。
    let remarks: String?

    init(minimumMajor: Int, preferredMajor: Int? = nil, mcVersion: String? = nil, remarks: String? = nil) {
        self.minimumMajor = minimumMajor
        self.preferredMajor = preferredMajor
        self.mcVersion = mcVersion
        self.remarks = remarks
    }
}

// MARK: - 由 Minecraft 版本推导

extension JavaRequirement {

    /// 通用兜底：Java 8，覆盖 1.16.5 及更早版本。
    static let fallbackMinimumMajor = 8

    /// 由 Minecraft 版本号推导需求。
    /// - Parameter mcVersion: 形如 "1.20.1" 的正式版，或 "24w14a" 形式的快照；无法解析时按 Java 8 处理。
    init(mcVersion: String, preferredMajor: Int? = nil, remarks: String? = nil) {
        self.init(
            minimumMajor: Self.minimumMajor(forMinecraftVersion: mcVersion),
            preferredMajor: preferredMajor,
            mcVersion: mcVersion,
            remarks: remarks
        )
    }

    /// 优先采用 manifest 声明，其次按版本号推断。
    /// 与现有 `MinecraftInstance.resolveMinJavaVersion` 的取值顺序一致，便于后续替换启动流程中的等价逻辑。
    /// - Parameter manifestJavaVersion: client manifest 的 `javaVersion`，未声明或 <= 0 时忽略。
    init(manifestJavaVersion: Int?, mcVersion: String? = nil, preferredMajor: Int? = nil, remarks: String? = nil) {
        let derived: Int
        if let manifestJavaVersion, manifestJavaVersion > 0 {
            derived = manifestJavaVersion
        } else if let mcVersion {
            derived = Self.minimumMajor(forMinecraftVersion: mcVersion)
        } else {
            derived = Self.fallbackMinimumMajor
        }
        self.init(minimumMajor: derived, preferredMajor: preferredMajor, mcVersion: mcVersion, remarks: remarks)
    }

    /// Minecraft 版本 -> 最低 Java 主版本。
    ///
    /// 规则（与 Mojang 官方要求对齐）：
    /// - 1.16.5 及更早：Java 8
    /// - 1.17.x：Java 16
    /// - 1.18 ~ 1.20.4：Java 17
    /// - 1.20.5 及之后（含 1.21+）：Java 21
    /// - 快照：按 (年份, 周序号) 近似映射到对应正式版，无法识别时取 Java 17
    static func minimumMajor(forMinecraftVersion version: String) -> Int {
        if let snapshotMajor = snapshotMinimumMajor(version) {
            return snapshotMajor
        }
        let components = numericComponents(of: version)
        guard let major = components.first else { return fallbackMinimumMajor }

        // 未来版本号方案（去掉 1. 前缀）：保守按 Java 21 处理
        guard major == 1, components.count > 1 else { return 21 }

        let minor = components[1]
        let patch = components.count > 2 ? components[2] : 0

        switch minor {
        case ..<17:
            return fallbackMinimumMajor
        case 17:
            return 16
        case 18...20:
            // 1.20.5 起提高到 Java 21
            return (minor == 20 && patch >= 5) ? 21 : 17
        default:
            return 21
        }
    }

    /// 提取版本号的纯数字前缀，"1.20.1" -> [1, 20, 1]；"1.20.1-rc1" -> [1, 20, 1]。
    private static func numericComponents(of version: String) -> [Int] {
        let cleaned = version.trimmingCharacters(in: .whitespacesAndNewlines)
        var components: [Int] = []
        for part in cleaned.split(separator: ".") {
            guard let value = Int(part.prefix { $0.isNumber }) else { break }
            components.append(value)
        }
        return components
    }

    /// 快照版的最低 Java 要求。识别形如 `24w14a` / `23w51b` 的编号。
    ///
    /// 已知边界：1.17 系列快照（21w03a ~ 21w36a）实际只需 Java 16，
    /// 此处统一取更高一级，仅用于过滤，不会导致选到过低的版本。
    private static func snapshotMinimumMajor(_ version: String) -> Int? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let weekSeparator = trimmed.firstIndex(where: { $0 == "w" }) else { return nil }
        guard let year = Int(trimmed[trimmed.startIndex..<weekSeparator]) else { return nil }

        let tail = trimmed[trimmed.index(after: weekSeparator)...]
        guard let week = Int(tail.prefix { $0.isNumber }) else { return nil }

        // 24w14a 起对应 1.20.5+，需要 Java 21；21w 及之后对应 1.17+，需要 Java 17
        if year > 24 || (year == 24 && week >= 14) { return 21 }
        if year >= 21 { return 17 }
        return fallbackMinimumMajor
    }
}
