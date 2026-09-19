import Foundation

// MARK: - Java 解析错误

/// Java 解析失败原因。调用方据此决定是否需要提示用户下载 Java。
enum JavaResolutionError: LocalizedError {

    /// 本机未发现任何 Java 安装（仓储扫描结果为空）。
    case notFound(JavaRequirement)

    /// 已发现 Java，但没有任何一份同时满足可用性校验与版本下限。
    case noCompatibleVersion(requirement: JavaRequirement, available: [JavaInstallation])

    /// 扫描过程未能返回有效数据（首次取用时为空且强制重扫后仍为空）。
    case scanFailed

    var errorDescription: String? {
        switch self {
        case .notFound(let requirement):
            return "未在本机发现任何 Java 安装，当前版本需要 Java \(requirement.minimumMajor) 或更高。"
        case .noCompatibleVersion(let requirement, let available):
            let versions = Set(available.map { $0.majorVersion }).sorted().map(String.init).joined(separator: ", ")
            return "已发现 \(available.count) 个 Java 安装（主版本：\(versions.isEmpty ? "无" : versions)），但没有满足 Java \(requirement.minimumMajor)+ 且可用于本机的版本。"
        case .scanFailed:
            return "Java 扫描未返回结果，请稍后在「Java 管理」中重试扫描。"
        }
    }
}

// MARK: - Java 解析器协议

/// Java 选取的唯一入口：给定需求，返回一个可用于启动的 Java。
protocol JavaResolver: Sendable {
    func resolve(_ requirement: JavaRequirement) async throws -> JavaInstallation
}

// MARK: - 默认实现

/// 由仓储提供候选集，按固定优先级排序后返回首个命中项。
///
/// 排序策略（自上而下依次比较）：
/// 1. 满足 `preferredMajor` 的优先；
/// 2. 本机原生架构（含 Universal）优先，需 Rosetta 转译的次之；
/// 3. 主版本号更高者优先；
/// 4. 路径字典序，保证同一批候选的选取结果稳定。
final class DefaultJavaResolver: JavaResolver {

    private let repository: JavaRepository

    init(repository: JavaRepository = DefaultJavaRepository()) {
        self.repository = repository
    }

    func resolve(_ requirement: JavaRequirement) async throws -> JavaInstallation {
        var candidates = await repository.installed()
        if candidates.isEmpty {
            candidates = await repository.refresh()
        }
        guard !candidates.isEmpty else {
            throw JavaResolutionError.scanFailed
        }
        guard candidates.contains(where: { $0.majorVersion > 0 }) else {
            throw JavaResolutionError.notFound(requirement)
        }

        let usable = candidates.filter { $0.isCompatible && $0.majorVersion >= requirement.minimumMajor }
        guard let selected = usable.min(by: { Self.prefer($0, over: $1, for: requirement) }) else {
            throw JavaResolutionError.noCompatibleVersion(requirement: requirement, available: candidates)
        }

        // 与既有 selectBestJava 行为一致：记住本次采纳结果，供下次快速命中
        await repository.save(selected)
        return selected
    }

    /// 返回 true 表示 lhs 比 rhs 更优。
    private static func prefer(_ lhs: JavaInstallation, over rhs: JavaInstallation, for requirement: JavaRequirement) -> Bool {
        if let preferred = requirement.preferredMajor {
            let lhsHit = lhs.majorVersion == preferred
            let rhsHit = rhs.majorVersion == preferred
            if lhsHit != rhsHit { return lhsHit }
        }
        if lhs.architecture.isNative != rhs.architecture.isNative {
            return lhs.architecture.isNative
        }
        if lhs.majorVersion != rhs.majorVersion {
            return lhs.majorVersion > rhs.majorVersion
        }
        return lhs.executablePath < rhs.executablePath
    }
}
