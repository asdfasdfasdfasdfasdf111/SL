import Foundation

// MARK: - 游戏版本下载编排（对标 PCL.Mac DownloadPage「开始下载」，自 ModDetailView 拆出）
// 用 MinecraftInstaller.createTask 建 Minecraft 安装任务（客户端清单/资源索引/本体/依赖/natives），
// 若用户选了加载器则追加对应加载器任务（key = fabric/forge/neoforge），组合成 InstallTasks
// 进入下载详情页；createTask 内部会从 DataManager.inprogressInstallTasks 按 key 找到加载器任务，
// 在客户端 jar 下载完成后自动串联安装（与 PCL.Mac createTask 行为一致）。
// 纯编排：不持有视图、不写 @State，只操作传入的引用类型（settings/manager），避免 UAF。

enum GameVersionDownloadStarter {
    /// 启动游戏版本下载安装。
    /// - Parameters:
    ///   - versionStr: 目标版本号
    ///   - loader: 用户选择的加载器（小写，如 "fabric"；无可用加载器的版本会装纯原版）
    ///   - loaderSupported: 该版本是否真的支持所选加载器（由调用方按实时检测结果传入）
    static func start(
        versionStr: String,
        loader: String,
        loaderSupported: Bool,
        settings: LauncherSettings,
        manager: DownloadDetailManager
    ) {
        Task {
            do {
                let root = settings.selectedGameRoot
                guard !root.isEmpty else { throw MyLocalizedError(reason: "未设置游戏根目录") }

                let minecraftDirectory = MinecraftDirectory(rootURL: URL(fileURLWithPath: root), name: "默认文件夹")
                let minecraftVersion = MinecraftVersion(displayName: versionStr)

                // 实例名：原版 = 版本号；带加载器 = 版本号 + "-" + 加载器名（与本地实例命名约定一致，如 1.20.1-Fabric）
                var name = versionStr
                var loaderKey: String? = nil
                if loaderSupported {
                    let brand: ClientBrand
                    switch loader {
                    case "fabric": brand = .fabric
                    case "forge": brand = .forge
                    case "neoforge", "neoforged": brand = .neoforge
                    case "quilt":
                        throw MyLocalizedError(reason: "Quilt 暂不支持一键下载安装，请使用 Fabric 或 Forge")
                    default:
                        throw MyLocalizedError(reason: "不支持的加载器: \(loader)")
                    }
                    name += "-\(brand.getName())"
                    loaderKey = brand.rawValue
                }

                // 组装任务集合（key 必须在 InstallTasks.getTasks() 固定顺序表内）
                let tasks = InstallTasks.empty()
                let minecraftTask = MinecraftInstaller.createTask(minecraftVersion, name, minecraftDirectory)
                tasks.addTask(key: "minecraft", task: minecraftTask)

                if let loaderKey {
                    // 交互是「点加载器卡片选类型」，没有版本选择 UI → 自动取该加载器最新版本
                    let loaderVersion = try await LoaderVersionResolver.latestVersion(loader: loaderKey, mcVersion: versionStr)
                    switch loaderKey {
                    case "fabric":
                        tasks.addTask(key: "fabric", task: FabricInstallTask(loaderVersion: loaderVersion))
                    case "forge":
                        tasks.addTask(key: "forge", task: ForgeInstallTask(forgeVersion: loaderVersion))
                    case "neoforge":
                        tasks.addTask(key: "neoforge", task: NeoforgeInstallTask(neoforgeVersion: loaderVersion))
                    default: break
                    }
                }

                let completedName = name
                minecraftTask.onComplete { [settings, manager, completedName] in
                    Task { @MainActor in
                        // 回调只操作全局单例（DownloadDetailManager）与 settings，
                        // 不写视图 @State：后台回调晚于视图销毁时写 State storage 会 UAF
                        manager.dismiss()
                        settings.javaPopupMessage = "\(completedName) 下载完成"
                        settings.showJavaPopup = true
                    }
                }

                // 打开详情页 + 同步 DataManager（createTask 内部按 tasks[key] 找加载器任务）→ 启动
                await MainActor.run {
                    manager.start(tasks)
                }
                tasks.tasks["minecraft"]!.start()
            } catch {
                await MainActor.run {
                    // 只操作全局单例与 settings（引用类型，生命周期与视图解耦）
                    manager.dismiss()
                    settings.launchErrorMessage = "下载失败: \(error.localizedDescription)"
                    settings.showLaunchAlert = true
                }
            }
        }
    }
}
