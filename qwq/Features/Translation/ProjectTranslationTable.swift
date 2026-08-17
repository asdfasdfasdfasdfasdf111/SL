import Foundation

/// 常见项目名内置翻译表（快速匹配，避免重复请求）。
/// 拆自 TranslationService.swift 顶层私有常量；key = slug 或 project_id。
enum ProjectTranslationTable {
    static let entries: [String: String] = [
        // slug / project_id -> 中文名称或描述
        "fabric-api": "Fabric API 是 Fabric 工具链提供的轻量级模块化 API，为模组提供通用钩子与兼容方案。",
        "P7dR8mSH": "Fabric API 是 Fabric 工具链提供的轻量级模块化 API，为模组提供通用钩子与兼容方案。",
        "sodium": "钠（Sodium）——现代渲染引擎优化模组，大幅提升游戏帧率。",
        "AANobbMI": "钠（Sodium）——现代渲染引擎优化模组，大幅提升游戏帧率。",
        "iris": "Iris 光影加载器——兼容 Sodium 的现代光影加载器。",
        "YL57xq9U": "Iris 光影加载器——兼容 Sodium 的现代光影加载器。",
        "lithium": "锂（Lithium）——服务端/客户端性能优化模组。",
        "gvQqBUqZ": "锂（Lithium）——服务端/客户端性能优化模组。",
        "phosphor": "磷（Phosphor）——光照引擎优化模组。",
        "hEOCdDgO": "磷（Phosphor）——光照引擎优化模组。",
        "modmenu": "模组菜单——为 Fabric 添加模组列表管理界面。",
        "mOgUt4GM": "模组菜单——为 Fabric 添加模组列表管理界面。",
        "cloth-config": "Cloth Config——通用配置界面库。",
        "9s6osm5g": "Cloth Config——通用配置界面库。",
        "architectury-api": "Architectury API——跨加载器开发兼容层。",
        "lhGA9TYQ": "Architectury API——跨加载器开发兼容层。",
        "create": "机械动力（Create）——围绕建筑与装饰的科技类模组。",
        "LZmaPXh4": "机械动力（Create）——围绕建筑与装饰的科技类模组。",
        "jei": "JEI——物品与配方查看器。",
        "fnYWtaPL": "JEI——物品与配方查看器。",
        "rei": "REI——物品与配方查看器（Roughly Enough Items）。",
        "nfn13Yns": "REI——物品与配方查看器（Roughly Enough Items）。",
        "emi": "EMI——高效物品与配方管理界面。",
        "fRiHVvFU": "EMI——高效物品与配方管理界面。",
        "xmmod": "Xaero 的小地图模组。"
    ]

    /// 按 id 直接匹配（原样 + 小写）
    static func match(_ id: String) -> String? {
        entries[id] ?? entries[id.lowercased()]
    }

    /// 按标题包含查找（Modrinth 详情页 title → 中文名称提示）
    static func hint(forTitle title: String) -> String? {
        for (_, value) in entries where value.contains(title) {
            return value
        }
        return nil
    }
}
