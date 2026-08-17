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
            // 本次调用真正 start 过才可能有「自己的」任务组可清；
            // resolve 阶段就失败时保持 nil → catch 里不做任何 dismiss，
            // 绝不动 manager 中可能正在进行的其它下载（崩溃 #4 同类竞态）
            var ownerID: UUID? = nil
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
                // 先 start 登记任务组并取 id（@discardableResult 本可忽略返回）：
                // dismiss(ownerID:) 只允许自己清自己——旧任务的迟到回调晚于新任务 start()
                // 到达时归属不一致 → 拒绝清理，避免误清新任务引用（跨任务交叉清理 UAF，
                // 崩溃 #4 根因）。顺序无妨：onComplete 只是登记回调，下面才 task.start()。
                ownerID = await MainActor.run { manager.start(task) }
                task.onComplete { [pageType, settings, destFile, ownerID] in
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
                                        DownloadDetailManager.shared.dismiss(ownerID: ownerID)
                                        settings.javaPopupMessage = "下载完成"
                                        settings.showJavaPopup = true
                                    }
                                } catch {
                                    await MainActor.run {
                                        DownloadDetailManager.shared.dismiss(ownerID: ownerID)
                                        settings.launchErrorMessage = "整合包安装失败: \(error.localizedDescription)"
                                        settings.showLaunchAlert = true
                                    }
                                }
                            }
                        } else {
                            DownloadDetailManager.shared.dismiss(ownerID: ownerID)
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
                task.start()
            } catch {
                // Sendable 闭包不可捕获 var：先拷贝成常量再进 MainActor.run
                let capturedOwner = ownerID
                await MainActor.run {
                    // 只操作全局单例与 settings（引用类型，生命周期与视图解耦）
                    // 只有本次确实 start 过才 dismiss（ownerID 非 nil 且归属一致才清），
                    // 否则绝不动管理器里可能正在进行的其它下载
                    if let capturedOwner {
                        DownloadDetailManager.shared.dismiss(ownerID: capturedOwner)
                    }
                    settings.launchErrorMessage = "下载失败: \(error.localizedDescription)"
                    settings.showLaunchAlert = true
                }
            }
        }
    }
}
