import Foundation

/// Java 信息模型（JavaManager / JavaVersionParser / ThemeManager 共享）。
/// 拆自 Services/JavaPathFinder.swift；纯搬移零行为变更。
struct JavaInfo: Codable, Equatable {
    let path: String
    let majorVersion: Int
    let fullVersion: String
    let architecture: String
    let vendor: String?
    let isValid: Bool
}
