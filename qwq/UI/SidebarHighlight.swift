import Foundation

/// 分类侧边栏高亮位置纯逻辑（GameViews 列表页 / GameSidebarView 共享）。
/// 集中 section → 高亮 index 映射与高亮 y 偏移表，消除 GameViews 实例属性。
/// ⚠️ `offsets` 与 `index(for:)` 是**成对的**：后者的返回值就是前者的下标。
/// 两处（行高表 / 各分支返回的下标）必须同步改，否则高亮条会落在错误的行上 ——
/// 而且不会有编译错误或运行时提示，症状只是「高亮歪了一格」。
enum SidebarHighlight {
    /// 各 section 头部的高亮 y 偏移表（累加高度：36/28/28/28/36/36/36/36）。
    /// 首项 12 是顶部留白；共 8 项，对应 8 个可选行（3 个游戏子分类 + 5 个一级分类）。
    static let offsets: [CGFloat] = {
        // 各行**行高**：「游戏」及其三个子项是 36/28/28/28，其余一级分类各 36。
        let hs: [CGFloat] = [36, 28, 28, 28, 36, 36, 36, 36]
        var off: [CGFloat] = [12]
        for i in 0..<7 { off.append(off[i] + hs[i]) }
        return off
    }()

    /// section + 游戏子分类 → 高亮 index（即 offsets 的下标）。
    /// ⚠️ `.game` 配 nil 得到 0（指向「游戏」这一节自己的头部），不是 1。
    static func index(for section: GameSidebarSection, sub: GameSubCategory?) -> Int {
        switch section {
        // 只有游戏分类有子项，所以单独展开一层；其余分类一行一个固定下标。
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
