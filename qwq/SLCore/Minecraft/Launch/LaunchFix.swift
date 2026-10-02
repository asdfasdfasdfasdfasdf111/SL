//
//  LaunchFix.swift
//  启动前补全（PCL2 DlClientFix + McLibFix + McAssetsFixList 移植）
//  ModDownload.vb DlClientFix(55-165) / ModMinecraft.vb McLibFix(1867) / McAssetsFixList(2172)
//
//  2026-10-02 P3-3 拆分：perform 只做编排；四类职责各抽为私有方法。
//  主资源循环与索引补漏循环同构段、两处下载段各收敛为一处实现。LAUNCH_FLOW 行为不变。
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
        // 「本应补全却补不了」的项（缺库/坏资源定位不到下载地址）：原实现直接 continue，
        // 进度条像卡死、游戏进入后才崩溃，无从定位。现在收集到本数组，末尾汇总提示。
        var unrepairable: [String] = []

        // 1) 缺失支持库分析（PCL2 McLibFix）：已存在且 sha1 匹配 → 跳过，仅收集缺失项
        items += collectMissingLibraries(
            manifest.getNeededLibraries(),
            dir: dir,
            onProgress: onProgress,
            unrepairable: &unrepairable
        )

        // 2) 资源索引：缺失或损坏时先补索引，再按索引分析缺失资源
        var assetsObjects: [AssetIndex.Object] = []
        if let assetIndexInfo = manifest.assetIndex {
            let indexPath = dir.assetsURL.appendingPathComponent("indexes").appendingPathComponent("\(assetIndexInfo.id).json")
            if !fileIsValid(indexPath, hash: assetIndexInfo.sha1) {
                if let url = URL(string: assetIndexInfo.url) {
                    items.append(.init(url, indexPath, sha1: assetIndexInfo.sha1))
                } else {
                    // 索引 URL 非法（第三方/损坏清单）：索引补不上 → 后续资源分析也无法进行
                    err("启动前补全：资源索引 URL 非法，已跳过：\(assetIndexInfo.url)")
                    unrepairable.append("资源索引 \(assetIndexInfo.id)")
                }
            }
            // 索引本地可用时立即解析，否则等下载完成后统一补资源（见下）
            if fileIsValid(indexPath, hash: assetIndexInfo.sha1),
               let data = try? Data(contentsOf: indexPath),
               let index = try? AssetIndex.parse(data) {
                assetsObjects = index.objects
            }
        }

        // 3) 缺失资源分析（PCL2 McAssetsFixList）：asset 以 hash 命名，直接用 hash 校验
        items += collectMissingAssets(
            assetsObjects,
            dir: dir,
            // 主循环进度区间：资源对象缺项占全局后半 0.5（前半为支持库），仅跳过项推进
            progressOnSkip: { onProgress(0.5 + $0 * 0.5) },
            unrepairable: &unrepairable
        )

        // 4) 下载缺失项（NetManager 引擎：多源回退 + 分片 + 重试 + 校验）
        if !items.isEmpty {
            try await download(items, onProgress: onProgress)
            // 若资源索引是本次刚下载的，现在补上资源分析
            if assetsObjects.isEmpty, let assetIndexInfo = manifest.assetIndex {
                let indexPath = dir.assetsURL.appendingPathComponent("indexes").appendingPathComponent("\(assetIndexInfo.id).json")
                if let data = try? Data(contentsOf: indexPath),
                   let index = try? AssetIndex.parse(data) {
                    let assetItems = collectMissingAssets(
                        index.objects,
                        dir: dir,
                        // 补漏场景：索引刚下载完，不推进度（全局进度已到 1，继续推会越界）
                        progressOnSkip: nil,
                        unrepairable: &unrepairable
                    )
                    if !assetItems.isEmpty {
                        try await download(assetItems, onProgress: onProgress)
                    }
                }
            }
        }

        // 5) natives 缺失 → 重新解压（PCL2 McLaunchNatives 语义）
        try MinecraftInstaller.ensureNatives(instance)

        // 6) 汇总「补不了的项」并让用户看见。
        //
        // **为什么只提示、不阻断**：
        //  - `getNeededLibraries()` 只表示「清单规则允许且当前平台适用」，不表示运行期一定会加载；
        //    据此阻断会把**本可正常启动**的实例变成不可启动——比原缺陷更糟。
        //  - 与 PCL2 DlClientFix 同源语义一致：尽力修补后继续，把判断留给用户。
        //  - 真正的硬失败（客户端 JAR 缺失或为空）已由桥接层 `slLaunchInternal` 在拉起进程前阻断。
        // 因此「不阻断 + 双重可见」：逐条 err 进日志，汇总 hint 进界面提示。
        if !unrepairable.isEmpty {
            let detail = unrepairable.prefix(3).joined(separator: "、")
            let suffix = unrepairable.count > 3 ? " 等" : ""
            warn("启动前补全：\(unrepairable.count) 项缺失文件无法解析下载地址，已跳过：\(unrepairable.joined(separator: "、"))")
            hint("启动前补全有 \(unrepairable.count) 项文件无法获取下载地址（\(detail)\(suffix)），游戏可能因缺库无法正常进入。", .critical)
        }
    }

    // MARK: - 四类职责（P3-3 拆分，行为与原 perform 内联段一致）

    /// 缺失支持库收集（McLibFix）：已存在且 sha1 匹配 → 跳过，仅收集缺失项。
    /// 每项都推进进度（跳过的项不计进度会让进度条停在原地）；
    /// 缺库且拿不到下载地址 = 无法自愈，记 err 并计入 unrepairable。
    private static func collectMissingLibraries(_ libraries: [ClientManifest.Library], dir: MinecraftDirectory, onProgress: (Double) -> Void, unrepairable: inout [String]) -> [DownloadItem] {
        var items: [DownloadItem] = []
        let libTotal = max(1, libraries.count)
        for (i, library) in libraries.enumerated() {
            let step = Double(i + 1) / Double(libTotal) * 0.5
            guard let artifact = library.artifact else { onProgress(step); continue }
            let dest = dir.librariesURL.appendingPathComponent(artifact.path)
            if fileIsValid(dest, hash: artifact.sha1) { onProgress(step); continue }
            if let url = DownloadSourceManager.shared.getLibraryURL(library) {
                items.append(.init(url, dest, sha1: artifact.sha1))
            } else {
                err("启动前补全：库 \(library.name) 缺失但无法解析下载地址，已跳过（\(dest.path)）")
                unrepairable.append(library.name)
            }
            onProgress(step)
        }
        return items
    }

    /// 缺失资源收集（McAssetsFixList CheckHash）：asset 以 hash 命名，直接用 hash 校验。
    /// 解析不出下载地址时记 err 并计入 unrepairable，不再强制解包 `URL(string:)!` 崩。
    /// - Parameter progressOnSkip: 每跳过一个有效项时推进的局部进度回调；
    ///   主循环传「缺项占后 0.5 区间」的映射，索引补漏场景传 nil（不推进度）。
    private static func collectMissingAssets(_ objects: [AssetIndex.Object], dir: MinecraftDirectory, progressOnSkip: ((Double) -> Void)?, unrepairable: inout [String]) -> [DownloadItem] {
        var items: [DownloadItem] = []
        let assetTotal = max(1, objects.count)
        for (i, object) in objects.enumerated() {
            let dest = object.appendTo(dir.assetsURL.appendingPathComponent("objects"))
            if fileIsValid(dest, hash: object.hash) {
                progressOnSkip?(Double(i + 1) / Double(assetTotal))
                continue
            }
            if let resolvedAssetURL = DownloadSourceManager.shared.getDownloadSource().getAssetURL(hash: object.hash)
                      ?? assetURL(hash: object.hash) {
                items.append(.init(resolvedAssetURL, dest, sha1: object.hash))
            } else {
                err("启动前补全：资源 \(object.hash) 的下载地址非法，已跳过")
                unrepairable.append("资源 \(object.hash)")
            }
        }
        return items
    }

    /// 下载一组缺失项（NetManager 引擎）。
    private static func download(_ items: [DownloadItem], onProgress: @escaping (Double) -> Void) async throws {
        try await MultiFileDownloader(items: items, concurrentLimit: 32) { progress, _ in
            onProgress(progress)
        }.start()
    }

    private static func assetURL(hash: String) -> URL? {
        return URL(string: "https://resources.download.minecraft.net/\(String(hash.prefix(2)))/\(hash)")
    }

    /// 文件存在且（有 hash 时）hash 匹配 → true
    private static func fileIsValid(_ url: URL, hash: String?) -> Bool {
        FileChecker(hash: hash).check(url) == nil
    }
}