import SwiftUI

struct Category: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let systemImage: String
    let filter: String?
}

extension Category {
    static let all: [Category] = [
        Category(name: "启动", systemImage: "sparkle.magnifyingglass", filter: nil),
        Category(name: "游戏", systemImage: "gamecontroller", filter: "游戏"),
        Category(name: "下载", systemImage: "arrow.down.circle", filter: nil),
        Category(name: "联机", systemImage: "wifi", filter: nil),
        Category(name: "赞助", systemImage: "heart", filter: nil),
        Category(name: "个性化", systemImage: "paintpalette", filter: nil)
    ]
}