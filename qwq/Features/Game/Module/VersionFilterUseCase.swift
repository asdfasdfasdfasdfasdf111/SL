//
//  VersionFilterUseCase.swift
//  Game 模块：版本清单分类过滤用例
//
//  本用例是「正式版 / 测试版（快照）/ 远古版」三分桶规则的**唯一实现处**。
//  既有 `GameVersionFilter.filteredIDs`（按 `[[String: Any]]` 过滤）已改为本用例的适配器，
//  分类列表（GameViews）与详情页（ModDetailView）共用同一份规则，不再各写一遍 switch。
//
//  规则逐条对齐原实现，注释随规则保留：
//  - 正式版：清单 type == "release"（含 1.7.x、1.8、1.12.2 等老正式版）
//  - 测试版（快照）：清单 type == "snapshot" 或 "pending"，且不是愚人节版本（愚人节归远古版）
//  - 远古版：清单 type == "old_alpha" 或 "old_beta"，以及全部愚人节版本
//  愚人节判定委托 `GameVersionHelper.isAprilFoolVersion(id:type:)`，本用例不重复实现命名规则。
//

import Foundation

// MARK: - 分类

/// 版本浏览使用的分类。
///
/// 与 `GameSubCategory`（Models/GameModels.swift:3）的展示分类一一对应：
/// `.release` ↔ `.release`（正式版）、`.snapshot` ↔ `.snapshot`（测试版，即快照）、
/// `.ancient` ↔ `.ancient`（远古版）。`.all` 为模块附加的未过滤视图，不对应侧边栏条目。
enum VersionCatalogCategory: String, Sendable, CaseIterable, Identifiable {

    case release = "正式版"
    case snapshot = "测试版"
    case ancient = "远古版"
    case all = "全部版本"

    var id: String { rawValue }

    /// 侧边栏子分类；`.all` 没有对应的侧边栏条目，返回 nil。
    var subCategory: GameSubCategory? {
        switch self {
        case .release: return .release
        case .snapshot: return .snapshot
        case .ancient: return .ancient
        case .all: return nil
        }
    }

    init(subCategory: GameSubCategory?) {
        switch subCategory {
        case .release: self = .release
        case .snapshot: self = .snapshot
        case .ancient: self = .ancient
        case .none: self = .all
        }
    }
}

// MARK: - 用例

/// 版本分类过滤。无状态、无副作用，可自由构造与跨并发域传递。
struct VersionFilterUseCase: Sendable {

    /// `nonisolated`：用例无状态，构造不应被任何全局 actor 限制
    /// （否则在默认隔离为 `MainActor` 的编译口径下，默认参数等非隔离上下文无法构造它）。
    nonisolated init() {}

    /// 按分类过滤，保持输入顺序。
    ///
    /// `kind` 为 nil（清单 type 未识别）的条目不落入任何分类，只会出现在 `.all` 中。
    func filter(_ versions: [MinecraftVersionInfo], into category: VersionCatalogCategory) -> [MinecraftVersionInfo] {
        switch category {
        case .all:
            return versions
        case .release:
            return versions.filter { $0.kind == .release }
        case .snapshot:
            return versions.filter { ($0.kind == .snapshot || $0.kind == .pending) && !$0.isAprilFool }
        case .ancient:
            return versions.filter { $0.kind == .alpha || $0.kind == .beta || $0.isAprilFool }
        }
    }

    /// 按侧边栏子分类过滤。
    ///
    /// `nil`（未选中任何子分类）返回空列表——与既有 `GameVersionFilter` 的 `.none` 分支一致，
    /// 调用方不得把它当作「不过滤」。需要全部版本请用 `filter(_:into: .all)`。
    func filter(_ versions: [MinecraftVersionInfo], subCategory: GameSubCategory?) -> [MinecraftVersionInfo] {
        guard subCategory != nil else { return [] }
        return filter(versions, into: VersionCatalogCategory(subCategory: subCategory))
    }

    /// 按侧边栏子分类过滤并取版本号，供既有清单取 id 的调用点使用。
    func ids(_ versions: [MinecraftVersionInfo], subCategory: GameSubCategory?) -> [String] {
        filter(versions, subCategory: subCategory).map(\.id)
    }
}
