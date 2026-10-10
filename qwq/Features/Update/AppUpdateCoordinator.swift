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

    /// 检查入口（App 启动自动检查 / 帮助菜单「检查更新…」手动检查共用）。
    /// `force`：手动检查时即使已是最新/检查失败也给反馈；自动检查静默（失败不打扰）。
    ///
    /// 排他：`isWorking` 保证启动自动检查与手动检查并发时只跑一次。
    func checkAndPromptIfNeeded(force: Bool = false) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let current = AppUpdateService.currentVersion()
        log("[Update] 开始检查更新：当前版本 \(current)")
        guard let release = await AppUpdateService.latestRelease() else {
            err("[Update] 检查更新失败：无法连接更新服务器（不打扰用户）")
            if force {
                NoticeCenter.shared.post(Notice(level: .warning, title: "检查更新失败",
                                                message: "无法连接更新服务器，请检查网络后重试"))
            }
            return
        }
        guard AppUpdateService.isNewer(release.tagName, than: current) else {
            log("[Update] 已是最新：服务器 \(release.tagName)")
            if force {
                NoticeCenter.shared.post(Notice(level: .success, title: "已是最新版本",
                                                message: "当前版本 \(current) 已是最新"))
            }
            return
        }
        log("[Update] 发现新版本 \(release.tagName)（当前 \(current)），等待用户选择")

        let notice = AppUpdateCoordinator.makeUpdateNotice(release: release, current: current)
        let choice = await NoticeCenter.shared.presentAndWait(notice)
        guard choice == 0 else {
            log("[Update] 用户选择稍后（下标 \(choice)），本次不更新")
            return
        }
        log("[Update] 用户选择立即更新")
        await performUpdate(release)
    }

    /// 构造「发现新版本」提示（纯函数，便于单测钉住下面这条安全属性）。
    ///
    /// ⚠️ **安全属性（不可改）**：`fallbackChoiceIndex` 必须指向「下次再说」。
    /// 更新提示是**启动时自动弹**的，用户完全可能在忙别的、或直接点右上角 ×。
    /// 若隐式应答落在下标 0（=「立即更新」），那么「没理会弹窗」就等于
    /// 「自动下载、替换 App 并重启」——无人值守时会真的把 App 换掉。
    /// 只有真人点「立即更新」才允许进入下载换装。
    static func makeUpdateNotice(release: AppUpdateService.AppRelease, current: String) -> Notice {
        let notes = release.notes.isEmpty ? "可到 Release 页查看更新内容" : String(release.notes.prefix(300))
        return Notice(
            level: .warning,
            title: "发现新版本 \(release.tagName)（当前 \(current)）",
            message: notes,
            buttons: [NoticeButton(label: "立即更新", style: .accent),
                      NoticeButton(label: "下次再说")],
            fallbackChoiceIndex: 1)
    }

    /// 启动后的自动检查（冷启动各调一次）。**必须由调用方在 UI 起来之后再延迟触发**，
    /// 原因见 `AppDelegate` 的延迟说明：太早会与首帧 / 目录预热抢资源。
    ///
    /// 测试宿主拦截：`xcodebuild test` 会把 App 真启动起来（`applicationDidFinishLaunching`
    /// 照跑），若不拦，跑一次用例就会去访问更新服务器 —— 而本工程测试套件的既定约束是
    /// **不碰网络**。判据用 XCTest 注入的环境变量（hosted test 必带），比「有没有链接 XCTest」
    /// 准确：后者在生产包里也可能为真。
    static func checkOnLaunch() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        await shared.checkAndPromptIfNeeded()
    }

    /// 下载 → 解包 → 换装重启。任一步失败都以 error 提示收场，旧 App 原地不动。
    private func performUpdate(_ release: AppUpdateService.AppRelease) async {
        progressNoticeID = nil   // 新一轮下载用新卡片（重试时不会续用上一张已关闭的）
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLUpdate-\(UUID().uuidString)", isDirectory: true)
        let packageURL = work.appendingPathComponent("update" + (release.downloadURL.pathExtension.isEmpty ? ".dmg" : "." + release.downloadURL.pathExtension))
        let extractDir = work.appendingPathComponent("extracted", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            log("[Update] 开始下载 \(release.downloadURL.absoluteString)")
            postProgress(release, fraction: 0)
            try await AppUpdateService.download(release.downloadURL, to: packageURL) { [weak self] fraction in
                Task { @MainActor in self?.postProgress(release, fraction: fraction) }
            }
            // 记字节数：为 0 说明服务端回的是空响应（历史上踩过「探测 Range 后整包拿到 304」
            // 与「挂载空 dmg 失败」，只靠 UI 通知查不出是哪一种）。
            let attrs = try? FileManager.default.attributesOfItem(atPath: packageURL.path)
            let downloaded = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            log("[Update] 下载结束：\(downloaded) 字节 → \(packageURL.lastPathComponent)")
            let stagedApp: URL
            if packageURL.pathExtension.lowercased() == "dmg" {
                stagedApp = try mountAndExtract(dmg: packageURL)
            } else {
                stagedApp = try unzip(packageURL, to: extractDir)
            }
            log("[Update] 解包完成：\(stagedApp.path)")
            NoticeCenter.shared.post(Notice(level: .warning, title: "更新下载完成",
                                            message: "正在退出并安装新版本…", buttons: []))
            log("[Update] 启动换装脚本并退出（旧包备份为 .old，脚本见 swapAndRelaunch）")
            try swapAndRelaunch(stagedApp: stagedApp, work: work)
        } catch {
            err("[Update] 自动更新失败：\(error.localizedDescription)")
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

    /// 下载进度提示的固定 id：整段下载只对应**一张**卡片。
    /// 每次 `post` 一条新 id 的提示会让 overlay 按 `.id(notice.id)` 重建卡片、重放出现动画
    /// （用户反馈的「进度条抽搐」），所以首次 `post`、之后一律走 `update` 就地刷新。
    private var progressNoticeID: UUID?

    private func postProgress(_ release: AppUpdateService.AppRelease, fraction: Double) {
        let clamped = max(0, min(1, fraction))
        let percent = Int((clamped * 100).rounded())
        let id = progressNoticeID ?? UUID()
        progressNoticeID = id
        let notice = Notice(id: id,
                            level: .warning,
                            title: "正在下载更新 \(release.tagName)",
                            message: "\(percent)%",
                            buttons: [],
                            progress: clamped)
        if NoticeCenter.shared.current?.id == id {
            NoticeCenter.shared.update(notice)   // 就地刷新：动画只作用在进度条上
        } else {
            NoticeCenter.shared.post(notice)     // 首次出现（或上一张已被顶替）
        }
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
