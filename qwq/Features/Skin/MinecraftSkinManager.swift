import Foundation

// MARK: - 皮肤管理器（重构：皮肤文件存磁盘，不再塞 UserDefaults）
// 已拆出：SkinAvatarCropper（头像裁剪）/ SkinResourcePackApplier（PCL2 资源包方案，离线皮肤主路径）。
// 第三十一批清理死代码：删除无调用者的 authlib-injector 下载/JVM 参数构建与 JAR 修改方式
// （downloadAuthlibInjector/buildOfflineSkinMeta/buildAuthlibInjectorArgs/applySkinToJar/
// restoreOriginalJar/isAuthlibInjectorAvailable/getAuthlibInjectorPath/runCommand），
// 离线登录走 PCLCore（MinecraftLauncher.downloadAuthlibInjector），离线皮肤走资源包方案。
// 本类仅保留皮肤持久化（saveSkin/getSkinData/skinsDirectory）。

class MinecraftSkinManager {
    static let shared = MinecraftSkinManager()
    private let fileManager = FileManager.default

    // 皮肤持久化目录
    var skinsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SL启动器/Skins")
    }

    /// 保存皮肤到持久化目录（文件系统，不再塞 UserDefaults）
    func saveSkin(_ skinURL: URL, forUUID uuid: String) throws -> URL {
        try fileManager.createDirectory(at: skinsDirectory, withIntermediateDirectories: true)

        let skinData = try Data(contentsOf: skinURL)
        let destURL = skinsDirectory.appendingPathComponent("\(uuid).png")

        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try skinData.write(to: destURL)

        return destURL
    }

    /// 获取皮肤数据（优先磁盘，不缓存大对象到内存）
    func getSkinData(forUUID uuid: String) -> Data? {
        let url = skinsDirectory.appendingPathComponent("\(uuid).png")
        return try? Data(contentsOf: url)
    }
}
