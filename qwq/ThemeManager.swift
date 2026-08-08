import SwiftUI
import AppKit
import Combine

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
    static let cachedJavaPaths = "cachedJavaPaths"
}

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    @Published var accentColor: Color {
        didSet {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(accentColor), requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: UDK.accentColor)
            }
        }
    }
    private init() {
        if let data = UserDefaults.standard.data(forKey: UDK.accentColor),
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            accentColor = Color(nsColor)
        } else {
            accentColor = .blue
        }
    }
}

func generateFixedUUIDForSteve() -> String {
    return "f47ac10b-58cc-4372-a567-0e02b2c3d479"
}

class LauncherSettings: ObservableObject {
    static let shared = LauncherSettings()
    
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
    @Published var showLaunchAlert = false
    @Published var launchErrorMessage: String?
    @Published var showJavaPopup = false
    @Published var javaPopupMessage = "正在选择 Java..."
    @Published var appliedSkinHash: String? {
        didSet { UserDefaults.standard.set(appliedSkinHash, forKey: UDK.appliedSkinHash) }
    }
    @Published var fixedOfflineUUID: String = {
        if let saved = UserDefaults.standard.string(forKey: UDK.fixedOfflineUUID) {
            return saved
        } else {
            let newUUID = generateFixedUUIDForSteve()
            UserDefaults.standard.set(newUUID, forKey: UDK.fixedOfflineUUID)
            return newUUID
        }
    }()
    @Published var availableJavaList: [JavaInfo] = []
    @Published var isJavaScanning: Bool = true
    @Published var selectedJavaPath: String? {
        didSet { UserDefaults.standard.set(selectedJavaPath, forKey: UDK.selectedJavaPath) }
    }

    private init() {
        self.selectedMinecraftVersion = UserDefaults.standard.string(forKey: UDK.selectedMinecraftVersion) ?? ""
        self.selectedGameRoot = UserDefaults.standard.string(forKey: UDK.selectedGameRoot) ?? ""
        self.offlineUsername = UserDefaults.standard.string(forKey: UDK.offlineUsername) ?? "Player"
        self.cachedJavaPath = UserDefaults.standard.string(forKey: UDK.cachedJavaPath)
        self.appliedSkinHash = UserDefaults.standard.string(forKey: UDK.appliedSkinHash)
        self.selectedJavaPath = UserDefaults.standard.string(forKey: UDK.selectedJavaPath)
        if let path = UserDefaults.standard.string(forKey: UDK.avatarImagePath) {
            self.avatarImageURL = URL(fileURLWithPath: path)
        } else {
            if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                self.avatarImageURL = builtinURL
            } else {
                self.avatarImageURL = nil
            }
        }
        if let path = UserDefaults.standard.string(forKey: UDK.skinImagePath) {
            self.skinImageURL = URL(fileURLWithPath: path)
        } else {
            self.skinImageURL = nil
        }
    }
}