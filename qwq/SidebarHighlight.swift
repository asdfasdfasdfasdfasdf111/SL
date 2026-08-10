import Foundation

/// 分类侧边栏高亮位置纯逻辑（GameViews 列表页 / GameSidebarView 共享）。
/// 集中 section → 高亮 index 映射与高亮 y 偏移表，消除 GameViews 实例属性。
enum SidebarHighlight {
    /// 各 section 头部的高亮 y 偏移表（累加高度：36/28/28/28/36/36/36/36）
    static let offsets: [CGFloat] = {
        let hs: [CGFloat] = [36, 28, 28, 28, 36, 36, 36, 36]
        var off: [CGFloat] = [12]
        for i in 0..<7 { off.append(off[i] + hs[i]) }
        return off
    }()

    /// section + 游戏子分类 → 高亮 index（对应 offsets 下标）
    static func index(for section: GameSidebarSection, sub: GameSubCategory?) -> Int {
        switch section {
        case .game:
            switch sub {
            case .release: return 1
            case .snapshot: return 2
            case .ancient: return 3
            case .none: return 0
            }
        case .mod: return 4
        case .resourcePack: return 5
        case .shader: return 6
        case .modpack: return 7
        }
    }
}
