//
//  DetailPageType.swift
//  模块化拆分：从 ModDetailView.swift 拆出（ModDetailView 与 GameViews 共用的详情页类型）
//

import SwiftUI

enum DetailPageType {
    case resourcePack
    case mod
    case shader
    case modpack
    case loaderSelector

    var titleText: String {
        switch self {
        case .resourcePack, .mod, .shader:
            return "你拥有的受支持的版本"
        case .modpack:
            return "请选择下载版本"
        case .loaderSelector:
            return "请选择下载的模组加载器"
        }
    }

    var supportedVersionTitle: String {
        switch self {
        case .resourcePack:
            return "此资源包目前严格意义上支持的游戏版本"
        case .mod:
            return "此模组支持的游戏版本"
        case .shader:
            return "此光影目前严格意义上支持的游戏版本"
        default:
            return ""
        }
    }

    var isCrossVersionDownload: Bool {
        switch self {
        case .resourcePack, .shader:
            return true
        default:
            return false
        }
    }

    /// 本详情页承载的条目，其 `item.id` 是否是 **Modrinth 项目 id**。
    ///
    /// 存在的理由（这是一个真实缺陷的收敛，不是风格偏好）：
    /// `ModDetailView` 用**同一个** `ModDetailViewModel` 渲染五种详情页，但各页 `item.id` 的语义不同：
    /// - `.mod` / `.shader` / `.resourcePack` / `.modpack`：id 来自 Modrinth 搜索结果，是真项目 id（或 slug）；
    /// - `.loaderSelector`（游戏版本页）：id 是 **Minecraft 版本号**（如 `"1.21.8"`），
    ///   来自 Mojang 清单或本地 `versions/` 目录 —— 它根本不是一个 Modrinth 项目。
    ///
    /// 拿版本号去请求 `/v2/project/1.21.8` 会得到 404，且 **官方 404 的响应体是空的**，
    /// 空数据喂给 `JSONDecoder().decode(ModrinthProject.self, ...)` 抛出的文案是
    /// 「The data couldn't be read because it isn't in the correct format.」——
    /// 把「这个 id 不是项目」误报成「数据格式不正确」。2026-09-23 实测复现：
    /// ```
    /// curl -s -o /dev/null -w "%{http_code}" -A "Swim111Launcher/1.0" \
    ///      https://api.modrinth.com/v2/project/1.21.8      # → 404，body 为空
    /// ```
    /// 后果：`triggerPageLoads` 此前无条件拉项目详情，于是**每打开一个新版游戏版本页都弹一次**
    /// 「项目信息获取失败」——用户报告的现象。
    ///
    /// 游戏版本页的加载器可用性**不依赖**本接口：它由 `LoaderSupportChecker` 走各加载器
    /// 自己的 meta 接口（Fabric/Quilt 官方 meta、Forge/NeoForge 走 BMCLAPI，见
    /// `qwq/SLCore/Minecraft/Mod/Loader/LoaderSupportProbe.swift`）决定。
    var hasModrinthProject: Bool {
        switch self {
        case .mod, .shader, .resourcePack, .modpack:
            return true
        case .loaderSelector:
            return false
        }
    }
}
