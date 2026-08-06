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
        self.name = name
        // 离线玩家 UUID 生成
        if let uuid = uuid {
            self.uuid = uuid
        } else {
            var bytes = Array("OfflinePlayer:\(name)".utf8)
            while bytes.count < 16 { bytes.append(0) }
            bytes[6] = (bytes[6] & 0x0F) | 0x30
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            self.uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
    }
    public func putAccessToken(options: LaunchOptions) {
        options.accessToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
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
