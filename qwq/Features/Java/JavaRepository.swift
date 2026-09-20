import Foundation

// MARK: - Java 仓储协议

/// Java 安装数据的唯一出入口。
///
/// 上层不再直接读取 `DataManager.shared.javaVirtualMachines`、`LauncherSettings.shared.availableJavaList`
/// 或自行调用 `JavaManager.scanInstalledJava`，统一经由此协议获取。
protocol JavaRepository: Sendable {

    /// 当前已发现的 Java 安装（允许使用既有缓存）。
    func installed() async -> [JavaInstallation]

    /// 强制重新扫描磁盘后返回最新列表。
    func refresh() async -> [JavaInstallation]

    /// 记录本次采纳的 Java，供后续 `installed()` 优先返回；写入失败静默忽略。
    func save(_ installation: JavaInstallation) async

    /// 触发一次后台预扫描（界面启动时预热 Java 列表）。
    /// 扫描结果由实现写回设置与实例清单，调用方不需要返回值。
    func preScan()
}

// MARK: - 默认实现

/// 复用 `JavaManager` 既有的扫描管线（发现 -> 解析 -> 缓存），不做二次实现。
///
/// `scanInstalledJava` 为同步实现且内部会拉起子进程，
/// 因此在 detached task 中以 utility 优先级执行，避免阻塞调用方所在的 actor 或主线程。
final class DefaultJavaRepository: JavaRepository {

    /// 进程级共享实例：预扫描等无状态调用不再重复构造。
    static let shared = DefaultJavaRepository()

    init() {}

    func installed() async -> [JavaInstallation] {
        await scan(useCache: true)
    }

    func refresh() async -> [JavaInstallation] {
        await scan(useCache: false)
    }

    func save(_ installation: JavaInstallation) async {
        JavaManager.shared.saveCachedJavaPath(installation.executablePath)
    }

    func preScan() {
        // 复用既有 JavaManager 的预扫描管线（结果写回 LauncherSettings.availableJavaList
        // 与 DataManager.javaVirtualMachines），语义与旧调用点完全一致；
        // JavaManager 的直接引用只保留在 Java 模块内部，上层不再触达。
        JavaManager.shared.preScanJavaAsync()
    }

    private func scan(useCache: Bool) async -> [JavaInstallation] {
        // 在 detached task 内完成扫描与转换，跨线程只传递 Sendable 的 JavaInstallation
        await Task.detached(priority: .utility) { () -> [JavaInstallation] in
            JavaManager.shared.scanInstalledJava(useCache: useCache).map { JavaInstallation($0) }
        }.value
    }
}
