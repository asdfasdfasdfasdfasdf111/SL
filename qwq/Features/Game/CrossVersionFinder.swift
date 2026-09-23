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
        // targetIdx 必须在「未过滤」的候选集上取，否则目标已被 filter 掉永远取不到，
        // 导致上面「优先搜相邻版本」的分支恒为死代码、只能从头线性扫描。
        let targetIdx = candidates.firstIndex(of: target)
        var searchOrder = candidates.filter { $0 != target }
        if let idx = targetIdx {
            let above = Array(candidates[0..<idx]).reversed()
            let below = Array(candidates[(idx + 1)...])
            searchOrder = (above + below).filter { $0 != target }
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
