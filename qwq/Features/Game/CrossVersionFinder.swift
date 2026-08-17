import Foundation

// MARK: - 跨版本下载匹配（自 ModDetailView 拆出）
// 资源包/光影页：目标版本没有对应文件夹时，在相邻版本中找第一个已建对应目录的版本，
// 提示「自动匹配版本」下载到该版本。

enum CrossVersionFinder {
    /// 在候选版本中找第一个「已存在对应目录」的版本（排除目标版本本身）。
    /// - Parameters:
    ///   - candidates: 全部已排序版本
    ///   - target: 目标版本
    ///   - pageType: 页面类型（.resourcePack → resourcepacks 目录，.shader → shaderpacks 目录）
    ///   - gameRoot: 游戏根目录
    static func find(
        in candidates: [String],
        target: String,
        pageType: DetailPageType,
        gameRoot: String
    ) -> String? {
        let sorted = candidates.filter { $0 != target }
        let targetIdx = sorted.firstIndex(of: target)
        var searchOrder = sorted
        if let idx = targetIdx {
            let above = Array(sorted[0..<idx]).reversed()
            let below = Array(sorted[(idx + 1)...])
            searchOrder = above + below
        }
        for candidate in searchOrder {
            let subPath: String
            switch pageType {
            case .resourcePack: subPath = "resourcepacks"
            case .shader: subPath = "shaderpacks"
            default: continue
            }
            let dirPath = "\(gameRoot)/versions/\(candidate)/\(subPath)"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return nil
    }
}
