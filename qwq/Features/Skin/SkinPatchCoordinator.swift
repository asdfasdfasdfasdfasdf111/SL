//
//  SkinPatchCoordinator.swift
//  高清皮肤补丁（CustomSkinLoader）询问卡片的**编排者**
//
//  职责边界（三层分离，别把代码放错层）：
//  - `SkinHDSupport` —— 纯逻辑：尺寸分类、版本 id 拆分、降采样、文案生成。不联网、不写盘。
//  - `SkinPatchCatalog` —— 取数层：查 Modrinth 最新可用补丁、把 jar 装进 mods 目录。
//  - 本类型 —— 编排层：读工程状态（当前版本 / 游戏根目录）→ 调取数层 → 把结果收敛成一份
//    **视图可直接渲染的窄状态**（`SkinPatchState`）。不发 HTTP、不拼文案、不画界面。
//  - `SkinPatchCardView` —— 界面层：只订阅 `state` 渲染，不自己查网络、不自己读 settings。
//
//  为什么状态要「窄」：状态里若塞进 `ModrinthVersion` 原对象，视图就得知道网络模型；
//  且它不可比较（非 Equatable），SwiftUI 的 `animation(value:)` 用不了。于是这里只暴露
//  界面真正需要的字段（尺寸文案 / 版本号 / 文件名 / 加载器名），原对象留在 `Patch` 里。
//
//  线程约定：本类型是 `@MainActor`（`@Published` 只允许主线程写）。网络与磁盘的 `await`
//  在 `Task` 内挂起时不阻塞主线程，恢复后自动回到主 actor，故所有状态赋值天然在主线程。
//  任务句柄统一持有并在「重新查询 / 关闭卡片」时 `cancel()`，避免旧结果覆盖新状态。
//

import SwiftUI
import Combine

// MARK: - 触发通知

extension Notification.Name {
    /// 用户选完皮肤、尺寸已分类完成。
    ///
    /// - `userInfo["pixelSize"]` 有值 → 该尺寸原版不支持但**整倍数可救**，界面应弹补丁询问卡片；
    /// - `userInfo["pixelSize"]` 缺失 → 原版尺寸（或尺寸不合法被拒），界面应**收起**先前那张卡片。
    ///
    /// 为什么用通知而不是让 `OfflineSkinService` 直接调本类型：`OfflineSkinService` 是
    /// **无视图依赖**的静态服务（不持有 `@StateObject`），而协调器的生命周期绑在
    /// `CategoryContentView` 上。用通知解耦这两者，与工程内既有的
    /// `closeGameSession` / `GameVersionSelected` 是同一种做法。
    static let skinSizeClassified = Notification.Name("skinSizeClassified")
}

// MARK: - 状态

/// 询问卡片的展示状态。
///
/// ⚠️ **刻意不做 `Equatable`**：`available` 分支携带的 `SkinPatchCatalog.Patch` 内含
/// `ModrinthVersion`（网络模型，非 Equatable），一路加 `==` 会污染到网络模型层。
/// 视图侧改用 `presentationKey`（一个稳定的字符串判别式）驱动动画即可。
enum SkinPatchState {

    /// 不显示卡片（初始态 / 用户关闭后）
    case hidden

    /// 正在向 Modrinth 查询（卡片显示转圈）
    case checking(pixelSize: String)

    /// **可安装** —— 卡片高光 + 右下角「下载」按钮
    case available(patch: SkinPatchCatalog.Patch, pixelSize: String,
                   gameVersion: String, loader: ModLoader?)

    /// 有加载器，但上游没有适配当前游戏版本的补丁（典型：每周快照，上游只发正式版）
    case noPatch(pixelSize: String, gameVersion: String, loader: ModLoader?)

    /// 当前版本是原版（未装加载器）—— 模组根本无法被加载，装补丁这条路不存在
    case noLoader(pixelSize: String, gameVersion: String)

    /// 还没选游戏版本 —— 无从判断该装哪个版本的补丁
    case noVersion(pixelSize: String)

    /// 查询失败（网络等）
    case failed(pixelSize: String, reason: String)

    /// 安装中（卡片显示进度）
    case installing(pixelSize: String, versionNumber: String)

    /// 安装完成
    case installed(pixelSize: String, filename: String)

    /// 安装失败
    case installFailed(pixelSize: String, reason: String)

    /// 卡片是否可见。`hidden` 之外一律可见 —— 包括失败态：
    /// 失败必须让用户看见原因，而不是静默把卡片收掉。
    var isVisible: Bool {
        if case .hidden = self { return false }
        return true
    }

    /// 是否处于「可安装」态。卡片的**高光**（accent 描边）与「下载」按钮据此显示 ——
    /// 与加载器选择卡的选中高光同一语义：只有真的能点的状态才高亮，避免高光变成纯装饰。
    var canInstall: Bool {
        if case .available = self { return true }
        return false
    }

    /// 供 SwiftUI 动画做 value 比较的稳定标识（状态内容变了才重播动画，不是每帧都播）。
    var presentationKey: String {
        switch self {
        case .hidden:                       return "hidden"
        case .checking:                     return "checking"
        case .available(_, _, _, let l):    return "available-\(l?.rawValue ?? "none")"
        case .noPatch:                      return "noPatch"
        case .noLoader:                     return "noLoader"
        case .noVersion:                    return "noVersion"
        case .failed:                       return "failed"
        case .installing:                   return "installing"
        case .installed:                    return "installed"
        case .installFailed:                return "installFailed"
        }
    }

    /// 展示用尺寸文案（各分支都带，收敛成一个读取口，免得视图里写 switch）。
    var pixelSize: String {
        switch self {
        case .hidden:                                   return ""
        case .checking(let s):                          return s
        case .available(_, let s, _, _):                return s
        case .noPatch(let s, _, _):                     return s
        case .noLoader(let s, _):                       return s
        case .noVersion(let s):                         return s
        case .failed(let s, _):                         return s
        case .installing(let s, _):                     return s
        case .installed(let s, _):                      return s
        case .installFailed(let s, _):                  return s
        }
    }
}

// MARK: - 编排者

/// 高清皮肤补丁询问卡片的状态机与副作用编排。
///
/// 生命周期：由 `CategoryContentView` 以 `@StateObject` 持有（与同页的
/// `LaunchAvatarSkinViewModel` 一致 —— 自己创建、绑在视图上），视图经
/// `.onReceive(NotificationCenter…skinNeedsPatch)` 驱动 `beginCheck(pixelSize:)`。
@MainActor
final class SkinPatchCoordinator: ObservableObject {

    /// 当前状态。视图**只读**，改写一律经本类型的方法（保证状态迁移与副作用成对发生）。
    @Published private(set) var state: SkinPatchState = .hidden

    /// 在飞任务的唯一句柄。重新查询或关闭卡片时取消，防止旧请求的结果回写覆盖新状态
    /// （典型竞态：连选两张皮肤，先发的慢请求后到，把新尺寸的卡片内容冲掉）。
    private var task: Task<Void, Never>?

    private var settings: LauncherSettings { LauncherSettings.shared }

    /// 游戏根目录 —— 与 `OfflineSkinService` / `ModDownloader.autoDownloadMod` 同一口径：
    /// 用户显式设过就用它，否则取「当前 Minecraft 目录」。
    private var resolvedGameRoot: String {
        settings.selectedGameRoot.isEmpty
            ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "")
            : settings.selectedGameRoot
    }

    // MARK: - 查询

    /// 收到「选中了高清皮肤」后开始查询。
    ///
    /// 三条前置校验按「最可能的失败原因」排序，且**各自给出不同的状态**（而不是统一报错）——
    /// 因为三者的出路完全不同：没选版本 → 去选版本；原版 → 去装加载器；有加载器 → 等上游或换皮肤。
    /// - Parameter pixelSize: 尺寸文案（如 `128×128`），直接进卡片正文
    func beginCheck(pixelSize: String) {
        task?.cancel()
        task = nil

        let versionID = settings.selectedMinecraftVersion
        guard !versionID.isEmpty else {
            state = .noVersion(pixelSize: pixelSize)
            return
        }

        // ⚠️ 必须拆出**纯游戏版本**：Modrinth 的 game_versions 里没有 `1.21.1-Fabric` 这种
        // 带加载器后缀的 id，拿 id 直接过滤会一条都查不到（表现为「上游明明有、就是查不到」）。
        let gameVersion = SkinVersionIdentity.minecraftVersion(from: versionID)
        guard let loader = SkinVersionIdentity.loader(from: versionID) else {
            state = .noLoader(pixelSize: pixelSize, gameVersion: gameVersion)
            return
        }

        state = .checking(pixelSize: pixelSize)
        task = Task { [weak self] in
            do {
                let patch = try await SkinPatchCatalog.latest(gameVersion: gameVersion, loader: loader)
                guard let self, !Task.isCancelled else { return }
                self.state = .available(patch: patch, pixelSize: pixelSize,
                                        gameVersion: gameVersion, loader: loader)
            } catch {
                guard let self, !Task.isCancelled else { return }
                // 「没有适配版本」是可预期的业务结果（快照版就是没有），单独成一态给出可行动建议；
                // 其余（HTTP 状态码错误、解码失败等）才是真失败，把原始文案带出去便于排查。
                if case ModDownloader.ModError.noCompatibleVersion = error {
                    self.state = .noPatch(pixelSize: pixelSize, gameVersion: gameVersion, loader: loader)
                } else {
                    self.state = .failed(pixelSize: pixelSize, reason: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 安装

    /// 把已查到的补丁装进当前版本的 mods 目录。
    ///
    /// 仅在 `.available` 态有意义（其余状态是空操作）—— 卡片只在该态渲染下载按钮，
    /// 这里的守卫是防御性的：万一被别处误调，也不会拿 nil 去下载。
    func install() {
        guard case .available(let patch, let pixelSize, _, _) = state else { return }

        let versionID = settings.selectedMinecraftVersion
        let gameRoot = resolvedGameRoot
        guard !versionID.isEmpty else {
            state = .installFailed(pixelSize: pixelSize, reason: "未选择游戏版本")
            return
        }
        guard !gameRoot.isEmpty else {
            state = .installFailed(pixelSize: pixelSize, reason: "未设置游戏根目录")
            return
        }

        // 先取消查询任务再起安装任务：同一句柄不能同时管两件事
        task?.cancel()
        state = .installing(pixelSize: pixelSize, versionNumber: patch.versionNumber)
        task = Task { [weak self] in
            do {
                let url = try await SkinPatchCatalog.install(patch, gameRoot: gameRoot, versionID: versionID)
                guard let self, !Task.isCancelled else { return }
                self.state = .installed(pixelSize: pixelSize, filename: url.lastPathComponent)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .installFailed(pixelSize: pixelSize, reason: error.localizedDescription)
            }
        }
    }

    // MARK: - 关闭

    /// 关闭卡片并把状态复位。
    ///
    /// 取消在飞任务：安装中途关卡片时，若放任任务跑完，`installed` 会写进已关闭的卡片
    /// （用户看不到，下次选皮肤时又莫名带着旧状态）。取消后状态停在 `.hidden`，干净。
    func dismiss() {
        task?.cancel()
        task = nil
        state = .hidden
    }
}
