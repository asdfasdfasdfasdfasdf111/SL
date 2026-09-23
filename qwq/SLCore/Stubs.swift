//  Stubs.swift —— 历史兼容层：既有真实实现（离线账号、提示/弹窗通道），也有待清理的桩类型。
//
//  本文件注释的引用标注约定：一律写「文件 + 符号/场景」，**不写行号**。
//  历史版本逐处标注了 `文件:行号`，但行号会随任何一次编辑漂移——经过数轮重构后，
//  其中大量标注已指向错误的行，甚至指向已被删除的代码（例如旧启动流程里的调用点）。
//  符号名不漂移，代价只是读者多跳一步。

import Foundation
import SwiftUI
import Combine

// MARK: - Hint function
/// 轻量提示。**已接入真实提示通道**（`NoticeCenter` → 根视图上的 `NoticeOverlay`）。
///
/// 行为：写一条日志，并把消息按级别转成 `Notice` 投递到 `NoticeCenter`，
/// 用户会在界面顶部看到对应横幅（`info` / `success` 自动消失，`warning` / `error` 需手动关闭）。
/// 投递是异步且线程安全的，因此本函数可从任意线程调用，调用后不会阻塞等待。
///
/// 使用方（均为活跃调用）：
///  - `SLCore/SLLaunchBridge.swift`——未实现账号告警（`.critical`）；
///  - `SLCore/Minecraft/Launch/MinecraftLauncherArguments.swift`——内存上限非法并回退（`.critical`）；
///  - `SLCore/Minecraft/Launch/LaunchFix.swift`——启动前补全存在无法修复的缺项（`.critical`）；
///  - `SLCore/Minecraft/Launch/MinecraftLauncher.swift`——游戏日志文件不可写（`.critical`）。
public func hint(_ message: String, _ type: HintType = .info) {
    log("[Hint] \(message)")
    let level = NoticeLevel(type)
    NoticeCenter.shared.post(
        Notice(level: level, title: level.defaultTitle, message: message)
    )
}
/// 提示级别。使用方：本文件的 `hint(_:_:)` 默认参数，以及
/// `UI/Notices/NoticeCenter.swift` 的 `NoticeLevel.init(_ type: HintType)` 映射；
/// 三个 case 在 `qwqTests/NoticeCenterTests.swift` 有断言覆盖。
public enum HintType { case info, finish, critical }

// MARK: - DataManager
/// 全局共享状态容器。
///
/// 使用方（节选，均为活跃引用）：
///  - `javaVirtualMachines`：`SLCore/SLLaunchBridge.swift`（启动前读取并等待扫描结果）、
///    `Features/Java/JavaManager.swift`（扫描结果写入）、
///    `SLCore/Minecraft/MinecraftInstanceJava.swift`（Java 探测、回写与筛选）；
///  - `versionManifest`：`SLCore/Minecraft/Download/VersionManifest.swift`、
///    `SLCore/Minecraft/MinecraftVersion.swift`、`SLCore/Download/DownloadSource.swift`；
///  - `inprogressInstallTasks`：`Features/Download/DownloadDetailManager.swift`（写入）、
///    `SLCore/Minecraft/Download/InstallTask.swift`（归属校验后清理）、
///    `SLCore/Minecraft/Download/MinecraftInstaller.swift`（按 key 取加载器子任务）。
public class DataManager: ObservableObject {
    public static let shared = DataManager()
    @Published public var javaVirtualMachines: [JavaVirtualMachine] = []
    @Published public var versionManifest: VersionManifest? = nil
    @Published public var inprogressInstallTasks: InstallTasks? = nil
    private init() {}
}

// MARK: - AppSettings
/// 下载源选项。**有活跃引用**：作为 `AppSettings.fileDownloadSource` / `versionManifestSource` 的类型，
/// 三个 case 的读取点为 `SLCore/Download/DownloadSourceManager.swift`（源选择与测速切换）、
/// `Core/Download/Adapters/DefaultDownloadSourceResolver.swift`（`== .both` 时追加镜像源）、
/// `SLCore/Download/MultiFileDownloader.swift`（决定是否提供备用源）。
public enum DownloadSourceOption: Codable { case official, mirror, both }

/// 应用级设置（兼容层）。
///
/// 字段引用情况：
///  - `currentMinecraftDirectory`：**只读不改**。读取点为 `SLCore/SLLaunchBridge.swift`（未传 gameDir 时的兜底）、
///    `Features/Launch/LaunchCoordinator.swift`、`Features/Skin/OfflineSkinService.swift`、
///    `Features/ModBrowser/ViewModels/LaunchAvatarSkinViewModel.swift`、
///    `Core/Minecraft/Module/MinecraftRepository.swift`；
///    全库（含 `qwqTests`）无写入点，实际恒为 `.default`——详见 `STUBS_AUDIT.md` §5.4。
///  - `fileDownloadSource`：`SLCore/Download/DownloadSourceManager.swift`（源选择与测速切换）、
///    `Core/Download/Adapters/DefaultDownloadSourceResolver.swift`（`== .both` 时追加镜像源）、
///    `SLCore/Download/MultiFileDownloader.swift`（备用源开关），
///    并有测试写入 `qwqTests/DownloadAdapterTests.swift`。
///  - `versionManifestSource`：`SLCore/Download/DownloadSourceManager.swift`。
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
/// `SLCore/SLLaunchBridge.swift`（启动前写入离线令牌）。
public protocol Account: Codable, Identifiable {
    var id: UUID { get }
    var uuid: UUID { get }
    var name: String { get }
    func putAccessToken(options: LaunchOptions) async
}

/// 离线账号（**真实实现**，非桩）。
/// 使用方：`SLCore/SLLaunchBridge.swift`（`OfflineAccount(username)`，全库唯一构造点，
/// 随后取 `account.uuid` 并调用 `account.putAccessToken(options:)`）；
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

    /// 使用方：`SLCore/SLLaunchBridge.swift`（直接以 `OfflineAccount` 调用）。
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
/// 使用方：`Features/Launch/LaunchCoordinator.swift`（UI 层即时校验，失败即阻断启动）、
/// `Features/Launch/Adapters/MinecraftInstanceLaunchService.swift`（服务层唯一入口校验）。
/// 属真实业务逻辑，不得删除。
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
    /// 其返回值在 `SLCore/SLLaunchBridge.swift` 的「未实现账号告警」分支被消费
    /// （先 `warn` 写日志，再 `hint(..., .critical)` 投递用户可见提示）。
    case microsoftLoginNotImplemented
    /// 使用方：同 `microsoftLoginNotImplemented`。
    case yggdrasilLoginNotImplemented

    public var errorDescription: String? {
        switch self {
        case .microsoftLoginNotImplemented:
            return "微软账号登录尚未实现：本启动器当前仅支持离线账号，请使用离线模式启动游戏。"
        case .yggdrasilLoginNotImplemented:
            return "Yggdrasil 外置登录尚未实现：本启动器当前仅支持离线账号，请使用离线模式启动游戏。"
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
///    不得依据枚举 case 名称推断该账号具备联网认证能力。
///
/// 使用方（活跃引用）：
///  - 类型：`SLCore/Minecraft/Launch/LaunchOptions.swift`（`public var account: AnyAccount?`）、
///    `SLCore/SLLaunchBridge.swift`（`options.account = .offline(account)`，全库唯一构造点）；
///  - `unimplementedError` / `accountKindDescription`：`SLCore/SLLaunchBridge.swift`
///    的「未实现账号告警」分支（分别用作判定条件与日志文案）。
public enum AnyAccount: Account, Identifiable, Equatable {
    /// 真实实现。构造点：`SLCore/SLLaunchBridge.swift`。
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

    /// 账号种类的中文描述，供 UI / 日志展示。
    /// 未实现的种类显式标注「尚未实现」，避免 UI 把它呈现为可用的登录方式。
    /// 使用方：`SLCore/SLLaunchBridge.swift`（未实现账号告警的日志文案）。
    public var accountKindDescription: String {
        switch self {
        case .offline: return "离线账号"
        case .microsoft: return "微软账号（尚未实现，当前按离线账号处理）"
        case .yggdrasil: return "Yggdrasil 外置登录（尚未实现，当前按离线账号处理）"
        }
    }

    /// 未实现种类的对应错误；已实现种类返回 nil。
    /// 供调用方在发现未实现账号时给出明确提示，而非静默降级。
    /// 使用方：`SLCore/SLLaunchBridge.swift`（未实现账号告警的判定条件）。
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
/// **有活跃引用，非死代码**：`SLCore/SLLaunchBridge.swift`
/// 通过 `AccountManager.shared.getAccount()` 读取已选账号，并对未实现账号告警。
/// （历史审计曾将其记为「全代码库无任何引用」，本次普查已核实为误判。）
public class AccountManager: ObservableObject {
    public static let shared = AccountManager()
    /// 唯一写入方：本类型自身（`@CodableAppStorage` 属性包装器）。
    /// 唯一读取路径：`getAccount()` → `SLCore/SLLaunchBridge.swift`。
    @CodableAppStorage("accounts") public var accounts: [AnyAccount] = []
    @CodableAppStorage("accountId") public var accountId: UUID? = nil
    private init() {}
    /// 使用方：`SLCore/SLLaunchBridge.swift`。
    public func getAccount() -> AnyAccount? {
        if accountId == nil { accountId = accounts.first?.id }
        return accounts.first(where: { $0.id == accountId })
    }
}

// MARK: - PopupManager
/// 弹窗按钮模型。
/// 使用方：`SLCore/Minecraft/Download/MinecraftInstallTask.swift`、`LoaderInstallTasks.swift`
/// （`[PopupButton.ok]`）；另有 `UI/Notices/NoticeCenter.swift` 的映射实现
/// 与 `qwqTests/NoticeCenterTests.swift` 的构造。
public struct PopupButton {
    public let label: String
    public let style: PopupButtonStyle
    public static let ok = PopupButton(label: "确定", style: .normal)
    public init(label: String, style: PopupButtonStyle = .normal) {
        self.label = label
        self.style = style
    }
}
/// 按钮样式。使用方：`PopupButton` 的默认参数、`UI/Notices/NoticeCenter.swift`、
/// `qwqTests/NoticeCenterTests.swift`（`.danger`）。
public enum PopupButtonStyle { case normal, accent, danger }
/// 弹窗类型。使用方：`UI/Notices/NoticeCenter.swift`（`NoticeLevel(_ type: PopupType)`）、
/// `qwqTests/NoticeCenterTests.swift`。
public enum PopupType { case info, warning, error }
/// 弹窗内容模型。使用方：`PopupManager.show(_:)` / `showAsync(_:)`（本文件）、
/// `UI/Notices/NoticeCenter.swift`（`Notice(_ model: PopupModel)`）、
/// `qwqTests/NoticeCenterTests.swift`。
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
/// 使用方：`SLCore/Minecraft/Download/MinecraftInstallTask.swift`、`LoaderInstallTasks.swift`（`show`）。
///
/// `showAsync` 目前**无调用方**——它唯一的调用点（旧启动流程里的崩溃弹窗）已随该流程一并删除。
/// 保留原因（见 `Features/Launch/Adapters/LAUNCH_FLOW.md` 第三节「失去调用方的能力」）：
/// 本启动器当前仍缺失「崩溃后可导出错误报告」这条能力，`showAsync` 是它的现成实现；
/// 且其底层 `NoticeCenter.presentAndWait` 有单元测试覆盖（`qwqTests/NoticeCenterTests.swift`），
/// 删除会让该等待机制连同测试覆盖一起失去生产侧入口。补齐能力时直接接线即可。
@MainActor
public class PopupManager: ObservableObject {
    public static let shared = PopupManager()
    private init() {}

    /// 展示弹窗：转成 `Notice` 投递到统一提示通道。不等待用户操作，调用后立即返回。
    /// 使用方：`SLCore/Minecraft/Download/MinecraftInstallTask.swift`、`LoaderInstallTasks.swift`。
    public func show(_ model: PopupModel) async {
        NoticeCenter.shared.post(Notice(model))
    }

    /// 展示弹窗并等待用户点选，返回被点击按钮在 `model.buttons` 中的**下标**。
    ///
    /// 返回值约定（重要，调用方据此分支）：
    ///  - `0` —— 用户点了第 0 个按钮，或直接关闭了提示，或 UI 承载者未挂载（兜底），
    ///           或等待超过兜底超时（300s）。即「默认 / 取消」语义。
    ///  - `n > 0` —— 用户点击了第 n 个按钮（例如崩溃提示里下标 1 的「导出错误报告」）。
    ///
    /// 注意：仅在 `NoticeOverlay` 已挂载时才会真正等待；否则立即返回 0，
    /// 与非阻塞场景保持兼容，绝不会把调用方永久挂起。
    ///
    /// 使用方：当前**无生产侧调用方**（唯一调用点随旧启动流程删除）；
    /// 作为「崩溃后导出错误报告」能力的现成实现保留，接线说明见类型注释。
    public func showAsync(_ model: PopupModel) async -> Int {
        await NoticeCenter.shared.presentAndWait(Notice(model))
    }
}

// MARK: - CodableAppStorage (simplified)
/// `UserDefaults` + JSON 的属性包装器（简化版：无 `@AppStorage` 的 KVO 联动）。
/// 使用方：本文件 `AccountManager.accounts` / `AccountManager.accountId`，全库其余位置无引用。
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

