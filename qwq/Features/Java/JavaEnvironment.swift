import Foundation

/// JavaEnvironment 模型 + 版本比较工具（Services/JavaPathFinder.swift 拆出）。
/// 纯搬移零行为变更。

struct JavaEnvironment {
    let path: String
    let version: String
    let vendor: String?
    let isValid: Bool
}

/// 版本比较（点分版本号逐段比较，非数值段按字典序）
func compareJavaVersions(_ v1: String, _ v2: String) -> ComparisonResult {
    let components1 = v1.split(separator: ".", omittingEmptySubsequences: false)
    let components2 = v2.split(separator: ".", omittingEmptySubsequences: false)
    for (c1, c2) in zip(components1, components2) {
        if let n1 = Int(c1), let n2 = Int(c2) {
            if n1 != n2 { return n1 < n2 ? .orderedAscending : .orderedDescending }
        } else {
            if c1 != c2 { return c1 < c2 ? .orderedAscending : .orderedDescending }
        }
    }
    return components1.count == components2.count ? .orderedSame :
        (components1.count < components2.count ? .orderedAscending : .orderedDescending)
}
