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
            // 先建空任务组并取 id：即使 do 内提前抛错（未设置根目录/加载器不支持/取版本失败等），
            // catch 也有 ownerID 可做归属校验。绝不能用无归属的 dismiss() 去清「可能正在进行的
            // 其它下载」——否则本次失败的迟到回调会清掉正在下载的新任务引用（崩溃 #4 同类竞态）。
            let tasks = InstallTasks.empty()
            let ownerID = tasks.id
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

                // 组装任务集合（key 必须在 InstallTasks.getTasks() 固定顺序表内；tasks 已在上面创建）
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
                // 捕获任务组 id 做归属校验：complete() 的迟到回调若晚于下一个下载的
                // start() 到达，dismiss(ownerID:) 会识别出「全局任务组已被替换」并拒绝清理，
                // 避免旧任务清掉新任务的 InstallTasks 引用（跨任务交叉清理 UAF，崩溃 #4 根因）
                minecraftTask.onComplete { [settings, manager, completedName, ownerID, minecraftTask] in
                    Task { @MainActor in
                        // 回调只操作全局单例（DownloadDetailManager）与 settings，
                        // 不写视图 @State：后台回调晚于视图销毁时写 State storage 会 UAF
                        manager.dismiss(ownerID: ownerID)
                        if let reason = (minecraftTask as? MinecraftInstallTask)?.failureReason {
                            // 失败：终止任务 + 明确报错（旧实现失败不 complete() → 不触发本回调，
                            // 详情页永远挂着、既不终止也不报错）
                            settings.launchErrorMessage = "\(completedName) 下载失败: \(reason)"
                            settings.showLaunchAlert = true
                        } else {
                            settings.javaPopupMessage = "\(completedName) 下载完成"
                            settings.showJavaPopup = true
                        }
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
                    // 带 ownerID：若已有其它下载正在进行（start 已把其任务组放进 manager），
                    // 归属不一致 → 拒绝清理，绝对不动正在下载的任务引用
                    manager.dismiss(ownerID: ownerID)
                    settings.launchErrorMessage = "下载失败: \(error.localizedDescription)"
                    settings.showLaunchAlert = true
                }
            }
        }
    }
}
