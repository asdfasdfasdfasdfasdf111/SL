import Foundation
import SwiftUI
import Combine

// MARK: - Extensions
extension URL {
    public func parent() -> URL { deletingLastPathComponent() }
    public init(fileURLWithUserPath: String) {
        self.init(fileURLWithPath: fileURLWithUserPath.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path))
    }
}

extension Array {
    public func find(_ isTarget: @escaping (Element) -> Bool) -> Element? {
        for element in self { if isTarget(element) { return element } }
        return nil
    }
    public func union(_ another: any Collection<Element>) -> [Element] {
        var result = self
        for element in another { result.append(element) }
        return result
    }
}

public extension Optional {
    func unwrap(_ errorMessage: String? = nil, file: String = #file, line: Int = #line) throws -> Wrapped {
        guard let value = self else {
            throw MyLocalizedError(reason: errorMessage ?? "\(file.split(separator: "/").last!):\(line) 解包失败")
        }
        return value
    }
}

// MARK: - Hint function
public func hint(_ message: String, _ type: HintType = .info) {
    log("[Hint] \(message)")
}
public enum HintType { case info, finish, critical }

// MARK: - DataManager
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
public class AppRouter: ObservableObject {
    public enum Route: Equatable {
        case versionList(directory: MinecraftDirectory)
        case installing(_ task: InstallTasks)
        case other
    }
    private var stack: [Route] = []
    public func getLast() -> Route { stack.last ?? .other }
    public func removeLast() { if !stack.isEmpty { stack.removeLast() } }
    public func append(_ route: Route) { stack.append(route) }
}

// MARK: - AppSettings
public enum DownloadSourceOption: Codable { case official, mirror, both }
public enum ColorSchemeOption: Codable { case light, dark, system }

public class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    public var currentMinecraftDirectory: MinecraftDirectory? = .default
    public var defaultInstance: String? = nil
    public var hasMicrosoftAccount: Bool = false
    public var fileDownloadSource: DownloadSourceOption = .both
    public var versionManifestSource: DownloadSourceOption = .both
    public var lastVersionManifest: VersionManifest? = nil
    public var showPclMacPopup: Bool = true
    public var launchCount: Int = 0
    private init() {}
}

// MARK: - Account / AnyAccount
public protocol Account: Codable, Identifiable {
    var id: UUID { get }
    var uuid: UUID { get }
    var name: String { get }
    func putAccessToken(options: LaunchOptions) async
}

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
            let hex = OfflineAccount.pclLegacyUuidHex(for: name)
            self.uuid = UUID(uuidString: OfflineAccount.formatUuid(hex)) ?? UUID()
        }
    }

    /// PCL2 离线 UUID（32 位 hex）。移植自 ModLaunch.vb McLoginLegacyUuid + ModBase.vb GetHash
    public static func pclLegacyUuidHex(for name: String) -> String {
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

    public static func leftPad(_ s: String, to length: Int) -> String {
        if s.count >= length { return String(s.prefix(length)) }
        return String(repeating: "0", count: length - s.count) + s
    }

    /// 32 位 hex → 标准 8-4-4-4-12 UUID 字符串
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
public func validateOfflineUsername(_ raw: String) -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return "玩家名不能为空！" }
    if name.contains("\"") { return "玩家名不能包含英文引号！" }
    if name.utf16.count > 16 { return "玩家名不能超过 16 个字符！" }
    return ""
}

public enum AnyAccount: Account, Identifiable, Equatable {
    case offline(OfflineAccount)
    case microsoft(OfflineAccount) // stub: treat as OfflineAccount
    case yggdrasil(OfflineAccount) // stub: treat as OfflineAccount

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
}

public class AccountManager: ObservableObject {
    public static let shared = AccountManager()
    @CodableAppStorage("accounts") public var accounts: [AnyAccount] = []
    @CodableAppStorage("accountId") public var accountId: UUID? = nil
    private init() {}
    public func getAccount() -> AnyAccount? {
        if accountId == nil { accountId = accounts.first?.id }
        return accounts.first(where: { $0.id == accountId })
    }
}

// MARK: - PopupManager
public struct PopupButton {
    public let label: String
    public let style: PopupButtonStyle
    public static let ok = PopupButton(label: "确定", style: .normal)
    public init(label: String, style: PopupButtonStyle = .normal) {
        self.label = label
        self.style = style
    }
}
public enum PopupButtonStyle { case normal, accent, danger }
public enum PopupType { case info, warning, error }
public struct PopupModel {
    public let type: PopupType
    public let title: String
    public let message: String
    public let buttons: [PopupButton]
    public init(_ type: PopupType, _ title: String, _ message: String, _ buttons: [PopupButton]) {
        self.type = type; self.title = title; self.message = message; self.buttons = buttons
    }
}

@MainActor
public class PopupManager: ObservableObject {
    public static let shared = PopupManager()
    private init() {}
    public func show(_ model: PopupModel) async {}
    public func showAsync(_ model: PopupModel) async -> Int { 0 }
}

// MARK: - NetworkTest
public class NetworkTest {
    public static let shared = NetworkTest()
    private init() {}
    public func hasNetworkConnection() -> Bool { true }
}

// MARK: - CodableAppStorage (simplified)
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

// MARK: - DownloadSourceProtocol (compat for old GameVersionDownloader)
public typealias DownloadSourceProtocol = DownloadSource

extension DownloadSourceManager {
    public var source: DownloadSource { getDownloadSource() }
}

// MARK: - Theme (stub)
public class Theme {
    public var id: String
    public init(id: String) { self.id = id }
    public static func load(id: String) -> Theme { Theme(id: id) }
}

public class ColorConstants {
    public static var colorScheme: ColorSchemeOption = .system
}
