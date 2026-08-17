//
//  ModrinthSectionType.swift
//  模块化拆分：从 GameViews.swift 拆出（原 applyFilter/loadMore 内重复的 section→type switch）
//  纯逻辑：GameSidebarSection → Modrinth API 的 project_type 查询参数映射；
//  游戏版本页（.game）无对应 Modrinth 类型，返回 nil。
//

import Foundation

/// 分类侧边栏 → Modrinth project_type 映射（纯逻辑，无状态）
enum ModrinthSectionType {
    /// 返回该分类对应的 Modrinth project_type；游戏版本页返回 nil（非 Modrinth 检索）
    static func type(for section: GameSidebarSection) -> String? {
        switch section {
        case .mod: return "mod"
        case .resourcePack: return "resourcepack"
        case .shader: return "shader"
        case .modpack: return "modpack"
        case .game: return nil
        }
    }
}
