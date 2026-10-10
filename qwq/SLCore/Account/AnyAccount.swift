//
//  AnyAccount.swift
//  账号种类的统一包装与其持久化容器。
//
//  历史：本文件的内容原先混在 `SLCore/Stubs.swift` 里。拆分后按「一个文件一件事」落位：
//  这里只讲**账号的种类与持久化**，离线账号的实现（含 UUID 算法）在
//  `SLCore/Account/OfflineAccount.swift`，微软账号的实现（令牌链 + 刷新）在
//  `SLCore/Account/MicrosoftAccount.swift` 与 `MicrosoftAuthService.swift`。
//
//  职责：`AccountError`（未实现能力的显式表达）、`AnyAccount`（种类包装）、
//        `AccountManager`（`UserDefaults` 持久化与已选账号读取）。
//  边界：**不实现任何登录流程**。登录流程在 `MicrosoftAuthService`；
//        `.yggdrasil` 仍为桩（保留枚举形状兼容历史持久化数据，运行期按离线账号处理）。
//
//  2026-10-… 模型变更（微软登录落地）：
//   - `.microsoft` 的关联值从 `OfflineAccount`（桩）换成 `MicrosoftAccount`（真实实现）。
//   - 磁盘形状随之变化：新写入的 `.microsoft` 载荷是 MicrosoftAccount 的字段集合。
//   - **旧数据兼容**：桩时代写入的 `.microsoft` 载荷是 OfflineAccount 形状
//     （仅 id/uuid/name）。解码时先按新形状解，失败则按旧形状解并迁移为 `.offline`
//     —— 与桩时代「运行期按离线账号处理」的既定行为一致，不丢用户名/UUID。
//     迁移由本文件的自定义 `Codable` 完成（见 `init(from:)`）。
//
//  注释引用约定：一律写「文件 + 符号/场景」，不写行号。
//

import Foundation
import Combine

/// 账号相关错误。
/// 语义约定：本条枚举只用于表达「能力尚未实现」或「运行环境不可用」，
/// 不得用于表达「已实现但因为密码/令牌错误而失败」——后者用
/// `MicrosoftAuthError`（SLCore/Account/MicrosoftAuthService.swift），
/// 两者语义相反（未实现 vs 认证失败）。
public enum AccountError: LocalizedError {
    /// 历史保留：微软登录已实现，不再从任何路径抛出（`unimplementedError` 对 `.microsoft` 返回 nil）。
    @available(*, deprecated, message: "微软登录已实现，本 case 仅作历史保留，不再被产生")
    case microsoftLoginNotImplemented
    /// 使用方：`AnyAccount.unimplementedError` 对 `.yggdrasil` 的返回。
    case yggdrasilLoginNotImplemented

    public var errorDescription: String? {
        switch self {
        case .microsoftLoginNotImplemented:
            return "微软账号登录尚未实现（历史文案，当前不应出现）。"
        case .yggdrasilLoginNotImplemented:
            return "Yggdrasil 外置登录尚未实现：本启动器当前仅支持离线账号与微软账号，请使用这两种登录方式。"
        }
    }
}

/// 账号种类的统一包装。
///
/// 重要说明（治理约定）：
///  - `.offline` 与 `.microsoft` 为真实实现：离线账号、微软账号均可正常使用。
///  - `.yggdrasil` **仅保留枚举形状**，用于兼容历史持久化数据
///    （`CodableAppStorage("accounts")` 以 JSON 存储，删除 case 会导致旧数据解码失败）。
///    Yggdrasil 登录流程尚未实现，运行期会被当作离线账号处理。
///  - 消费方在启动或展示账号前，应先用 `unimplementedError` 判断
///    不得依据枚举 case 名称推断该账号具备联网认证能力。
///
/// 使用方（活跃引用）：
///  - 类型：`SLCore/Minecraft/Launch/LaunchOptions.swift`（`public var account: AnyAccount?`）、
///    `SLCore/SLLaunchBridge.swift`（账号选择分支）；
///  - `unimplementedError` / `accountKindDescription`：`SLCore/SLLaunchBridge.swift`
///    的「未实现账号告警」分支（分别用作判定条件与日志文案）；
///  - 持久化：`AccountManager`（本文件下方）。
public enum AnyAccount: Account, Identifiable, Equatable {
    /// 真实实现。构造点：`SLCore/SLLaunchBridge.swift`（离线用户名启动）、
    /// `MicrosoftLoginViewModel`（微软登录完成后 upsert）。
    case offline(OfflineAccount)
    /// 真实实现（微软账号）。构造点：`MicrosoftLoginViewModel`（登录完成后 upsert）。
    case microsoft(MicrosoftAccount)
    /// 尚未实现：类型层保留，实际按离线账号处理（无 Yggdrasil 认证、无会话服务器交互）。
    case yggdrasil(OfflineAccount)

    private var account: any Account {
        switch self {
        case .offline(let a): return a
        case .microsoft(let a): return a
        case .yggdrasil(let a): return a
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
        case .microsoft: return "微软账号"
        case .yggdrasil: return "Yggdrasil 外置登录（尚未实现，当前按离线账号处理）"
        }
    }

    /// 未实现种类的对应错误；已实现种类返回 nil。
    /// 供调用方在发现未实现账号时给出明确提示，而非静默降级。
    /// 使用方：`SLCore/SLLaunchBridge.swift`（未实现账号告警的判定条件）。
    public var unimplementedError: AccountError? {
        switch self {
        case .offline: return nil
        case .microsoft: return nil // 已实现（2026-10-…）
        case .yggdrasil: return .yggdrasilLoginNotImplemented
        }
    }

    /// 便利访问：取出微软账号（未选中/非微软账号时返回 nil）。
    /// 使用方：启动用例层 `MinecraftInstanceLaunchService`（启动前刷新令牌）、
    /// UI 层 `MicrosoftLoginViewModel`（恢复已选账号展示）。
    public var microsoftAccount: MicrosoftAccount? {
        if case .microsoft(let ms) = self { return ms }
        return nil
    }

    // MARK: - Codable（自定义：保持合成形状 + 旧微软件数据迁移）

    /// 磁盘形状 == Swift 合成的「带关联值 enum」形状：`{<case名>: {_0: <载荷>}}`。
    /// 形状由 `AccountPersistenceCompatTests`（qwqTests/）钉死，改形状即改磁盘契约。
    private enum CodingKeys: String, CodingKey {
        case offline, microsoft, yggdrasil
        /// 关联值容器键（合成 Codable 的固定键名，不得改名）
        case _0
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = container.allKeys
        if keys.contains(.offline) {
            let payload = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .offline)
            self = .offline(try payload.decode(OfflineAccount.self, forKey: ._0))
        } else if keys.contains(.microsoft) {
            let payload = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .microsoft)
            if let ms = try? payload.decode(MicrosoftAccount.self, forKey: ._0) {
                // 新形状：真实微软账号
                self = .microsoft(ms)
            } else if let legacy = try? payload.decode(OfflineAccount.self, forKey: ._0) {
                // 旧形状（桩时代）：微软登录未实现时以 OfflineAccount 承载，
                // 运行期按离线账号处理 → 迁移为 .offline（不丢用户名/UUID）。
                self = .offline(legacy)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: ._0, in: payload,
                    debugDescription: "microsoft 载荷既不是 MicrosoftAccount 形状也不是历史 OfflineAccount 形状")
            }
        } else if keys.contains(.yggdrasil) {
            let payload = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .yggdrasil)
            self = .yggdrasil(try payload.decode(OfflineAccount.self, forKey: ._0))
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.offline,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "未知的账号 case，拒绝静默降级"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .offline(let account):
            var payload = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .offline)
            try payload.encode(account, forKey: ._0)
        case .microsoft(let account):
            var payload = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .microsoft)
            try payload.encode(account, forKey: ._0)
        case .yggdrasil(let account):
            var payload = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .yggdrasil)
            try payload.encode(account, forKey: ._0)
        }
    }
}

/// 账号持久化层（`@CodableAppStorage` 以 JSON 落 `UserDefaults`）。
///
/// **有活跃引用，非死代码**：`SLCore/SLLaunchBridge.swift`
/// 通过 `AccountManager.shared.getAccount()` 读取已选账号（未实现账号告警 + 账号选择分支）；
/// `MinecraftInstanceLaunchService`（启动前刷新）与 `MicrosoftLoginViewModel`（登录/登出）写入。
/// （历史审计曾将其记为「全代码库无任何引用」，本次普查已核实为误判。）
public class AccountManager: ObservableObject {
    public static let shared = AccountManager(store: .standard)
    /// 唯一写入方：本类型自身的 `upsert(_:)` / `remove(accountID:)`。
    /// 唯一读取路径：`getAccount()` → `SLLaunchBridge` / 启动用例层 / UI。
    /// ⚠️ 下面两个包装器**必须由同一个 `store` 构造**，否则「读账号」与「读已选 id」会落在不同偏好域。
    /// 声明处的 `= []` / `= nil` 只用于满足属性包装器的声明形态，真正生效的是 `init` 里的显式构造。
    @CodableAppStorage("accounts") public var accounts: [AnyAccount] = []
    @CodableAppStorage("accountId") public var accountId: UUID? = nil

    private init(store: UserDefaults) {
        _accounts = CodableAppStorage(wrappedValue: [], "accounts", store: store)
        _accountId = CodableAppStorage(wrappedValue: nil, "accountId", store: store)
    }

    #if DEBUG
    /// 测试专用：把账号持久化**整体指向独立偏好域**，用例因此无需读写用户真实账号数据。
    ///
    /// 为什么必须有这个入口：测试宿主的宿主 App 就是 qwq.app 本体，测试进程里的
    /// `UserDefaults.standard` **就是用户真实偏好域**（见 `HANDOFF`/测试文件头说明）。
    /// 在此之前用例只能靠「临时删掉真实 `accounts` / `accountId` 键、`defer` 再还原」来隔离，
    /// 而宿主 abort（Xcode 26.2 隔离析构缺陷，见 `qwqTests/TESTING.md` §五）会直接杀掉进程、
    /// **`defer` 不执行** —— 等于一次测试运行可能抹掉用户的已保存账号。
    /// 注入独立域后，用例的读写**在物理上**落不到真实域，不再依赖任何还原动作。
    ///
    /// ⚠️ 生产代码不得调用；Release 构建里此方法不存在（与 `MemoryCacheReclaimer.resetForTesting()` 同一约定）。
    static func makeForTesting(store: UserDefaults) -> AccountManager {
        AccountManager(store: store)
    }
    #endif

    /// 使用方：`SLCore/SLLaunchBridge.swift`（账号选择分支）、启动用例层、UI。
    public func getAccount() -> AnyAccount? {
        if accountId == nil { accountId = accounts.first?.id }
        return accounts.first(where: { $0.id == accountId })
    }

    /// 新增或按 id 替换账号，并设为已选账号。
    /// 使用方：`MicrosoftLoginViewModel`（登录成功）、`MicrosoftAccount.refresh()`（刷新后回写）。
    public func upsert(_ account: AnyAccount) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
        accountId = account.id
    }

    /// 按 id 删除账号；删除的若是已选账号，则回退到剩下第一个（无则置空）。
    /// 使用方：`MicrosoftLoginViewModel`（退出登录）。
    public func remove(accountID: UUID) {
        accounts.removeAll { $0.id == accountID }
        if accountId == accountID {
            accountId = accounts.first?.id
        }
    }
}