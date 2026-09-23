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

        let libraries = manifest.getNeededLibraries()
        let libTotal = max(1, libraries.count)
        // 「本应补全却补不了」的项：缺失文件定位不到下载地址 / 清单 URL 非法。
        // 原实现对这些项直接 `continue`——不下载、不报错、不计进度，于是：
        //  日志里看不到、界面上看不到、进度条停在原地像是卡死，
        //  最终仍带着缺失的库拉起进程，游戏在进入后才以 NoClassDefFoundError 崩溃，
        //  UI 只能显示「异常退出」，用户与维护者都无从定位。
        // 现在统一收集到本数组，逐条 err 记日志，并在末尾汇总为一次用户可见提示。
        var unrepairable: [String] = []

        // 1) 缺失支持库分析（PCL2 McLibFix）：已存在且 sha1 匹配 → 跳过，仅收集缺失项
        for (i, library) in libraries.enumerated() {
            // 每项（含补不了的项）都推进进度：跳过的项不计进度会让进度条停在原地
            let step = Double(i + 1) / Double(libTotal) * 0.5
            guard let artifact = library.artifact else {
                onProgress(step)
                continue
            }
            let dest = dir.librariesURL.appendingPathComponent(artifact.path)
            if fileIsValid(dest, hash: artifact.sha1) {
                onProgress(step)
                continue
            }
            // 走到这里代表该文件**当前缺失或校验不通过**
            if let url = DownloadSourceManager.shared.getLibraryURL(library) {
                items.append(.init(url, dest, sha1: artifact.sha1))
            } else {
                // 缺库且拿不到下载地址 = 无法自愈的缺库，必须可见
                err("启动前补全：库 \(library.name) 缺失但无法解析下载地址，已跳过（\(dest.path)）")
                unrepairable.append(library.name)
            }
            onProgress(step)
        }
        
        // 2) 资源索引：缺失或损坏时先补索引，再按索引分析缺失资源
        var assetsObjects: [AssetIndex.Object] = []
        if let assetIndexInfo = manifest.assetIndex {
            let indexPath = dir.assetsURL.appendingPathComponent("indexes").appendingPathComponent("\(assetIndexInfo.id).json")
            if !fileIsValid(indexPath, hash: assetIndexInfo.sha1) {
                if let url = URL(string: assetIndexInfo.url) {
                    items.append(.init(url, indexPath, sha1: assetIndexInfo.sha1))
                } else {
                    // 清单里的索引 URL 非法（第三方/损坏清单）：索引补不上 → 后续资源分析也无法进行
                    err("启动前补全：资源索引 URL 非法，已跳过：\(assetIndexInfo.url)")
                    unrepairable.append("资源索引 \(assetIndexInfo.id)")
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
        let assetTotal = max(1, assetsObjects.count)
        for (i, object) in assetsObjects.enumerated() {
            let dest = object.appendTo(dir.assetsURL.appendingPathComponent("objects"))
            if fileIsValid(dest, hash: object.hash) {
                onProgress(0.5 + Double(i + 1) / Double(assetTotal) * 0.5)
                continue
            }
            // 原实现：`getAssetURL(hash:) ?? URL(string: 官方CDN)!`，hash 含空格/`#`/裸 `%` 时
            // `getAssetURL` 返回 nil 且兜底 `URL(string:)!` 崩。两者都解析不出则记 err 并计入
            // unrepairable（与 :67 资源索引 URL 非法同口径）。
            if let resolvedAssetURL = DownloadSourceManager.shared.getDownloadSource().getAssetURL(hash: object.hash)
                      ?? assetURL(hash: object.hash) {
                items.append(.init(resolvedAssetURL, dest, sha1: object.hash))
            } else {
                err("启动前补全：资源 \(object.hash) 的下载地址非法，已跳过")
                unrepairable.append("资源 \(object.hash)")
            }
        }
        
        // 4) 下载缺失项（NetManager 引擎：多源回退 + 分片 + 重试 + 校验）
        if !items.isEmpty {
            let total = Double(items.count)
            try await MultiFileDownloader(items: items, concurrentLimit: 32) { progress, _ in
                onProgress(progress)
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
                        // 与原 :91 资源分析同口径：hash 含空格/`#`/裸 `%` 时 getAssetURL 与兜底都解析
                        // 不出，记 err 并计入 unrepairable，而非 `URL(string:)!` 崩。
                        if let resolvedAssetURL = DownloadSourceManager.shared.getDownloadSource().getAssetURL(hash: object.hash)
                                  ?? assetURL(hash: object.hash) {
                            assetItems.append(.init(resolvedAssetURL, dest, sha1: object.hash))
                        } else {
                            err("启动前补全：资源 \(object.hash) 的下载地址非法，已跳过")
                            unrepairable.append("资源 \(object.hash)")
                        }
                    }
                    if !assetItems.isEmpty {
                        let total = Double(assetItems.count)
                    try await MultiFileDownloader(items: assetItems, concurrentLimit: 32) { progress, _ in
                        onProgress(progress)
                        }.start()
                    }
                }
            }
        }
        
        // 5) natives 缺失 → 重新解压（PCL2 McLaunchNatives 语义）
        try MinecraftInstaller.ensureNatives(instance)

        // 6) 汇总「补不了的项」并让用户看见。
        //
        // **为什么只提示、不阻断**（本条的取舍口径）：
        //  - `getNeededLibraries()` 只表示「清单规则允许且当前平台适用」，不表示运行期一定会加载该库；
        //    第三方加载器清单里常见「列了但实际由加载器自带 / 永不访问」的条目。
        //    据此阻断会把**本可正常启动**的实例变成不可启动——这是比原缺陷更糟的结果。
        //  - 与 PCL2 DlClientFix 的同源语义一致：尽力修补后继续，把判断留给用户。
        //  - 真正的硬失败（客户端 JAR 缺失或为空）已由桥接层 `slLaunchInternal` 在拉起进程前阻断，
        //    不依赖本函数。
        // 因此这里选择「不阻断 + 双重可见」：逐条 err 进日志，汇总 hint 进界面提示，
        // 并保留 `unrepairable` 计数供后续接入更精细的必要性判定。
        if !unrepairable.isEmpty {
            let detail = unrepairable.prefix(3).joined(separator: "、")
            let suffix = unrepairable.count > 3 ? " 等" : ""
            warn("启动前补全：\(unrepairable.count) 项缺失文件无法解析下载地址，已跳过：\(unrepairable.joined(separator: "、"))")
            hint("启动前补全有 \(unrepairable.count) 项文件无法获取下载地址（\(detail)\(suffix)），游戏可能因缺库无法正常进入。", .critical)
        }
    }
    
    /// 资源文件（assets objects）兜底下载地址：官方 CDN。
    /// 原实现用 `getAssetURL(hash:) ?? URL(string: 官方CDN)!`，当 hash 含空格/`#`/裸 `%` 时
    /// `getAssetURL` 返回 nil 且兜底 `URL(string:)!` 崩。这里返回 `URL?`，解析不出则交回调用方
    /// 走 err + unrepairable（与 :67 资源索引 URL 非法同口径）。
    private static func assetURL(hash: String) -> URL? {
        return URL(string: "https://resources.download.minecraft.net/\(String(hash.prefix(2)))/\(hash)")
    }

    /// 文件存在且（有 hash 时）hash 匹配 → true
    private static func fileIsValid(_ url: URL, hash: String?) -> Bool {
        FileChecker(hash: hash).check(url) == nil
    }
}
