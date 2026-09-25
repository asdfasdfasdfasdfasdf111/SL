//
//  OfflineAccount.swift
//  离线账号：账号协议、真实实现、以及 PCL2 离线 UUID 算法。
//
//  历史：本文件的内容原先混在 `SLCore/Stubs.swift` 里 —— 那个文件叫「Stubs」，却装着
//  逐行移植自 PCL2 的真实业务逻辑（离线 UUID、用户名校验）。名称与内容不符会导致
//  下一轮「清理桩代码」时误删真实现，因此按职责拆分，每个符号都落在名副其实的文件里。
//
//  职责：`Account` 协议的定义、`OfflineAccount` 的实现（含 UUID 算法三件套）、离线用户名校验。
//  边界：**不含任何联网认证** —— 微软 / Yggdrasil 的枚举形状在 `SLCore/Account/AnyAccount.swift`，
//        两者均未实现且不得据此推断具备联网能力。
//
//  注释引用约定：一律写「文件 + 符号/场景」，**不写行号** —— 行号会随任何一次编辑漂移，
//  历史版本大量使用 `文件:行号`，经数轮重构后其中很多已指向错误位置甚至是已删除的代码。
//

import Foundation

// MARK: - Account / AnyAccount
/// 账号抽象。使用方：`OfflineAccount`（本文件）与 `AnyAccount`
/// （`SLCore/Account/AnyAccount.swift`）遵循本协议，
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
    /// 使用方：本文件 `OfflineAccount.init(_:_:)`（本文件内唯一调用点）。
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
