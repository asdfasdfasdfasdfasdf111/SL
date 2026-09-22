import Foundation
import SwiftUI
import Combine

// MARK: - Extensions
extension URL {
    /// 取父目录（等价于 `deletingLastPathComponent()`）。
    /// 使用方：`SLCore/Minecraft/Mod/Loader/Fabric/FabricInstaller.swift:24`、
    /// `SLCore/Minecraft/Mod/Loader/Forge/ForgeInstaller.swift:175,237,253`、
    /// `SLCore/Minecraft/Launch/MinecraftLauncher.swift:110,114`、
    /// `SLCore/Minecraft/Download/MinecraftInstaller.swift:373`、
    /// `SLCore/Java/JavaVirtualMachine.swift:82,83,111`、
    /// `SLCore/Storage/CacheStorage.swift:80,109`、`SLCore/Temp/TemperatureDirectory.swift:26`、
    /// `SLCore/FileManagerExtension.swift:17`。
    public func parent() -> URL { deletingLastPathComponent() }

    /// 兼容层遗留接口：全库（含 `qwqTests`）无任何引用，待清理。
    /// 语义上也只是把 `~` 展开后转交 `init(fileURLWithPath:)`，无独立价值。
    @available(*, deprecated, message: "全库无引用，待清理")
    public init(fileURLWithUserPath: String) {
        self.init(fileURLWithPath: fileURLWithUserPath.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path))
    }
}

// MARK: - Hint function
/// 轻量提示。**已接入真实提示通道**（`NoticeCenter` → 根视图上的 `NoticeOverlay`）。
///
/// 行为：写一条日志，并把消息按级别转成 `Notice` 投递到 `NoticeCenter`，
/// 用户会在界面顶部看到对应横幅（`info` / `success` 自动消失，`warning` / `error` 需手动关闭）。
/// 投递是异步且线程安全的，因此本函数可从任意线程调用，调用后不会阻塞等待。
///
/// 使用方：`SLCore/Minecraft/Download/InstallTask.swift:441,.critical` / `:445,.finish`、
/// `SLCore/Minecraft/MinecraftInstance.swift:338,.critical` / `:345,.info`、
/// `SLCore/SLLaunchBridge.swift:127,.critical`。
public func hint(_ message: String, _ type: HintType = .info) {
    log("[Hint] \(message)")
    let level = NoticeLevel(type)
    NoticeCenter.shared.post(
        Notice(level: level, title: level.defaultTitle, message: message)
    )
}
/// 提示级别。使用方：本文件的 `hint(_:_:)` 默认参数，以及
/// `UI/Notices/NoticeCenter.swift:71`（`NoticeLevel(_ type: HintType)` 映射）；
/// 三个 case 在 `qwqTests/NoticeCenterTests.swift:291-293` 有断言覆盖。
public enum HintType { case info, finish, critical }

// MARK: - DataManager
/// 全局共享状态容器。
///
/// 使用方（节选，均为活跃引用）：
///  - `javaVirtualMachines`：`SLCore/SLLaunchBridge.swift:195,206,253`、`SLCore/Minecraft/MinecraftInstance.swift:164,182,246`、
///    `Features/Java/JavaManager.swift:124,143`；
///  - `versionManifest`：`SLCore/Minecraft/Download/VersionManifest.swift:86`、`SLCore/Minecraft/MinecraftVersion.swift:60`、
///    `SLCore/Download/DownloadSource.swift:37`；
///  - `inprogressInstallTasks`：`Features/Download/DownloadDetailManager.swift:57`、
///    `SLCore/Minecraft/Download/InstallTask.swift:118,119`、`SLCore/Minecraft/Download/MinecraftInstaller.swift:451,453,455`；
///  - `router`：`SLCore/Minecraft/Download/InstallTask.swift:120,121`。
public class DataManager: ObservableObject {
    public static let shared = DataManager()
    @Published public var javaVirtualMachines: [JavaVirtualMachine] = []
    @Published public var versionManifest: VersionManifest? = nil
    @Published public var inprogressInstallTasks: InstallTasks? = nil
    public var router = AppRouter()
    private var routerCancellable: AnyCancellable?
    private init() {
        routerCancellable = router.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

// MARK: - AppRouter
/// 极简路由栈。**有活跃引用，非死代码**：经 `DataManager.shared.router` 在
/// `SLCore/Minecraft/Download/InstallTask.swift:120`（`getLast()` 模式匹配 `.installing`）
/// 与 `:121`（`removeLast()`）使用。
///
/// 语义提示（本次仅记录，不改动）：全库不存在任何入栈点（`append(_:)` 无调用），
/// 因此栈恒为空、`getLast()` 恒返回 `.other`，上述 `.installing` 判断在运行期永不成立。
/// 真实页面切换由 `Features/Download/DownloadDetailManager.swift` 承担。
public class AppRouter: ObservableObject {
    public enum Route: Equatable {
        /// 全库（含 `qwqTests`）无任何构造点，待清理。
        @available(*, deprecated, message: "全库无引用，待清理")
        case versionList(directory: MinecraftDirectory)
        /// 使用方：`SLCore/Minecraft/Download/InstallTask.swift:120`（模式匹配）。
        case installing(_ task: InstallTasks)
        /// 使用方：本文件 `getLast()` 的空栈兜底值。
        case other
    }
    private var stack: [Route] = []
    /// 使用方：`SLCore/Minecraft/Download/InstallTask.swift:120`。
    public func getLast() -> Route { stack.last ?? .other }
    /// 使用方：`SLCore/Minecraft/Download/InstallTask.swift:121`。
    public func removeLast() { if !stack.isEmpty { stack.removeLast() } }
    /// 全库（含 `qwqTests`）无任何调用点，待清理。
    @available(*, deprecated, message: "全库无引用，待清理")
    public func append(_ route: Route) { stack.append(route) }
}

// MARK: - AppSettings
/// 下载源选项。**有活跃引用**：作为 `AppSettings.fileDownloadSource` / `versionManifestSource` 的类型，
/// 取值在 `SLCore/Download/DownloadSourceManager.swift:40,49,69,132`、
/// `Core/Download/Adapters/DefaultDownloadSourceResolver.swift:41`、`SLCore/Download/MultiFileDownloader.swift:27` 使用。
public enum DownloadSourceOption: Codable { case official, mirror, both }

/// 应用级设置（兼容层）。
///
/// 字段引用情况：
///  - `currentMinecraftDirectory`：**只读不改**。读取点 `Features/ModBrowser/CategoryContentView.swift:133`、
///    `Features/Launch/LaunchCoordinator.swift:52`、`Features/Skin/OfflineSkinService.swift:70,128,165`、
///    `Core/Minecraft/Module/MinecraftRepository.swift:76`、`SLCore/SLLaunchBridge.swift:94`；
///    全库（含 `qwqTests`）无写入点，实际恒为 `.default`——详见 `STUBS_AUDIT.md` §5.4。
///  - `fileDownloadSource`：`SLCore/Download/DownloadSourceManager.swift:40,49,69`、
///    `Core/Download/Adapters/DefaultDownloadSourceResolver.swift:41`、`SLCore/Download/MultiFileDownloader.swift:27`，
///    并有测试写入 `qwqTests/DownloadAdapterTests.swift:49,53,182,192`。
///  - `versionManifestSource`：`SLCore/Download/DownloadSourceManager.swift:132`。
public class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    public var currentMinecraftDirectory: MinecraftDirectory? = .default
    public var fileDownloadSource: DownloadSourceOption = .both
    public var versionManifestSource: DownloadSourceOption = .both
    private init() {}
}

// MARK: - Account / AnyAccount
/// 账号抽象。使用方：`OfflineAccount`（本文件）与 `AnyAccount`（本文件）遵循本协议，
/// `AnyAccount.account` 以 `any Account` 承载；`putAccessToken` 的调用点为
/// `SLCore/Minecraft/MinecraftInstance.swift:301`、`SLCore/SLLaunchBridge.swift:191`。
public protocol Account: Codable, Identifiable {
    var id: UUID { get }
    var uuid: UUID { get }
    var name: String { get }
    func putAccessToken(options: LaunchOptions) async
}

/// 离线账号（**真实实现**，非桩）。
/// 使用方：`SLCore/SLLaunchBridge.swift:113`（`OfflineAccount(username)`，全库唯一构造点）、
/// `SLLaunchBridge.swift:116`（`account.uuid`）、`:191`（`account.putAccessToken(options:)`）；
/// `AnyAccount.offline(_:)` 的关联值类型。
public class OfflineAccount: Account {
    public let id: UUID
    public var uuid: UUID
    public var name: String
    public init(_ name: String, _ uuid: UUID? = nil) {
        self.id = .init()
        // 与 PCL2 一致：用户名按调用方传入值保存（调用方已 trim），不做二次处理
        self.name = name
        if let uuid = uuid {
            self.uuid = uuid
        } else {
            // 完整移植 PCL2 离线 UUID 算法（Modules/Minecraft/ModLaunch.vb McLoginLegacyUuid）：
            //   不采用官方 "OfflinePlayer:"+名字 的 MD5，而是 PCL2 自有的
            //   [名字长度(hex,16位)] + [GetHash(名字)(hex,16位)] 拼接后强制 version=3 / variant=9，
            //   保证任何用户名都产出合法 RFC 4122 UUID。
            let hex = OfflineAccount.legacyUuidHex(for: name)
            self.uuid = UUID(uuidString: OfflineAccount.formatUuid(hex)) ?? UUID()
        }
    }

    /// PCL2 离线 UUID（32 位 hex）。移植自 ModLaunch.vb McLoginLegacyUuid + ModBase.vb GetHash。
    /// 使用方：本文件 `OfflineAccount.init(_:_:)`（`Stubs.swift` 内唯一调用点）。
    /// 全库其余位置无直接调用，但属离线 UUID 算法的**真实业务逻辑**，不得删除。
    public static func legacyUuidHex(for name: String) -> String {
        // GetHash：djb2 变体（用 XOR 而非加法），ULong(64bit) 运算，最后 XOR 固定掩码
        // VB: GetHash = 5381; For i: GetHash = (GetHash << 5) Xor GetHash Xor AscW(Str(i)); Return GetHash Xor &HA98F501BC684032FUL
        var hash: UInt64 = 5381
        for unit in name.utf16 {          // VB AscW(Char) = UTF-16 code unit
            hash = (hash << 5) ^ hash ^ UInt64(unit)
        }
        hash ^= 0xA98F_501B_C684_032F
        // VB Name.Length 按 UTF-16 code unit 计数，与 name.utf16.count 一致
        let lenHex = String(name.utf16.count, radix: 16).uppercased()
        let hashHex = String(hash, radix: 16).uppercased()
        // StrFill(Str, "0", 16)：不足 16 位左侧补零
        let full = OfflineAccount.leftPad(lenHex, to: 16) + OfflineAccount.leftPad(hashHex, to: 16)
        // 索引 12 强制 version=3，索引 16 强制 variant=9（10xx → 1001）
        // VB: FullUuid.Substring(0,12) & "3" & Substring(13,3) & "9" & Substring(17,15)
        return String(full.prefix(12)) + "3" + String(full.dropFirst(13).prefix(3)) + "9" + String(full.dropFirst(17).prefix(15))
    }

    /// `StrFill(Str, "0", 16)` 等价实现。使用方：本文件 `legacyUuidHex(for:)`；
    /// 属离线 UUID 算法的真实业务逻辑，不得删除。
    public static func leftPad(_ s: String, to length: Int) -> String {
        if s.count >= length { return String(s.prefix(length)) }
        return String(repeating: "0", count: length - s.count) + s
    }

    /// 32 位 hex → 标准 8-4-4-4-12 UUID 字符串。
    /// 使用方：本文件 `OfflineAccount.init(_:_:)`；属离线 UUID 算法的真实业务逻辑，不得删除。
    public static func formatUuid(_ hex: String) -> String {
        let parts = [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20).prefix(12)
        ]
        return parts.map(String.init).joined(separator: "-")
    }

    /// 使用方：`SLCore/SLLaunchBridge.swift:191`（直接以 `OfflineAccount` 调用）、
    /// `SLCore/Minecraft/MinecraftInstance.swift:301`（经 `AnyAccount` 转发）。
    public func putAccessToken(options: LaunchOptions) {
        // PCL2 行为（ModLaunch.vb McLoginLegacyStart）：离线账号 AccessToken = UUID 本身
        // （与 ClientToken 相同），不是随机串
        options.accessToken = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

// MARK: - 离线用户名校验（移植 PCL2 PageLoginLegacy.IsVaild + 1.20.5+ hello 包 16 字符上限）
/// 校验离线用户名，返回错误信息；返回 "" 表示合法。
/// 规则：
///  - 非空（trim 后）
///  - 不含英文引号 `"`
///  - 不超过 16 个 UTF-16 code unit（1.20.5+ ServerboundHelloPacket 编码时
///    writeUtf(name, 16) 会抛 "String too big (was N characters, max 16)"）
///
/// 使用方：`Features/Launch/LaunchCoordinator.swift:27`、
/// `Features/Launch/Adapters/MinecraftInstanceLaunchService.swift:291`、
/// `SLCore/Minecraft/MinecraftInstance.swift:293`。属真实业务逻辑，不得删除。
public func validateOfflineUsername(_ raw: String) -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return "玩家名不能为空！" }
    if name.contains("\"") { return "玩家名不能包含英文引号！" }
    if name.utf16.count > 16 { return "玩家名不能超过 16 个字符！" }
    return ""
}

/// 账号相关错误。
/// 语义约定：本条枚举只用于表达「能力尚未实现」或「运行环境不可用」，
/// 不得用于表达「已实现但因为密码/令牌错误而失败」——后者不属于本枚举范围。
/// 因此 `errorDescription` 一律直述「尚未实现」，不写成「登录失败」，避免误导用户以为重试即可成功。
public enum AccountError: LocalizedError {
    /// 使用方：本文件 `AnyAccount.unimplementedError`（`Stubs.swift`），
    /// 其返回值在 `SLCore/SLLaunchBridge.swift:125-127` 与
    /// `SLCore/Minecraft/MinecraftInstance.swift:288-289` 被消费。
    case microsoftLoginNotImplemented
    /// 使用方：同 `microsoftLoginNotImplemented`。
    case yggdrasilLoginNotImplemented
    /// 全库（含 `qwqTests`）无任何构造点，待清理。
    @available(*, deprecated, message: "全库无引用，待清理")
    case networkUnavailable
    /// 全库（含 `qwqTests`）无任何构造点，待清理。
    @available(*, deprecated, message: "全库无引用，待清理")
    case popupNotAvailable

    public var errorDescription: String? {
        switch self {
        case .microsoftLoginNotImplemented:
            return "微软账号登录尚未实现：本启动器当前仅支持离线账号，请使用离线模式启动游戏。"
        case .yggdrasilLoginNotImplemented:
            return "Yggdrasil 外置登录尚未实现：本启动器当前仅支持离线账号，请使用离线模式启动游戏。"
        case .networkUnavailable:
            return "网络不可用：当前无法建立网络连接，请检查网络后重试。"
        case .popupNotAvailable:
            return "弹窗不可用：弹窗管理器尚未实现，该提示无法显示。"
        }
    }
}

/// 账号种类的统一包装。
///
/// 重要说明（治理约定）：
///  - `.offline` 为真实实现，离线账号可正常使用。
///  - `.microsoft` / `.yggdrasil` **仅保留枚举形状**，用于兼容历史持久化数据
///    （`CodableAppStorage("accounts")` 以 JSON 存储，删除 case 会导致旧数据解码失败）。
///    两者的登录流程尚未实现，运行期会被当作离线账号处理，不存在任何 OAuth / 外置认证行为。
///  - 消费方在启动或展示账号前，应先用 `unimplementedError` 判断
///    （原先并列的 `isFullyImplemented` 全库无引用，已在本次普查中标注待清理），
///    不得依据枚举 case 名称推断该账号具备联网认证能力。
///
/// 使用方（活跃引用）：
///  - 类型：`SLCore/Minecraft/Launch/LaunchOptions.swift:17`（`public var account: AnyAccount?`）、
///    `SLCore/SLLaunchBridge.swift:117`（`options.account = .offline(account)`，全库唯一构造点）、
///    `SLCore/Minecraft/MinecraftInstance.swift:285,302`；
///  - `unimplementedError`：`SLLaunchBridge.swift:125`、`MinecraftInstance.swift:288`；
///  - `accountKindDescription`：`SLLaunchBridge.swift:126`、`MinecraftInstance.swift:289`；
///  - `name` / `uuid` / `putAccessToken`：`MinecraftInstance.swift:293,299,301`。
public enum AnyAccount: Account, Identifiable, Equatable {
    /// 真实实现。构造点：`SLCore/SLLaunchBridge.swift:117`。
    case offline(OfflineAccount)
    /// 尚未实现：类型层保留，实际按离线账号处理（无 OAuth 流程、无 accessToken 交换）。
    case microsoft(OfflineAccount)
    /// 尚未实现：类型层保留，实际按离线账号处理（无 Yggdrasil 认证、无会话服务器交互）。
    case yggdrasil(OfflineAccount)

    private var account: any Account {
        switch self {
        case .offline(let a), .microsoft(let a), .yggdrasil(let a): return a
        }
    }
    public var id: UUID { account.id }
    public var uuid: UUID { account.uuid }
    public var name: String { account.name }
    public static func == (lhs: AnyAccount, rhs: AnyAccount) -> Bool { lhs.id == rhs.id }
    public func putAccessToken(options: LaunchOptions) async { await account.putAccessToken(options: options) }

    /// 该账号种类是否已完整实现。
    /// 仅 `.offline` 返回 true；`.microsoft` / `.yggdrasil` 登录流程尚未实现，返回 false。
    ///
    /// 全库（含 `qwqTests`）无任何引用，待清理：实际消费方一律走 `unimplementedError`。
    @available(*, deprecated, message: "全库无引用，待清理")
    public var isFullyImplemented: Bool {
        switch self {
        case .offline: return true
        case .microsoft, .yggdrasil: return false
        }
    }

    /// 账号种类的中文描述，供 UI / 日志展示。
    /// 未实现的种类显式标注「尚未实现」，避免 UI 把它呈现为可用的登录方式。
    /// 使用方：`SLCore/SLLaunchBridge.swift:126`、`SLCore/Minecraft/MinecraftInstance.swift:289`。
    public var accountKindDescription: String {
        switch self {
        case .offline: return "离线账号"
        case .microsoft: return "微软账号（尚未实现，当前按离线账号处理）"
        case .yggdrasil: return "Yggdrasil 外置登录（尚未实现，当前按离线账号处理）"
        }
    }

    /// 未实现种类的对应错误；已实现种类返回 nil。
    /// 供调用方在发现未实现账号时给出明确提示，而非静默降级。
    /// 使用方：`SLCore/SLLaunchBridge.swift:125`、`SLCore/Minecraft/MinecraftInstance.swift:288`。
    public var unimplementedError: AccountError? {
        switch self {
        case .offline: return nil
        case .microsoft: return .microsoftLoginNotImplemented
        case .yggdrasil: return .yggdrasilLoginNotImplemented
        }
    }
}

/// 账号持久化层（`@CodableAppStorage` 以 JSON 落 `UserDefaults`）。
///
/// **有活跃引用，非死代码**：`SLCore/SLLaunchBridge.swift:124`
/// 通过 `AccountManager.shared.getAccount()` 读取已选账号，并在 `:125-127` 对未实现账号告警。
/// （历史审计曾将其记为「全代码库无任何引用」，本次普查已核实为误判。）
public class AccountManager: ObservableObject {
    public static let shared = AccountManager()
    /// 唯一写入方：本类型自身（`@CodableAppStorage` 属性包装器）。
    /// 唯一读取路径：`getAccount()` → `SLLaunchBridge.swift:124`。
    @CodableAppStorage("accounts") public var accounts: [AnyAccount] = []
    @CodableAppStorage("accountId") public var accountId: UUID? = nil
    private init() {}
    /// 使用方：`SLCore/SLLaunchBridge.swift:124`。
    public func getAccount() -> AnyAccount? {
        if accountId == nil { accountId = accounts.first?.id }
        return accounts.first(where: { $0.id == accountId })
    }
}

// MARK: - PopupManager
/// 弹窗按钮模型。
/// 使用方：`SLCore/Minecraft/Download/InstallTask.swift:240,304,355`（`[PopupButton.ok]`）、
/// `SLCore/Minecraft/MinecraftInstance.swift:348`；另有 `UI/Notices/NoticeCenter.swift:15` 的映射实现
/// 与 `qwqTests/NoticeCenterTests.swift:321,322,336,346,347,351,352` 的构造。
public struct PopupButton {
    public let label: String
    public let style: PopupButtonStyle
    public static let ok = PopupButton(label: "确定", style: .normal)
    public init(label: String, style: PopupButtonStyle = .normal) {
        self.label = label
        self.style = style
    }
}
/// 按钮样式。使用方：`PopupButton` 的默认参数、`UI/Notices/NoticeCenter.swift:19,21`、
/// `qwqTests/NoticeCenterTests.swift:347`（`.danger`）。
public enum PopupButtonStyle { case normal, accent, danger }
/// 弹窗类型。使用方：`UI/Notices/NoticeCenter.swift:62`（`NoticeLevel(_ type: PopupType)`）、
/// `qwqTests/NoticeCenterTests.swift:284-286`。
public enum PopupType { case info, warning, error }
/// 弹窗内容模型。使用方：`PopupManager.show(_:)` / `showAsync(_:)`（本文件）、
/// `UI/Notices/NoticeCenter.swift:92`（`Notice(_ model: PopupModel)`）、
/// `qwqTests/NoticeCenterTests.swift:318,336,345,350`。
public struct PopupModel {
    public let type: PopupType
    public let title: String
    public let message: String
    public let buttons: [PopupButton]
    public init(_ type: PopupType, _ title: String, _ message: String, _ buttons: [PopupButton]) {
        self.type = type; self.title = title; self.message = message; self.buttons = buttons
    }
}

/// 弹窗管理器。**已接入真实提示通道**（`NoticeCenter` → 根视图上的 `NoticeOverlay`）。
///
/// 实现约定：
///  - `show(_:)` 把 `PopupModel` 转成 `Notice` 投递到 `NoticeCenter`，随即返回（不等待用户）；
///  - `showAsync(_:)` 同样投递，但会**真正等待用户点选按钮**，并返回被点按钮的下标；
///  - 两者签名与调用点保持不变，旧调用方无需改动。
///
/// 使用方：`SLCore/Minecraft/Download/InstallTask.swift:240,304,355`（`show`）、
/// `SLCore/Minecraft/MinecraftInstance.swift:348`（`showAsync`）。
@MainActor
public class PopupManager: ObservableObject {
    public static let shared = PopupManager()
    /// 弹窗能力是否可用：取决于 UI 承载者（`NoticeOverlay`）是否已挂载。
    /// 未挂载时 `show` 仍会记入 `NoticeCenter.history`，但不会有任何可见 UI，
    /// 且 `showAsync` 会立即返回默认下标 0（不会阻塞调用方）。
    ///
    /// 全库（含 `qwqTests`）无任何引用，待清理。
    @available(*, deprecated, message: "全库无引用，待清理")
    public var isAvailable: Bool { NoticeCenter.shared.hasPresenter }
    private init() {}

    /// 展示弹窗：转成 `Notice` 投递到统一提示通道。不等待用户操作，调用后立即返回。
    /// 使用方：`SLCore/Minecraft/Download/InstallTask.swift:240,304,355`。
    public func show(_ model: PopupModel) async {
        NoticeCenter.shared.post(Notice(model))
    }

    /// 展示弹窗并等待用户点选，返回被点击按钮在 `model.buttons` 中的**下标**。
    ///
    /// 返回值约定（重要，调用方据此分支）：
    ///  - `0` —— 用户点了第 0 个按钮，或直接关闭了提示，或 UI 承载者未挂载（兜底），
    ///           或等待超过兜底超时（300s）。即「默认 / 取消」语义。
    ///  - `n > 0` —— 用户点击了第 n 个按钮（例如 `MinecraftInstance` 中下标 1 的「导出错误报告」）。
    ///
    /// 注意：仅在 `NoticeOverlay` 已挂载时才会真正等待；否则立即返回 0，
    /// 与非阻塞场景保持兼容，绝不会把调用方永久挂起。
    ///
    /// 使用方：`SLCore/Minecraft/MinecraftInstance.swift:348`。
    public func showAsync(_ model: PopupModel) async -> Int {
        await NoticeCenter.shared.presentAndWait(Notice(model))
    }
}

// MARK: - CodableAppStorage (simplified)
/// `UserDefaults` + JSON 的属性包装器（简化版：无 `@AppStorage` 的 KVO 联动）。
/// 使用方：本文件 `AccountManager.accounts` / `AccountManager.accountId`
/// （`Stubs.swift:345,346`），全库其余位置无引用。
/// 线程安全前提：`wrappedValue` 直接读写 `UserDefaults`（线程安全 API），不持有隔离状态。
@propertyWrapper
public struct CodableAppStorage<Value: Codable> {
    private let key: String
    private let defaultValue: Value
    public init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.defaultValue = wrappedValue
    }
    public var wrappedValue: Value {
        get {
            if let data = UserDefaults.standard.data(forKey: key),
               let value = try? JSONDecoder().decode(Value.self, from: data) {
                return value
            }
            return defaultValue
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}

// MARK: - Theme（桩实现）
/// 主题模型（**桩实现**）。
/// 当前只保留 `id` 字段，`load(id:)` 仅按 id 构造对象，不读取任何主题文件、
/// 不解析配色/字体，也不参与渲染。因此「切换主题」在本类型层面不产生任何视觉效果。
/// 真实主题渲染由 `qwq/Features/Settings/ThemeManager.swift` 负责，
/// 本类型为历史遗留接口，调用方不应据此判断主题是否生效。
///
/// 全库（含 `qwqTests`）无任何代码引用，待清理；仅
/// `Features/Theme/ThemeDefinition.swift:8-13` 在注释中说明「本类型不具备渲染语义、不纳入配色来源」。
@available(*, deprecated, message: "全库无引用，待清理")
public class Theme {
    public var id: String
    public init(id: String) { self.id = id }
    public static func load(id: String) -> Theme { Theme(id: id) }
}
