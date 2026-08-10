import Foundation

// MARK: - 文件下载编排（mod/shader/resourcePack/modpack，自 ModDetailView 拆出）
// 解析目标文件 → 创建 ModFileDownloadTask → 打开详情页 → 启动任务；
// 整合包下载完成后自动进入 ModpackInstaller 安装流程。
// 纯编排：不持有视图、不写 @State，只操作传入的引用类型（settings/manager），避免 UAF。

enum ModFileDownloadStarter {
    /// 启动单文件下载。
    static func start(
        pageType: DetailPageType,
        item: DownloadedItem,
        selectedVersion: String,
        selectedLoader: String,
        selectedModpackVersionId: String,
        settings: LauncherSettings,
        manager: DownloadDetailManager
    ) {
        Task.detached(priority: .userInitiated) {
            do {
                let resolved = try await DownloadFileResolver.resolve(
                    pageType: pageType,
                    item: item,
                    selectedVersion: selectedVersion,
                    selectedLoader: selectedLoader,
                    selectedModpackVersionId: selectedModpackVersionId,
                    settings: settings
                )
                // destination 必须是完整文件路径（目录 + 文件名），供 SingleFileDownloader 落盘
                let destFile = resolved.destination.appendingPathComponent(resolved.filename)
                let task = ModFileDownloadTask(
                    url: resolved.url,
                    destination: destFile,
                    title: resolved.title
                )
                task.onComplete { [pageType, settings, manager, destFile] in
                    Task { @MainActor in
                        if pageType == .modpack, task.failureReason == nil {
                            // 整合包：zip 下载完成后还需解压安装（含 Minecraft/加载器/模组下载）
                            settings.javaPopupMessage = "正在安装整合包…"
                            settings.showJavaPopup = true
                            Task.detached(priority: .userInitiated) {
                                do {
                                    try await ModpackInstaller().install(
                                        packURL: destFile,
                                        to: URL(fileURLWithPath: LauncherSettings.shared.selectedGameRoot)
                                    )
                                    await MainActor.run {
                                        // 回调只操作全局单例（DownloadDetailManager）与 settings，
                                        // 不写视图 @State：后台回调晚于视图销毁时写 State storage 会 UAF
                                        DownloadDetailManager.shared.dismiss()
                                        settings.javaPopupMessage = "下载完成"
                                        settings.showJavaPopup = true
                                    }
                                } catch {
                                    await MainActor.run {
                                        DownloadDetailManager.shared.dismiss()
                                        settings.launchErrorMessage = "整合包安装失败: \(error.localizedDescription)"
                                        settings.showLaunchAlert = true
                                    }
                                }
                            }
                        } else {
                            DownloadDetailManager.shared.dismiss()
                            if let reason = task.failureReason {
                                settings.launchErrorMessage = "下载失败: \(reason)"
                                settings.showLaunchAlert = true
                            } else {
                                settings.javaPopupMessage = "下载完成"
                                settings.showJavaPopup = true
                            }
                        }
                    }
                }
                await MainActor.run {
                    manager.start(task)
                }
                task.start()
            } catch {
                await MainActor.run {
                    // 只操作全局单例与 settings（引用类型，生命周期与视图解耦）
                    DownloadDetailManager.shared.dismiss()
                    settings.launchErrorMessage = "下载失败: \(error.localizedDescription)"
                    settings.showLaunchAlert = true
                }
            }
        }
    }
}
