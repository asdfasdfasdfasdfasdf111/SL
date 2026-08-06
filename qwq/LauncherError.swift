import Foundation

enum LauncherError: Error, LocalizedError {
    case noJavaFound
    case noGameDirectoryFound
    case noVersionsFound
    case versionJsonMissing(path: String)
    case versionJarMissing(path: String)
    case skinValidationFailed(String)
    case jarModificationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noJavaFound: return "未找到任何 Java 运行时，请安装 Java 17 或更高版本"
        case .noGameDirectoryFound: return "未找到有效的 Minecraft 游戏目录（缺少 versions 子目录）"
        case .noVersionsFound: return "版本目录为空，请确保 versions 下至少有一个版本子目录"
        case .versionJsonMissing(let path): return "版本 JSON 文件不存在: \(path)"
        case .versionJarMissing(let path): return "版本 JAR 文件不存在: \(path)"
        case .skinValidationFailed(let msg): return "皮肤无效: \(msg)"
        case .jarModificationFailed(let msg): return "修改皮肤失败: \(msg)"
        }
    }
}