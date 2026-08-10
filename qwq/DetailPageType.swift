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
}
