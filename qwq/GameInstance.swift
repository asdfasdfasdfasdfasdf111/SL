//
//  GameInstance.swift
//  模块化拆分：从 ModInstallViews.swift 拆出「游戏实例」数据模型。
//  纯数据：rootPath + version，displayName 做展示名归一（根目录名与版本名一致时只显示版本）。
//

import Foundation

struct GameInstance: Identifiable, Equatable {
    let id = UUID()
    let rootPath: String
    let version: String

    var displayName: String {
        let rootName = URL(fileURLWithPath: rootPath).lastPathComponent
        if rootName == version || rootName.isEmpty || rootName == "minecraft" || rootName == ".minecraft" {
            return version
        }
        return "\(rootName) / \(version)"
    }
}
