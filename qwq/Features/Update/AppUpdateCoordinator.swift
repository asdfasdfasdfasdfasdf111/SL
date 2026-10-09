//
//  AppUpdateCoordinator.swift
//  自动更新的编排层：检查 → 询问 → 下载 → 解包 → 换装 → 重启。
//
//  界面呈现走全局通知通道（NoticeCenter）：发现新版本是带按钮的可等待提示
//  （presentAndWait），下载进度是即发即弃的持续顶替提示（post，warning 级
//  不会自动消失）。换装必须交给一段**脱离本进程**的脚本执行——进程无法在
//  运行中替换自己的 bundle——脚本在退出后完成「移旧 → 拷新 → 重启 → 清理」，
//  任何一步失败旧 App 原地不动，调用方以 error 提示收场。
//

import AppKit
import Foundation

@MainActor
final class AppUpdateCoordinator {
    static let shared = AppUpdateCoordinator()
    /// 检查-更新进行中标志：启动自动检查与手动「检查更新」并发时只跑一个
    private var isWorking = false
    private init() {}

    /// 检查入口（帮助菜单「检查更新」手动触发）。
    /// `force`：手动检查时即使已是最新/检查失败也给反馈。
    /// 不再在启动时自动调用 —— 服务器版本由发布流程（GitHub Actions）自动同步，
    /// App 无需频繁轮询；用户需要时手动检查即可。
    func checkAndPromptIfNeeded(force: Bool = false) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let current = AppUpdateService.currentVersion()
        guard let release = await AppUpdateService.latestRelease() else {
            if force {
                NoticeCenter.shared.post(Notice(level: .warning, title: "检查更新失败",
                                                message: "无法连接更新服务器，请检查网络后重试"))
            }
            return
        }
        guard AppUpdateService.isNewer(release.tagName, than: current) else {
            if force {
                NoticeCenter.shared.post(Notice(level: .success, title: "已是最新版本",
                                                message: "当前版本 \(current) 已是最新"))
            }
            return
        }

        let notes = release.notes.isEmpty ? "可到 Release 页查看更新内容" : String(release.notes.prefix(300))
        let notice = Notice(
            level: .warning,
            title: "发现新版本 \(release.tagName)（当前 \(current)）",
            message: notes,
            buttons: [NoticeButton(label: "立即更新", style: .accent),
                      NoticeButton(label: "下次再说")])
        let choice = await NoticeCenter.shared.presentAndWait(notice)
        guard choice == 0 else { return }
        await performUpdate(release)
    }

    /// 下载 → 解包 → 换装重启。任一步失败都以 error 提示收场，旧 App 原地不动。
    private func performUpdate(_ release: AppUpdateService.AppRelease) async {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLUpdate-\(UUID().uuidString)", isDirectory: true)
        let packageURL = work.appendingPathComponent("update" + (release.downloadURL.pathExtension.isEmpty ? ".dmg" : "." + release.downloadURL.pathExtension))
        let extractDir = work.appendingPathComponent("extracted", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            postProgress(release, fraction: 0)
            try await AppUpdateService.download(release.downloadURL, to: packageURL) { [weak self] fraction in
                Task { @MainActor in self?.postProgress(release, fraction: fraction) }
            }
            let stagedApp: URL
            if packageURL.pathExtension.lowercased() == "dmg" {
                stagedApp = try mountAndExtract(dmg: packageURL)
            } else {
                stagedApp = try unzip(packageURL, to: extractDir)
            }
            NoticeCenter.shared.post(Notice(level: .warning, title: "更新下载完成",
                                            message: "正在退出并安装新版本…", buttons: []))
            try swapAndRelaunch(stagedApp: stagedApp, work: work)
        } catch {
            NoticeCenter.shared.post(Notice(level: .error, title: "自动更新失败",
                                            message: "\(error.localizedDescription)。当前版本未受影响，可稍后重试或到 GitHub 手动下载。"))
        }
    }

    /// dmg：挂载 → 找 .app → 拷贝到工作目录 → 卸载（dmg 是文件系统映像，
    /// 权限/符号链接/代码签名逐字节保留，不会出现 zip 解包后 App 打不开的问题）。
    private func mountAndExtract(dmg: URL) throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLMount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        // 1) 挂载：-nobrowse 不进 Finder，-readonly 免写权限问题，-mountpoint 固定点
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        try attach.run()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else { throw UpdateError.mountFailed }

        // 2) 找 .app 并拷贝出来（挂载点卸载后即失效，必须先拷出来）
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint.path, "-quiet"]
            try? detach.run()
            detach.waitUntilExit()
            try? FileManager.default.removeItem(at: mountPoint)
        }
        let contents = try FileManager.default.contentsOfDirectory(at: mountPoint,
                                                                   includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFound
        }
        // 拷到独立 staging 目录：换装脚本会 cp -R 到最终位置，来源用临时目录最稳
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLStaged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent(app.lastPathComponent)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/bin/cp")
        copy.arguments = ["-R", app.path, staged.path]
        try copy.run()
        copy.waitUntilExit()
        guard copy.terminationStatus == 0 else { throw UpdateError.copyFailed }
        return staged
    }

    /// zip：ditto --keepParent 打包（外层目录就是 qwq.app），ditto -x 解包
    /// 能保住可执行位——App bundle 里的主程序没有 +x 的话换装完就起不来。
    private func unzip(_ zipURL: URL, to extractDir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let unzipped = Process()
        unzipped.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzipped.arguments = ["-x", "-k", zipURL.path, extractDir.path]
        try unzipped.run()
        unzipped.waitUntilExit()
        guard unzipped.terminationStatus == 0 else { throw UpdateError.unzipFailed }

        let contents = try FileManager.default.contentsOfDirectory(at: extractDir,
                                                                   includingPropertiesForKeys: nil)
        guard let stagedApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFound
        }
        return stagedApp
    }

    private func postProgress(_ release: AppUpdateService.AppRelease, fraction: Double) {
        NoticeCenter.shared.post(Notice(level: .warning,
                                        title: "正在下载更新 \(release.tagName)",
                                        message: "\(Int(fraction * 100))%",
                                        buttons: []))
    }

    /// 换装脚本（脱离本进程执行）：等本进程退出 → 旧版挪走 → 新版就位 → 重启 → 清理。
    private func swapAndRelaunch(stagedApp: URL, work: URL) throws {
        let current = Bundle.main.bundleURL
        let old = current.appendingPathExtension("old")
        let quote = { (path: String) in "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        sleep 1
        rm -rf \(quote(old.path))
        mv \(quote(current.path)) \(quote(old.path))
        cp -R \(quote(stagedApp.path)) \(quote(current.path))
        open \(quote(current.path))
        sleep 2
        rm -rf \(quote(old.path)) \(quote(work.path))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try process.run()
        NSApp.terminate(nil)
    }

    private enum UpdateError: LocalizedError {
        case unzipFailed
        case mountFailed
        case copyFailed
        case appNotFound

        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "更新包解压失败"
            case .mountFailed: return "更新镜像（dmg）挂载失败"
            case .copyFailed: return "从更新包提取 App 失败"
            case .appNotFound: return "更新包里没有找到 App"
            }
        }
    }
}
