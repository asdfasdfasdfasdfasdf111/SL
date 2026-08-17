//
//  LaunchFix.swift
//  启动前补全（PCL2 DlClientFix + McLibFix + McAssetsFixList 移植）
//
//  PCL2 每次启动前都会执行 DlClientFix：分析缺失/损坏的支持库与资源文件，
//  仅下载缺失项（McLibFix 按 sha1 检查库、McAssetsFixList 按 hash 检查资源），
//  实现「启动即自愈」——缺库/坏资源自动补上，游戏不会因文件缺失崩溃。
//
//  本模块对应移植：ModDownload.vb DlClientFix(55-165) / ModMinecraft.vb McLibFix(1867) / McAssetsFixList(2172)
//

import Foundation

public enum LaunchFix {
    
    /// 执行启动前补全。缺失库/损坏资源会被重新下载；natives 缺失时重新解压。
    /// - Parameters:
    ///   - instance: 待启动的实例（manifest 已合并 inheritsFrom）
    ///   - onProgress: 补全进度回调 0~1（仅在有实际下载时调用）
    public static func perform(instance: MinecraftInstance, onProgress: @escaping (Double) -> Void) async throws {
        guard let manifest = instance.manifest else {
            // 无 manifest 无法分析缺失项，跳过补全（启动流程自身会报错）
            return
        }
        let dir = instance.minecraftDirectory
        var items: [DownloadItem] = []
        
        // 1) 缺失支持库分析（PCL2 McLibFix）：已存在且 sha1 匹配 → 跳过，仅收集缺失项
        for library in manifest.getNeededLibraries() {
            guard let artifact = library.artifact else { continue }
            let dest = dir.librariesURL.appendingPathComponent(artifact.path)
            if fileIsValid(dest, hash: artifact.sha1) { continue }
            if let url = DownloadSourceManager.shared.getLibraryURL(library) {
                items.append(.init(url, dest, sha1: artifact.sha1))
            }
        }
        
        // 2) 资源索引：缺失或损坏时先补索引，再按索引分析缺失资源
        var assetsObjects: [AssetIndex.Object] = []
        if let assetIndexInfo = manifest.assetIndex {
            let indexPath = dir.assetsURL.appendingPathComponent("indexes").appendingPathComponent("\(assetIndexInfo.id).json")
            if !fileIsValid(indexPath, hash: assetIndexInfo.sha1) {
                if let url = URL(string: assetIndexInfo.url) {
                    items.append(.init(url, indexPath, sha1: assetIndexInfo.sha1))
                }
            }
            // 索引本地可用时立即解析，否则等下载完成后由本函数末尾统一补资源（见下）
            if fileIsValid(indexPath, hash: assetIndexInfo.sha1),
               let data = try? Data(contentsOf: indexPath),
               let index = try? AssetIndex.parse(data) {
                assetsObjects = index.objects
            }
        }
        
        // 3) 缺失资源分析（PCL2 McAssetsFixList CheckHash）：asset 以 hash 命名，直接用 hash 校验
        for object in assetsObjects {
            let dest = object.appendTo(dir.assetsURL.appendingPathComponent("objects"))
            if fileIsValid(dest, hash: object.hash) { continue }
            let src = object.appendTo(URL(string: "https://resources.download.minecraft.net")!)
            items.append(.init(src, dest, sha1: object.hash))
        }
        
        // 4) 下载缺失项（NetManager 引擎：多源回退 + 分片 + 重试 + 校验）
        if !items.isEmpty {
            let total = Double(items.count)
            try await MultiFileDownloader(items: items, concurrentLimit: 32) { completedCount, _ in
                onProgress(Double(completedCount) / total)
            }.start()
            // 若资源索引是本次刚下载的，现在补上资源分析
            if assetsObjects.isEmpty, let assetIndexInfo = manifest.assetIndex {
                let indexPath = dir.assetsURL.appendingPathComponent("indexes").appendingPathComponent("\(assetIndexInfo.id).json")
                if let data = try? Data(contentsOf: indexPath),
                   let index = try? AssetIndex.parse(data) {
                    var assetItems: [DownloadItem] = []
                    for object in index.objects {
                        let dest = object.appendTo(dir.assetsURL.appendingPathComponent("objects"))
                        if fileIsValid(dest, hash: object.hash) { continue }
                        let src = object.appendTo(URL(string: "https://resources.download.minecraft.net")!)
                        assetItems.append(.init(src, dest, sha1: object.hash))
                    }
                    if !assetItems.isEmpty {
                        let total = Double(assetItems.count)
                        try await MultiFileDownloader(items: assetItems, concurrentLimit: 32) { completedCount, _ in
                            onProgress(Double(completedCount) / total)
                        }.start()
                    }
                }
            }
        }
        
        // 5) natives 缺失 → 重新解压（PCL2 McLaunchNatives 语义）
        try MinecraftInstaller.ensureNatives(instance)
    }
    
    /// 文件存在且（有 hash 时）hash 匹配 → true
    private static func fileIsValid(_ url: URL, hash: String?) -> Bool {
        FileChecker(hash: hash).check(url) == nil
    }
}
