//
//  AnyAccount.swift
//  账号种类的统一包装与其持久化容器。
//
//  历史：本文件的内容原先混在 `SLCore/Stubs.swift` 里。拆分后按「一个文件一件事」落位：
//  这里只讲**账号的种类与持久化**，离线账号的实现（含 UUID 算法）在
//  `SLCore/Account/OfflineAccount.swift`。
//
//  职责：`AccountError`（未实现能力的显式表达）、`AnyAccount`（种类包装）、
//        `AccountManager`（`UserDefaults` 持久化与已选账号读取）。
//  边界：**不实现任何登录流程**。`.microsoft` / `.yggdrasil` 只保留枚举形状用于兼容历史
//        持久化数据，运行期按离线账号处理（详见 `AnyAccount` 的治理约定）。
//
//  注释引用约定：一律写「文件 + 符号/场景」，**不写行号**（行号会随任何一次编辑漂移）。
//

import Foundation
import Combine

/// 账号相关错误。
/// 语义约定：本条枚举只用于表达「能力尚未实现」或「运行环境不可用」，
/// 不得用于表达「已实现但因为密码/令牌错误而失败」——后者不属于本枚举范围。
/// 因此 `errorDescription` 一律直述「尚未实现」，不写成「登录失败」，避免误导用户以为重试即可成功。
public enum AccountError: LocalizedError {
    /// 使用方：本文件 `AnyAccount.unimplementedError`，
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
