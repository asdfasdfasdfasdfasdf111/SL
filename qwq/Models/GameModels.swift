import Foundation

enum GameSubCategory: String, CaseIterable, Identifiable {
    case release = "正式版"
    case snapshot = "测试版"
    case ancient = "远古版"

    var id: String { rawValue }
}

enum GameSidebarSection: String, CaseIterable, Identifiable {
    case game = "游戏"
    case mod = "模组"
    case resourcePack = "资源包"
    case shader = "光影"
    case modpack = "整合包"

    var id: String { rawValue }

    var systemImage: String {
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
    "8x-": "极简", "16x": "16x", "32x": "32x", "48x": "48x",
    "64x": "64x", "128x": "128x", "256x": "256x", "512x+": "超高清",
    "audio": "含声音", "fonts": "含字体", "models": "含模型",
    "gui": "含 UI", "locale": "含语言", "core-shaders": "核心着色器",
    "modded": "兼容 Mod", "fantasy": "幻想风", "semi-realistic": "半写实风",
    "cartoon": "卡通风", "colored-lighting": "彩色光照", "path-tracing": "路径追踪",
    "pbr": "PBR", "reflections": "反射", "iris": "Iris",
    "optifine": "OptiFine", "vanilla": "原版可用"
]

struct DownloadedItem: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var subtitle: String
    let iconURL: String?
    let tags: [String]

    static func == (lhs: DownloadedItem, rhs: DownloadedItem) -> Bool {
        lhs.id == rhs.id && lhs.subtitle == rhs.subtitle
    }
}