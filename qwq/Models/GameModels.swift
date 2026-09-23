import Foundation

/// 游戏版本的子分类（侧边栏「游戏」下的三项）。
/// ⚠️ rawValue 是**中文显示名**（`"正式版"`），并且同时被当作 `id` ——
/// 它既是界面文案又是列表 identity，改名会同时改动显示文字与列表键。
enum GameSubCategory: String, CaseIterable, Identifiable {
    /// 正式版（release）：稳定版本，绝大多数玩家的默认选择。
    case release = "正式版"
    /// 测试版（snapshot）：快照 / 预发布版，可能不稳定。
    case snapshot = "测试版"
    /// 远古版（ancient）：历史版本（alpha / beta 时代的旧版本）。
    case ancient = "远古版"

    /// `id` 直接取 rawValue —— 即上面那串中文。用作 `ForEach` 的 identity 时留意这一点。
    var id: String { rawValue }
}

/// 左侧边栏的五个一级分类。
/// ⚠️ 与 GameSubCategory 同一个坑：rawValue 就是中文显示名，且被当作 `id`。
/// ⚠️ 这五个中文名还承担**页面分派**的作用 —— CategoryContentView 靠
/// `category.name == "个性化" / "启动" / "游戏"` 这类字符串比较决定渲染哪个页面，
/// 改名会导致分派静默落空（走进空网格分支，无编译错误）。
enum GameSidebarSection: String, CaseIterable, Identifiable {
    /// 游戏：版本浏览与启动（唯一带子分类的一级分类）。
    case game = "游戏"
    /// 模组：Modrinth 模组浏览。
    case mod = "模组"
    /// 资源包：Modrinth 资源包浏览。
    case resourcePack = "资源包"
    /// 光影：Modrinth 光影浏览。
    case shader = "光影"
    /// 整合包：整合包浏览。
    case modpack = "整合包"

    /// 同 GameSubCategory：`id` = 中文 rawValue。
    var id: String { rawValue }

    /// 侧边栏图标。值直接是 **SF Symbols 名称**（不是资产目录名）——
    /// 拼错不会崩，只是图标位置空白。
    var systemImage: String {
        // 五个分类一一对应；统一用 `.fill` 变体保证填充风格一致。
        switch self {
        case .game: return "rectangle.grid.1x2.fill"
        case .mod: return "puzzlepiece.fill"
        case .resourcePack: return "photo.on.rectangle.angled"
        case .shader: return "sparkles"
        case .modpack: return "archivebox.fill"
        }
    }
}

// MARK: - Modrinth 分类标签汉化对照表（搬运自 PCL.Mac）

/// Modrinth 英文分类标签 → 中文显示名。
/// ⚠️ **白名单**语义：查不到的标签原样展示英文，不崩也不翻译 ——
/// 上游新增标签后，界面上会一直显示英文，直到这里补上映射。
/// ⚠️ 键集合是「内容标签 + 分辨率标签 + 光影特性标签」三类的混装，
/// 与 Modrinth 官方标签集同名不同义的情况存在，改动前先核对上游。
let ModrinthTagMap: [String: String] = [
    "technology": "科技", "magic": "魔法", "adventure": "冒险",
    "utility": "实用", "optimization": "性能优化", "vanilla-like": "原版风",
    "realistic": "写实风", "worldgen": "世界元素", "food": "食物/烹饪",
    "game-mechanics": "游戏机制", "transportation": "运输", "storage": "仓储",
    "decoration": "装饰", "mobs": "生物", "equipment": "装备",
    "social": "服务器", "library": "支持库", "multiplayer": "多人",
    "challenging": "硬核", "combat": "战斗", "quests": "任务",
    "kitchen-sink": "水槽包", "lightweight": "轻量", "simplistic": "简洁",
    "tweaks": "改良",
    // ↓ 分辨率标签（资源包 / 光影用）：数值即贴图或采样倍率，`512x+` 表示「512 及以上」。
    "8x-": "极简", "16x": "16x", "32x": "32x", "48x": "48x",
    "64x": "64x", "128x": "128x", "256x": "256x", "512x+": "超高清",
    // ↓ 资源包的内容类型标签（含声音 / 字体 / 模型）。
    "audio": "含声音", "fonts": "含字体", "models": "含模型",
    "gui": "含 UI", "locale": "含语言", "core-shaders": "核心着色器",
    // ↓ 光影的风格与渲染特性标签。
    "modded": "兼容 Mod", "fantasy": "幻想风", "semi-realistic": "半写实风",
    "cartoon": "卡通风", "colored-lighting": "彩色光照", "path-tracing": "路径追踪",
    "pbr": "PBR", "reflections": "反射", "iris": "Iris",
    "optifine": "OptiFine", "vanilla": "原版可用"
]

/// 下载 / 搜索列表里的**通用条目**（模组、资源包、光影、整合包、游戏版本共用同一个类型）。
/// 各页面按需要填字段：例如游戏版本把版本号放进 `name`、发布时间放进 `subtitle`。
///
/// ⚠️ 是 `Codable`：该类型会被缓存模块的序列化路径用到，增删字段要考虑旧缓存能否解码。
/// ⚠️ 自定义了 `==`（见下），所以「两个条目相等」**不看名字、图标与标签**。
struct DownloadedItem: Identifiable, Equatable, Codable {
    /// 唯一标识。Modrinth 项目用 `project_id`（缺失时会依次回落到 slug、甚至随机 UUID，
    /// 见 ModrinthSearcher）；游戏版本用版本号。
    let id: String
    /// 主标题（卡片上的大字）。
    var name: String
    /// 副标题 / 详情行（作者、发布时间、描述摘要等）。**参与相等判断**，见下。
    var subtitle: String
    /// 图标地址。nil = 无图标，界面回落到占位图。
    let iconURL: String?
    /// 分类标签（已按 ModrinthTagMap 汉化过的展示用文本）。
    let tags: [String]

    /// 自定义相等：**只比 id 与 subtitle**，刻意忽略 name / iconURL / tags。
    /// 设计意图是「同一条目、副标题（如下载量）变了就算内容更新」，用于判断列表要不要刷新。
    /// 副作用：名字改了但 subtitle 没变时，会判定为「未变化」而跳过更新。
    static func == (lhs: DownloadedItem, rhs: DownloadedItem) -> Bool {
        lhs.id == rhs.id && lhs.subtitle == rhs.subtitle
    }
}