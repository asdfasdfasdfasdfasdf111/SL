//
//  Category.swift
//  左侧分类栏的数据模型与唯一定义表（`Category.all`）。
//
//  谁在用它：
//  - `NavigationState.categories` 就是 `Category.all` 本身（不是副本），
//    所以「菜单里的第 N 项」与「导航状态里的第 N 项」指向同一个值 —— 这正是
//    `qwqApp` 的 ⌘1…⌘6 菜单（按 `Category.all` 下标发请求）与
//    `ContentView`（按 `navigation.categories` 下标取项）能对上的前提。
//    ⚠️ 改动 `all` 的顺序会同时改变菜单快捷键的归属，属于用户可见的行为变更。
//  - `CategoryContentView` 按本类型的 `name` 分发到各分类页面。
//
//  ── 已知弱点（2026-10-02：第 1 条已闭环）─────────────────────
//  1. ✅ 分发判据已结构化：`CategoryContentView` 改按 `category.kind`
//     （`CategoryKind` 枚举，下详）switch，不再比较 `name` 中文字符串。
//     改 `name` 字面量不再影响页面路由（`name` 退化为纯界面文案）。
//  2. `filter` 字段在 `all` 里只有「游戏」被赋了值，但**全库没有任何读取点**
//     （2026-09-23 与 2026-10-02 两次 grep 核实）。即它当前是只写不读的死字段。
//     保留原样以免动到模型；确认无用后可连同初始化参数一起删。
//

import SwiftUI

/// 左侧分类栏的一项。
///
/// `Hashable` 由编译器合成，**`id`（每次 `init` 新生成的 UUID）也参与相等性判断**。
/// 因此 `NavigationState.selectedIndex` 里的 `categories.firstIndex(of:)` 依赖的是
/// 「同一个实例」——只有当这些项来自 `Category.all` 这个 `static let`（实例只创建一次）时才成立。
/// 若将来在某处重新 `Category(name: "游戏", ...)` 造一个同名的项拿去比较，`==` 会返回 false。
struct Category: Identifiable, Hashable {
    /// 视图身份。每次实例化都是新的 UUID，故 `Category.all` 必须在进程内只求值一次（它是 `static let`）。
    let id = UUID()
    /// 分类名。**界面文案**；页面分派由 `kind` 承担，改名/本地化不再静默破坏路由（2026-10-02 起）。
    let name: String
    /// 分类语义身份（2026-10-02 新增）：`CategoryContentView` 按它分派到各页面。
    let kind: CategoryKind
    /// 侧边栏图标（SF Symbol 名）
    let systemImage: String
    /// 分类的筛选关键字。当前无读取点（见文件头弱点 2）。
    let filter: String?
}

/// 左侧分类的语义身份（2026-10-02）。
/// 与 `name`（文案）解耦：路由判据是 `kind`，新增分类必须先在此注册身份，
/// 否则 `CategoryContentView` 的 switch 会因不穷尽而编译报错（替代原来的静默空白页）。
enum CategoryKind: Hashable {
    /// 「启动」：`CategoryContentView` 内联实现（头像/用户名/启动/日志/电源）。
    case launcher
    /// 「游戏」→ `GameCategoryView`
    case game
    /// 「下载」→ `DownloadCategoryView`
    case download
    /// 「联机」：空网格占位分支。
    case online
    /// 「赞助」：静态赞助卡页。
    case sponsor
    /// 「个性化」→ `ColorPickerView`
    case appearance
}

extension Category {
    /// 全部分类，**顺序即侧边栏顺序，也是 ⌘1…⌘6 的归属**：
    /// 启动=⌘1、游戏=⌘2、下载=⌘3、联机=⌘4、赞助=⌘5、个性化=⌘6。
    ///
    /// 这里是 `static let`，不是计算属性：`id` 是每实例化的 UUID，
    /// 若写成 `static var { [...] }` 每次访问都会造出新实例，
    /// 依赖 `firstIndex(of:)` 的选中态判断会全部失配。
    static let all: [Category] = [
        Category(name: "启动", kind: .launcher, systemImage: "sparkle.magnifyingglass", filter: nil),
        Category(name: "游戏", kind: .game, systemImage: "gamecontroller", filter: "游戏"),
        Category(name: "下载", kind: .download, systemImage: "arrow.down.circle", filter: nil),
        Category(name: "联机", kind: .online, systemImage: "wifi", filter: nil),
        Category(name: "赞助", kind: .sponsor, systemImage: "heart", filter: nil),
        Category(name: "个性化", kind: .appearance, systemImage: "paintpalette", filter: nil)
    ]
}