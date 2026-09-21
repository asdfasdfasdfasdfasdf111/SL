//
//  LoaderSupportState.swift
//  PCL.Mac
//
//  加载器支持检测的结果模型（从 LoaderSupportChecker.swift 逐字搬移，逻辑与文案未变）：
//  - LoaderState：单个加载器的检测状态，供 UI 逐卡片渲染
//  - LoaderSupportResult：聚合三态结果（兼容旧调用 `supportedLoaders(for:)`）
//

import Foundation

/// 单个加载器的检测状态（供 UI 逐卡片渲染，完成一个显示一个）
public enum LoaderState: Equatable {
    case checking
    case supported
    case notSupported
    case unavailable
}

extension LoaderSupportChecker {

    /// 加载器支持检测结果三态：
    /// - `.supported([String])`：明确检测到这些加载器（可能为空列表，见 `.notSupported`）
    /// - `.notSupported`：API 明确返回「该版本无此加载器」（404/410/空数组）→ 可缓存空结果
    /// - `.unavailable`：结果未知（网络失败 / 5xx / 超时）→ 不得写入缓存，UI 显示「暂时无法获取」而非「不支持」
    public enum LoaderSupportResult: Equatable {
        case supported([String])
        case notSupported
        case unavailable

        /// 结果中的加载器列表（非 supported 恒为空）
        public var loaders: [String] {
            if case .supported(let l) = self { return l }
            return []
        }
        /// 是否「结果未知」
        public var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    /// 兼容旧调用：聚合三态结果（内部走单加载器缓存 + 未定论项检测）
    public static func supportedLoaders(for version: String) async -> LoaderSupportResult {
        if let cached = cachedLoaders(for: version) { return .supported(cached) }
        let states = await checkLoaderStates(for: version)
        let supported = states.compactMap { $0.value == .supported ? $0.key : nil }.sorted { orderIndex($0) < orderIndex($1) }
        let hasUnknown = states.values.contains { $0 == .unavailable }
        if !supported.isEmpty { return .supported(supported) }
        if !hasUnknown { return .notSupported }
        if let cached = cachedLoaders(for: version) { return .supported(cached) }  // 过期磁盘兜底
        return .unavailable
    }
}
