//
//  DropInstallCoordinatorTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//  1. 文件分流是唯一裁决点：`.jar` 走模组安装、`.zip` / `.mrpack` 走整合包安装，
//     其余扩展名一律忽略——误收文件会弹出错误的安装弹窗；
//  2. 扩展名判定大小写不敏感（`.ZIP` / `.MrPack` 必须与全小写等价）；
//  3. 失败路径不产生半成品状态：模组版本检测失败时必须只提示错误、
//     不得同时打开模组安装弹窗（否则用户会在空列表里点确认）；
//  4. 弹窗状态与暂存数据分离：cancel 只关弹窗；无暂存文件时确认按钮不得产生
//     「安装完成」这类假成功提示（对应实现里的 guard）；
//  5. `handle(providers:)` 的返回值语义：没有可接受的 file-url 内容时返回 false，
//     不得误判为已接受拖拽；
//  6. 弹窗状态变化必须发出 objectWillChange（否则 SwiftUI 不渲染弹窗）；
//  7. **成功安装路径**（本轮补上，此前完全无用例）：jar 能识别版本且匹配到实例时必须打开弹窗
//     并暂存匹配结果；确认后文件必须真的落到每个实例的 `versions/<版本>/mods`，
//     且按「全部成功 / 部分失败 / 全部失败」三种结果分别投递气泡、warning 横幅、error 横幅 ——
//     尤其不得把失败伪装成「已安装到 N 个实例」。驱动方式见下方夹具注释（注入点 + 临时目录）。
//
//  被测：App/ViewModels/DropInstallCoordinator.swift
//

import XCTest
import Combine
@testable import qwq

/// ⚠️ `@MainActor` 是**必需**的（与 `NoticeCenterTests` 同理）：`DropInstallCoordinator`
/// 现在显式标注为主 actor 隔离，用例体若不是主 actor 隔离就无法构造它、也读不到它的
/// `@Published` 字段（口径一实测：不加时报 `主 actor 隔离的初始化器不能从 actor 外调用`）。
@MainActor
final class DropInstallCoordinatorTests: XCTestCase {

    /// 无消息投递时的哨兵文案
    private let idlePopupMessage = "无消息"

    /// 本用例期间创建的临时目录（游戏根目录 / 待装文件所在目录），tearDown 统一删除
    private var tempRoots: [URL] = []

    override func setUp() {
        super.setUp()
        let settings = LauncherSettings.shared
        settings.javaPopupMessage = idlePopupMessage
        settings.showJavaPopup = false
        settings.showLaunchAlert = false
        settings.launchErrorMessage = nil
    }

    override func tearDown() {
        let settings = LauncherSettings.shared
        settings.showJavaPopup = false
        settings.showLaunchAlert = false
        settings.launchErrorMessage = nil
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    /// 构造一个稳定的临时路径（不落盘，协调器的分流只看扩展名）
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    // MARK: - 成功安装路径的夹具
    //
    //  为什么需要注入点：`ModVersionDetector` 要从真实 jar 里解出元数据，
    //  `ModDragInstaller.findInstances` 除用户选定根目录外还会**全盘扫描本机游戏目录**，
    //  两者都无法在测试里稳定落到一个受控实例上。注入后即可把实例指向临时目录，
    //  再断言「文件真的写进了游戏会加载的那个目录」。

    /// 建一个临时「游戏根目录」（用例结束由 tearDown 删除）
    private func makeTempRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qwqTests-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    /// 造一个「目标路径不是目录而是文件」的实例子目录，用来制造确定性的安装失败：
    /// `ModDragInstaller.install` 会在它下面 `createDirectory(at: <它>/versions/<版本>/mods)`，
    /// 父路径是文件时必然失败。
    private func makeBlockedRoot() throws -> URL {
        let blocker = try makeTempRoot().appendingPathComponent("这是一个文件，不是目录")
        try Data("blocker".utf8).write(to: blocker)
        return blocker
    }

    /// 造一个真实落盘的待装模组文件（安装只做拷贝，内容无关但需要可读，用于比对字节）
    private func makeModFile(named name: String = "示例模组.jar") throws -> (url: URL, data: Data) {
        let dir = try makeTempRoot()
        let url = dir.appendingPathComponent(name)
        let data = Data("fake-mod-bytes-\(name)".utf8)
        try data.write(to: url)
        return (url, data)
    }

    /// 造一个「前置决策已被固定」的协调器：版本检测恒返回 `versionRange`，实例匹配恒返回 `instances`
    private func makeInjectedCoordinator(versionRange: String = "1.20.1",
                                         instances: [GameInstance]) -> DropInstallCoordinator {
        DropInstallCoordinator(
            detectVersion: { _ in ModVersionDetector.ModVersionInfo(versionRange: versionRange, loader: "fabric") },
            findInstances: { _, _ in instances }
        )
    }

    /// 本次安装新增的横幅提示（`NoticeCenter.shared.history` 无重置接口；
    /// 单例历史会被先前用例污染，故一律按「新增了哪条」断言，不依赖绝对下标）
    private func newNotices(since before: Set<UUID>) -> [Notice] {
        NoticeCenter.shared.history.filter { !before.contains($0.id) }
    }

    private func currentNoticeIds() -> Set<UUID> {
        Set(NoticeCenter.shared.history.map(\.id))
    }

    // MARK: - 初始状态

    /// 初始态：两个弹窗关闭、暂存字段为空
    func testInitialState() async {
        let coordinator = DropInstallCoordinator()

        XCTAssertFalse(coordinator.showModInstallSheet)
        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertTrue(coordinator.modInstallInstances.isEmpty)
        XCTAssertEqual(coordinator.pendingModName, "")
        XCTAssertEqual(coordinator.pendingModVersion, "")
        XCTAssertEqual(coordinator.pendingModpackName, "")
    }

    // MARK: - 整合包分流

    /// .zip 直接进入安装位置选择，展示名取去扩展名的文件名
    func testZipOpensModpackInstallSheet() async {
        let coordinator = DropInstallCoordinator()

        coordinator.handle(urls: [url("我的整合包.zip")])

        XCTAssertTrue(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "我的整合包")
        XCTAssertFalse(coordinator.showModInstallSheet, "整合包不得走模组安装弹窗")
        XCTAssertNil(LauncherSettings.shared.launchErrorMessage)
    }

    /// .mrpack 与 .zip 同路径处理
    func testMrpackOpensModpackInstallSheet() async {
        let coordinator = DropInstallCoordinator()

        coordinator.handle(urls: [url("BetterMC.mrpack")])

        XCTAssertTrue(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "BetterMC")
    }

    /// 扩展名判定大小写不敏感
    func testPathExtensionMatchingIsCaseInsensitive() async {
        let upper = DropInstallCoordinator()
        upper.handle(urls: [url("PACK.ZIP")])
        XCTAssertTrue(upper.showModpackInstallSheet)
        XCTAssertEqual(upper.pendingModpackName, "PACK")

        let mixed = DropInstallCoordinator()
        mixed.handle(urls: [url("Mod.Pack.MrPack")])
        XCTAssertTrue(mixed.showModpackInstallSheet)
        XCTAssertEqual(mixed.pendingModpackName, "Mod.Pack")
    }

    // MARK: - 模组分流与失败路径

    /// 无法识别版本与加载器的 jar：只提示错误，不得打开模组安装弹窗
    func testJarWithoutDetectableVersionReportsErrorOnly() async {
        let coordinator = DropInstallCoordinator()
        let jar = url("qwqTests-\(UUID().uuidString).jar")

        coordinator.handle(urls: [jar])

        let name = jar.deletingPathExtension().lastPathComponent
        XCTAssertEqual(LauncherSettings.shared.launchErrorMessage,
                       "无法检测模组「\(name)」的 Minecraft 版本")
        XCTAssertTrue(LauncherSettings.shared.showLaunchAlert)
        XCTAssertFalse(coordinator.showModInstallSheet,
                       "前置条件不满足时打开空弹窗会让用户对着空列表点确认")
        XCTAssertEqual(coordinator.pendingModName, "")
        XCTAssertTrue(coordinator.modInstallInstances.isEmpty)
    }

    /// 不支持的类型一律忽略：不弹窗、不提示、不产生任何暂存数据
    func testUnsupportedExtensionsAreIgnored() async {
        let coordinator = DropInstallCoordinator()
        let ignored = ["notes.txt", "archive.zipx", "mod.jar.txt", "无扩展名", "数据.json", "pack.7z"]

        coordinator.handle(urls: ignored.map(url))

        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertFalse(coordinator.showModInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "")
        XCTAssertEqual(coordinator.pendingModName, "")
        XCTAssertNil(LauncherSettings.shared.launchErrorMessage)
        XCTAssertEqual(LauncherSettings.shared.javaPopupMessage, idlePopupMessage,
                       "被忽略的文件不得产生任何用户可见提示")
    }

    /// 空列表是 no-op
    func testEmptyURLListIsNoOp() async {
        let coordinator = DropInstallCoordinator()

        coordinator.handle(urls: [])

        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertFalse(coordinator.showModInstallSheet)
    }

    /// 混合批次只处理可安装文件，忽略项不得干扰暂存数据
    func testBatchRouteHandlesOnlyInstallableFiles() async {
        let coordinator = DropInstallCoordinator()

        coordinator.handle(urls: [url("说明.txt"), url("整合包.zip"), url("图片.png")])

        XCTAssertTrue(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "整合包")
    }

    /// 一批多个整合包时以最后一个为暂存目标（逐个分流、后写覆盖）
    func testBatchRouteKeepsLastModpackAsPendingTarget() async {
        let coordinator = DropInstallCoordinator()

        coordinator.handle(urls: [url("第一个.zip"), url("第二个.mrpack")])

        XCTAssertTrue(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "第二个")
    }

    /// jar 失败与整合包成功混投：两条分支互不掩盖，均按各自语义执行
    func testJarFailureAndModpackSuccessAreBothHandled() async {
        let coordinator = DropInstallCoordinator()
        let jar = url("qwqTests-\(UUID().uuidString).jar")

        coordinator.handle(urls: [jar, url("整合包.zip")])

        XCTAssertTrue(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "整合包")
        XCTAssertNotNil(LauncherSettings.shared.launchErrorMessage)
        XCTAssertFalse(coordinator.showModInstallSheet)
    }

    // MARK: - 取消与确认

    /// 取消整合包安装只关弹窗；暂存数据保留（下次确认仍指向同一文件）
    func testCancelModpackInstallClosesSheetOnly() async {
        let coordinator = DropInstallCoordinator()
        coordinator.handle(urls: [url("整合包.zip")])
        XCTAssertTrue(coordinator.showModpackInstallSheet)

        coordinator.cancelModpackInstall()

        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertEqual(coordinator.pendingModpackName, "整合包",
                       "取消只关弹窗，不清暂存名（当前实现的既有行为）")
    }

    /// 无暂存文件时确认整合包安装是 no-op：不落盘、不提示、不崩溃
    func testConfirmModpackInstallWithoutStagedFileIsNoOp() async {
        let coordinator = DropInstallCoordinator()

        coordinator.confirmModpackInstall(folderURL: url("目标目录"))

        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertEqual(LauncherSettings.shared.javaPopupMessage, idlePopupMessage,
                       "无暂存整合包时不得产生任何成功/失败提示")
        XCTAssertFalse(LauncherSettings.shared.showLaunchAlert)
    }

    /// 无暂存模组时确认模组安装不得报「已安装到 N 个实例」
    func testConfirmModInstallWithoutStagedFileReportsNothing() async {
        let coordinator = DropInstallCoordinator()

        coordinator.confirmModInstall(instances: [])

        XCTAssertFalse(coordinator.showModInstallSheet)
        XCTAssertEqual(LauncherSettings.shared.javaPopupMessage, idlePopupMessage,
                       "guard 失效会让用户看到「模组已安装到 0 个实例」这类假成功文案")
        XCTAssertFalse(LauncherSettings.shared.showJavaPopup)
    }

    /// 弹窗未展示时取消模组安装是幂等 no-op
    func testCancelModInstallIsIdempotentWhenSheetHidden() async {
        let coordinator = DropInstallCoordinator()

        coordinator.cancelModInstall()
        coordinator.cancelModInstall()

        XCTAssertFalse(coordinator.showModInstallSheet)
        XCTAssertTrue(coordinator.modInstallInstances.isEmpty)
        XCTAssertEqual(coordinator.pendingModName, "")
    }

    // MARK: - 成功安装路径：进入弹窗

    /// jar 能识别版本且匹配到实例 → 打开模组安装弹窗，并暂存待装文件与匹配结果
    func testJarWithDetectedVersionAndMatchedInstanceOpensModSheet() async throws {
        let (jar, _) = try makeModFile()
        let root = try makeTempRoot()
        let coordinator = makeInjectedCoordinator(instances: [GameInstance(rootPath: root.path, version: "1.20.1")])

        coordinator.handle(urls: [jar])

        XCTAssertTrue(coordinator.showModInstallSheet)
        XCTAssertFalse(coordinator.showModpackInstallSheet, "模组不得走整合包弹窗")
        XCTAssertEqual(coordinator.pendingModName, jar.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(coordinator.pendingModVersion, "1.20.1")
        XCTAssertEqual(coordinator.modInstallInstances.map(\.rootPath), [root.path])
        XCTAssertNil(LauncherSettings.shared.launchErrorMessage)
    }

    /// 版本能识别但一个实例都不匹配 → 只提示错误，不得打开空弹窗
    /// （反向：删掉 `beginModInstall` 里的 `!instances.isEmpty` 守卫，本用例即变红）
    func testJarWithoutMatchedInstanceReportsErrorOnly() async throws {
        let (jar, _) = try makeModFile()
        let coordinator = makeInjectedCoordinator(instances: [])

        coordinator.handle(urls: [jar])

        let name = jar.deletingPathExtension().lastPathComponent
        XCTAssertEqual(LauncherSettings.shared.launchErrorMessage,
                       "未找到与模组「\(name)」（需要 1.20.1）匹配的游戏版本")
        XCTAssertTrue(LauncherSettings.shared.showLaunchAlert)
        XCTAssertFalse(coordinator.showModInstallSheet)
        XCTAssertTrue(coordinator.modInstallInstances.isEmpty)
        XCTAssertEqual(coordinator.pendingModName, "")
    }

    /// 一批多个 jar：逐个分流、后写覆盖暂存目标 —— 确认时装的必须是**暂存的那一个**
    /// （只比对 `pendingModName` 不够：暂存 URL 与展示名是两个字段，可能只有一个被覆盖）
    func testBatchOfJarsKeepsLastAsPendingTarget() async throws {
        let (first, _) = try makeModFile(named: "第一个.jar")
        let (second, _) = try makeModFile(named: "第二个.jar")
        let root = try makeTempRoot()
        let coordinator = makeInjectedCoordinator(instances: [GameInstance(rootPath: root.path, version: "1.20.1")])

        coordinator.handle(urls: [first, second])
        XCTAssertEqual(coordinator.pendingModName, "第二个")

        coordinator.confirmModInstall(instances: coordinator.modInstallInstances)

        let modsDir = root.appendingPathComponent("versions/1.20.1/mods")
        XCTAssertTrue(FileManager.default.fileExists(atPath: modsDir.appendingPathComponent("第二个.jar").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: modsDir.appendingPathComponent("第一个.jar").path),
                       "批次里第一个文件被装上了 —— 暂存目标未随后一个 jar 覆盖")
    }

    // MARK: - 成功安装路径：确认安装（核心）

    /// 确认安装：模组必须真的落到**每个**匹配实例的 `versions/<版本>/mods`，并投递成功气泡。
    /// 落盘目录按游戏 `game_directory` 口径（版本运行目录），写到游戏根目录游戏不会加载。
    func testConfirmModInstallCopiesModToEveryInstanceAndReportsCount() async throws {
        let (jar, data) = try makeModFile()
        let first = try makeTempRoot()
        let second = try makeTempRoot()
        let coordinator = makeInjectedCoordinator(instances: [
            GameInstance(rootPath: first.path, version: "1.20.1"),
            GameInstance(rootPath: second.path, version: "1.20.1"),
        ])
        coordinator.handle(urls: [jar])
        XCTAssertTrue(coordinator.showModInstallSheet, "前置条件：本轮要验证的是成功路径")
        let noticesBefore = currentNoticeIds()

        coordinator.confirmModInstall(instances: coordinator.modInstallInstances)

        for root in [first, second] {
            let installed = root.appendingPathComponent("versions/1.20.1/mods/\(jar.lastPathComponent)")
            XCTAssertEqual(try Data(contentsOf: installed), data,
                           "模组未落到 \(root.lastPathComponent) 的版本运行目录 —— 游戏只从该目录加载 mods")
        }
        XCTAssertEqual(LauncherSettings.shared.javaPopupMessage, "模组已安装到 2 个实例")
        XCTAssertTrue(LauncherSettings.shared.showJavaPopup)
        XCTAssertEqual(newNotices(since: noticesBefore).count, 0,
                       "全部成功时不得再投递横幅提示（与气泡重复提示同一件事）")
        XCTAssertFalse(coordinator.showModInstallSheet, "安装结束后弹窗必须关闭")
    }

    /// 部分失败：能写的实例真的装上、写不进去的实例给出原因，投递 warning 横幅，
    /// 且**不**投递「已安装到 N 个实例」这种只说成功数的气泡
    func testConfirmModInstallPartialFailureWarnsAndCopiesOnlyReachableInstance() async throws {
        let (jar, data) = try makeModFile()
        let good = try makeTempRoot()
        let blocked = try makeBlockedRoot()
        let coordinator = makeInjectedCoordinator(instances: [
            GameInstance(rootPath: good.path, version: "1.20.1"),
            GameInstance(rootPath: blocked.path, version: "1.20.1"),
        ])
        coordinator.handle(urls: [jar])
        let noticesBefore = currentNoticeIds()

        coordinator.confirmModInstall(instances: coordinator.modInstallInstances)

        XCTAssertEqual(try Data(contentsOf: good.appendingPathComponent("versions/1.20.1/mods/\(jar.lastPathComponent)")),
                       data,
                       "可写实例必须照常装上，部分失败不得整体放弃")
        let added = newNotices(since: noticesBefore)
        XCTAssertEqual(added.count, 1, "部分失败应恰好投递一条横幅")
        XCTAssertEqual(added.first?.level, .warning)
        XCTAssertEqual(added.first?.title, "部分实例安装失败")
        XCTAssertTrue(added.first?.message.contains("已安装到 1 个实例") == true,
                      "实际文案：\(added.first?.message ?? "无")")
        XCTAssertTrue(added.first?.message.contains(blocked.path) == true,
                      "失败原因必须带上是哪个实例，否则用户不知道该去关哪个游戏")
        XCTAssertEqual(LauncherSettings.shared.javaPopupMessage, idlePopupMessage,
                       "部分失败时只报成功数会让用户以为全部装上了")
        XCTAssertFalse(coordinator.showModInstallSheet)
    }

    /// 全部失败：投递 error 横幅并列出每个实例的原因，且不得留下「已安装到 0 个实例」的假成功气泡
    func testConfirmModInstallTotalFailureReportsErrorWithEveryReason() async throws {
        let (jar, _) = try makeModFile()
        let firstBlocker = try makeBlockedRoot()
        let secondBlocker = try makeBlockedRoot()
        let coordinator = makeInjectedCoordinator(instances: [
            GameInstance(rootPath: firstBlocker.path, version: "1.20.1"),
            GameInstance(rootPath: secondBlocker.path, version: "1.20.1"),
        ])
        coordinator.handle(urls: [jar])
        let noticesBefore = currentNoticeIds()

        coordinator.confirmModInstall(instances: coordinator.modInstallInstances)

        let added = newNotices(since: noticesBefore)
        XCTAssertEqual(added.count, 1, "全部失败应恰好投递一条横幅")
        XCTAssertEqual(added.first?.level, .error)
        XCTAssertEqual(added.first?.title, "模组安装失败")
        let message = added.first?.message ?? ""
        XCTAssertTrue(message.contains("未能安装到任何实例（共 2 个）"), "实际文案：\(message)")
        XCTAssertTrue(message.contains(firstBlocker.path), "两个失败实例都要出现。实际文案：\(message)")
        XCTAssertTrue(message.contains(secondBlocker.path), "两个失败实例都要出现。实际文案：\(message)")
        XCTAssertEqual(LauncherSettings.shared.javaPopupMessage, idlePopupMessage,
                       "全部失败时不得留下「已安装到 0 个实例」这类假成功文案")
        XCTAssertFalse(LauncherSettings.shared.showJavaPopup)
        XCTAssertFalse(coordinator.showModInstallSheet)
    }

    // MARK: - 拖拽入口返回值

    /// 没有 file-url 内容的 provider 一律不接受（含 Text 类型）
    func testHandleProvidersRejectsNonFileContent() async {
        let coordinator = DropInstallCoordinator()

        XCTAssertFalse(coordinator.handle(providers: []), "空 provider 列表不得被视为已接受")
        XCTAssertFalse(coordinator.handle(providers: [NSItemProvider()]),
                       "空 provider 不含 public.file-url，必须返回 false")
        XCTAssertFalse(coordinator.handle(providers: [NSItemProvider(object: "纯文本" as NSString)]),
                       "文本拖拽不得被当作文件拖入接受")

        XCTAssertFalse(coordinator.showModpackInstallSheet)
        XCTAssertFalse(coordinator.showModInstallSheet)
    }

    // MARK: - 状态发布

    /// 打开整合包弹窗时两个 @Published 字段都要通知订阅方
    func testSheetStateChangesEmitObjectWillChange() async {
        let coordinator = DropInstallCoordinator()
        var emissions = 0
        let cancellable = coordinator.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        coordinator.handle(urls: [url("整合包.zip")])

        XCTAssertGreaterThanOrEqual(emissions, 2,
                                    "pendingModpackName 与 showModpackInstallSheet 各需一次通知，否则弹窗不渲染")
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. `handle(providers:)` 的 true 分支不覆盖：`DragDropHandler` 通过
//     `NSItemProvider.loadItem` 异步回调 + `DispatchQueue.main.async` 派发，
//     需要宿主 App 跑 run loop，且 `item as? Data` 的形态随系统版本变化，
//     无法在不引入时序脆弱性的前提下稳定断言。
//  2. 真实的 `ModVersionDetector.detectVersion` / `ModDragInstaller.findInstances` 不在用例里驱动
//     —— **不是因为没有注入点（已有），而是因为驱动它们会写用户的真实游戏目录**：
//     · `detectVersion` 要一个含 `fabric.mod.json` 等元数据的真实 jar（要起 `unzip` 子进程，
//       属 `ModVersionDetector` 自身该覆盖的范围，见 §4.5 的后续计划）；
//     · `findInstances` 除「选定根目录」外还会全盘扫描本机真实游戏目录，且对每个扫到的根目录
//       调 `MinecraftVersionManager.getVersions` → 内部 `normalizeVersionFolderNames`
//       **会重命名磁盘上的版本文件夹并改写其中的 json**（是测试不该触发的写副作用）。
//     本文件因此一律走注入替身，把实例指向临时目录 —— 断言的是「协调器拿到的结果怎么处理」，
//     而 `findInstances` 自身的匹配规则（含 `savedRoot` 分支）仍无用例。
//  3. `confirmModpackInstall(folderURL:)` 的成功分支**不可达**（不是「没测」）：
//     `ModpackInstaller.install` 的最后一步 `installLoader` 无条件抛
//     `InstallError.loaderInstallUnsupported`（这是刻意为之，见其文档注释：宁可真失败，
//     也不假装装上加载器），因此 `presentMessage("整合包安装完成")` 永远执行不到。
//     失败分支要真正联网（`installMinecraft` 先打 launchermeta 官方源）才能走到，属集成测试范畴。
//  4. `GameInstance` 的 `Equatable` 是**按包含 `UUID id` 合成**出来的（两个字段相同的实例并不相等），
//     故本文件一律按字段比较；工程内也没有任何地方依赖它的值相等（选实例走 `id`）。
