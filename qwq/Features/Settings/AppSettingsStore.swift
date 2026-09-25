import AppKit
import Combine
import SwiftUI

enum UDK {
    static let accentColor = "accentColor"
    static let selectedMinecraftVersion = "selectedMinecraftVersion"
    static let selectedGameRoot = "selectedGameRoot"
    static let offlineUsername = "offlineUsername"
    static let cachedJavaPath = "cachedJavaPath"
    static let avatarImagePath = "avatarImagePath"
    static let skinImagePath = "skinImagePath"
    static let appliedSkinHash = "appliedSkinHash"
    static let fixedOfflineUUID = "fixedOfflineUUID"
    static let selectedJavaPath = "selectedJavaPath"
}

/// Application settings store extracted from the ad-hoc global settings used by
/// the UI layer. This is the first boundary of the Settings module:
///
/// - UI code reads from this object.
/// - persistence is centralized here.
/// - the old `LauncherSettings` and `ThemeManager` remain as compatibility
///   wrappers while the project is gradually migrated.
final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()

    @Published var accentColor: Color {
        didSet { saveColor(accentColor, forKey: UDK.accentColor) }
    }

    @Published var selectedMinecraftVersion: String {
        didSet { UserDefaults.standard.set(selectedMinecraftVersion, forKey: UDK.selectedMinecraftVersion) }
    }

    @Published var selectedGameRoot: String {
        didSet { UserDefaults.standard.set(selectedGameRoot, forKey: UDK.selectedGameRoot) }
    }

    @Published var offlineUsername: String {
        didSet { UserDefaults.standard.set(offlineUsername, forKey: UDK.offlineUsername) }
    }

    @Published var cachedJavaPath: String? {
        didSet { UserDefaults.standard.set(cachedJavaPath, forKey: UDK.cachedJavaPath) }
    }

    @Published var avatarImageURL: URL? {
        didSet {
            if let url = avatarImageURL {
                UserDefaults.standard.set(url.path, forKey: UDK.avatarImagePath)
            } else {
                UserDefaults.standard.removeObject(forKey: UDK.avatarImagePath)
            }
        }
    }

    @Published var skinImageURL: URL? {
        didSet {
            if let url = skinImageURL {
                UserDefaults.standard.set(url.path, forKey: UDK.skinImagePath)
            } else {
                UserDefaults.standard.removeObject(forKey: UDK.skinImagePath)
            }
        }
    }

    @Published var appliedSkinHash: String? {
        didSet { UserDefaults.standard.set(appliedSkinHash, forKey: UDK.appliedSkinHash) }
    }

    @Published var fixedOfflineUUID: String {
        didSet { UserDefaults.standard.set(fixedOfflineUUID, forKey: UDK.fixedOfflineUUID) }
    }

    @Published var availableJavaList: [JavaInfo] = []

    @Published var isJavaScanning: Bool = true

    @Published var selectedJavaPath: String? {
        didSet { UserDefaults.standard.set(selectedJavaPath, forKey: UDK.selectedJavaPath) }
    }

    private init() {
        let savedColor = Self.loadStoredColor(forKey: UDK.accentColor) ?? .blue
        self.accentColor = savedColor

        self.selectedMinecraftVersion = UserDefaults.standard.string(forKey: UDK.selectedMinecraftVersion) ?? ""
        self.selectedGameRoot = UserDefaults.standard.string(forKey: UDK.selectedGameRoot) ?? ""
        let storedOfflineUsername = UserDefaults.standard.string(forKey: UDK.offlineUsername) ?? "Player"
        self.offlineUsername = storedOfflineUsername
        self.cachedJavaPath = UserDefaults.standard.string(forKey: UDK.cachedJavaPath)
        self.appliedSkinHash = UserDefaults.standard.string(forKey: UDK.appliedSkinHash)
        self.selectedJavaPath = UserDefaults.standard.string(forKey: UDK.selectedJavaPath)

        if storedOfflineUsername == "SL启动器（最好使用英文及下划线）" {
            self.offlineUsername = "Player"
            UserDefaults.standard.set("Player", forKey: UDK.offlineUsername)
        }

        if let path = UserDefaults.standard.string(forKey: UDK.fixedOfflineUUID) {
            self.fixedOfflineUUID = path
        } else {
            let uuid = generateFixedUUIDForSteve()
            self.fixedOfflineUUID = uuid
            UserDefaults.standard.set(uuid, forKey: UDK.fixedOfflineUUID)
        }

        if let path = UserDefaults.standard.string(forKey: UDK.avatarImagePath) {
            self.avatarImageURL = URL(fileURLWithPath: path)
        } else if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
            self.avatarImageURL = builtinURL
        } else {
            self.avatarImageURL = nil
        }

        if let path = UserDefaults.standard.string(forKey: UDK.skinImagePath) {
            self.skinImageURL = URL(fileURLWithPath: path)
        } else {
            self.skinImageURL = nil
        }
    }

    private func saveColor(_ color: Color, forKey key: String) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(color), requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadStoredColor(forKey key: String) -> Color? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        else {
            return nil
        }
        return Color(nsColor)
    }
}

final class SettingsModule: SLModule {
    let identifier = "settings"

    func register(in context: ModuleContext) throws {
        var mutableContext = context
        mutableContext.register(AppSettingsStore.shared, for: ModuleCapabilityKey<AppSettingsStore>("settings.store"))
    }
}

extension ModuleContext {
    func appSettingsStore() -> AppSettingsStore? {
        resolve(ModuleCapabilityKey<AppSettingsStore>("settings.store"))
    }
}
