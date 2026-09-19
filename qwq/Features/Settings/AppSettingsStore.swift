import AppKit
import Combine
import SwiftUI

/// 应用设置的唯一存储点。
///
/// 背景：此前设置项散落在 `ThemeManager`、`LauncherSettings` 以及各处的
/// `UserDefaults.standard.set(...)` 调用里，同一个数据有多个写入口，
/// 导致状态流向无法追踪，也难以测试。
///
/// 本类型的职责边界：
/// - 只负责“设置数据”的持有与持久化
/// - 不持有 Java、下载、启动等业务状态（那些属于各自的模块）
/// - `ThemeManager` / `LauncherSettings` 暂时保留为兼容层，逐步收窄后移除
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

    @Published var selectedJavaPath: String? {
        didSet { UserDefaults.standard.set(selectedJavaPath, forKey: UDK.selectedJavaPath) }
    }

    private init() {
        self.accentColor = Self.loadStoredColor(forKey: UDK.accentColor) ?? .blue
        self.selectedMinecraftVersion = UserDefaults.standard.string(forKey: UDK.selectedMinecraftVersion) ?? ""
        self.selectedGameRoot = UserDefaults.standard.string(forKey: UDK.selectedGameRoot) ?? ""
        self.offlineUsername = UserDefaults.standard.string(forKey: UDK.offlineUsername) ?? "Player"

        // 清理历史遗留脏数据：占位提示串曾被存成真实用户名，长度超过 MC 16 字符上限，
        // 在 1.20.5+ 进服时 hello 包编码会失败。
        let legacyPlaceholder = "SL启动器（最好使用英文及下划线）"
        if self.offlineUsername == legacyPlaceholder {
            self.offlineUsername = "Player"
            UserDefaults.standard.set(self.offlineUsername, forKey: UDK.offlineUsername)
        }

        self.cachedJavaPath = UserDefaults.standard.string(forKey: UDK.cachedJavaPath)
        self.appliedSkinHash = UserDefaults.standard.string(forKey: UDK.appliedSkinHash)
        self.selectedJavaPath = UserDefaults.standard.string(forKey: UDK.selectedJavaPath)

        if let saved = UserDefaults.standard.string(forKey: UDK.fixedOfflineUUID) {
            self.fixedOfflineUUID = saved
        } else {
            let uuid = generateFixedUUIDForSteve()
            self.fixedOfflineUUID = uuid
            UserDefaults.standard.set(uuid, forKey: UDK.fixedOfflineUUID)
        }

        if let path = UserDefaults.standard.string(forKey: UDK.avatarImagePath) {
            self.avatarImageURL = URL(fileURLWithPath: path)
        } else {
            self.avatarImageURL = Bundle.main.url(forResource: "stf", withExtension: "png")
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
              let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
            return nil
        }
        return Color(nsColor)
    }
}

/// 设置模块：把设置存储注册进模块上下文，后续调用方从上下文取，而不是直接摸单例。
final class SettingsModule: SLModule {
    let identifier = "settings"

    func register(in context: ModuleContext) throws {
        context.register(AppSettingsStore.shared, for: ModuleCapabilityKey<AppSettingsStore>("settings.store"))
    }
}

extension ModuleContext {
    func appSettingsStore() -> AppSettingsStore? {
        resolve(ModuleCapabilityKey<AppSettingsStore>("settings.store"))
    }
}
