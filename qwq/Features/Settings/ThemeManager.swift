import AppKit
import SwiftUI

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    private let settings = AppSettingsStore.shared

    @Published var accentColor: Color {
        didSet {
            settings.accentColor = accentColor
        }
    }

    private init() {
        self.accentColor = settings.accentColor
    }
}

class LauncherSettings: ObservableObject {
    static let shared = LauncherSettings()

    private let settings = AppSettingsStore.shared

    @Published var selectedMinecraftVersion: String {
        didSet { settings.selectedMinecraftVersion = selectedMinecraftVersion }
    }

    @Published var selectedGameRoot: String {
        didSet { settings.selectedGameRoot = selectedGameRoot }
    }

    @Published var offlineUsername: String {
        didSet { settings.offlineUsername = offlineUsername }
    }

    @Published var cachedJavaPath: String? {
        didSet { settings.cachedJavaPath = cachedJavaPath }
    }

    @Published var avatarImageURL: URL? {
        didSet { settings.avatarImageURL = avatarImageURL }
    }

    @Published var skinImageURL: URL? {
        didSet { settings.skinImageURL = skinImageURL }
    }

    @Published var showLaunchAlert = false
    @Published var launchErrorMessage: String?
    @Published var showJavaPopup = false
    @Published var javaPopupMessage = "正在选择 Java..."

    @Published var appliedSkinHash: String? {
        didSet { settings.appliedSkinHash = appliedSkinHash }
    }

    @Published var fixedOfflineUUID: String {
        didSet { settings.fixedOfflineUUID = fixedOfflineUUID }
    }

    @Published var availableJavaList: [JavaInfo] = []
    @Published var isJavaScanning: Bool = true

    @Published var selectedJavaPath: String? {
        didSet { settings.selectedJavaPath = selectedJavaPath }
    }

    private init() {
        self.selectedMinecraftVersion = settings.selectedMinecraftVersion
        self.selectedGameRoot = settings.selectedGameRoot
        self.offlineUsername = settings.offlineUsername
        self.cachedJavaPath = settings.cachedJavaPath
        self.avatarImageURL = settings.avatarImageURL
        self.skinImageURL = settings.skinImageURL
        self.appliedSkinHash = settings.appliedSkinHash
        self.fixedOfflineUUID = settings.fixedOfflineUUID
        self.availableJavaList = settings.availableJavaList
        self.isJavaScanning = settings.isJavaScanning
        self.selectedJavaPath = settings.selectedJavaPath
    }
}

func generateFixedUUIDForSteve() -> String {
    return "f47ac10b-58cc-4372-a567-0e02b2c3d479"
}
