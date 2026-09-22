//
//  LoaderSupportState.swift
//  SL启动器
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
    ///
    /// 全库无引用，待清理：UI 层已改走 `streamLoaderStates` / `cachedLoaderStates` 流式状态机，
    /// 本聚合入口没有调用方（其内部调用的 `cachedLoaders` 因此也只剩这一处调用点）。
    /// 保留以实现与文案不变，仅标注待清理。
    @available(*, deprecated, message: "全库无引用，待清理")
    public static func supportedLoaders(for version: String) async -> LoaderSupportResult {
        // 缓存短路必须同时满足两个条件：有缓存 + 缓存已覆盖全部候选。
        // `cachedLoaders` 返回 `[]` 只说明「缓存里有记录但没有 supported 项」，
        // 若此时仍有候选未定论（例如只缓存到 Forge = notSupported），
        // 直接返回会把「部分未知」当成「已定论：全不支持」——短路联网且永不重试，
        // 因此以 `isFullyResolved`（唯一可用的定论判据）作为采信条件。
        // 缓存真的已定论时行为不变（空列表仍按枚举约定返回 .supported([])）。
        if let cachedStates = cachedLoaderStates(for: version), isFullyResolved(cachedStates, for: version) {
            return .supported(cachedLoaders(for: version) ?? [])
        }
        let states = await checkLoaderStates(for: version)
        let supported = states.compactMap { $0.value == .supported ? $0.key : nil }.sorted { orderIndex($0) < orderIndex($1) }
        let hasUnknown = states.values.contains { $0 == .unavailable }
        if !supported.isEmpty { return .supported(supported) }
        if !hasUnknown { return .notSupported }
        // 走到这里说明仍有未定论项：只有确实读到非空缓存 supported 时才降级为 supported；
        // 空列表不能当作「不支持」返回，否则会掩盖 unavailable 并让调用方停止重试。
        if let cached = cachedLoaders(for: version), !cached.isEmpty { return .supported(cached) }
        return .unavailable
    }
}
