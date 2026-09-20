import Foundation

/// Java 解析的同步桥接层。
///
/// 背景：`PCLLaunchBridge.pclLaunchInternal` 运行在同步上下文里（内部用 `DispatchSemaphore`
/// 等待扫描结果），而统一的 `JavaResolver` 是 async 接口。直接把启动桥改成异步会牵动
/// 整条进程启动链路，风险过高。
///
/// 因此这里提供一个**受超时保护**的同步包装：启动链路复用统一解析器，
/// 失败或超时返回 `nil`，由调用方回退到旧链路，保证行为不退化。
enum JavaResolverBridge {

    /// 同步解析一次 Java。
    /// - Parameters:
    ///   - minimumMajor: 最低 Java 主版本要求（0 表示不限制）
    ///   - mcVersion: Minecraft 版本号，仅用于日志追溯
    ///   - timeout: 等待上限；超时即放弃，避免阻塞应用启动
    /// - Returns: 可用 Java 的可执行文件路径；解析失败或超时返回 nil
    static func resolveSynchronously(
        minimumMajor: Int,
        mcVersion: String?,
        timeout: TimeInterval = 8
    ) -> URL? {
        let requirement = JavaRequirement(
            minimumMajor: max(0, minimumMajor),
            mcVersion: mcVersion,
            remarks: "PCLLaunchBridge 同步桥接"
        )

        let resolver = DefaultJavaResolver()
        let semaphore = DispatchSemaphore(value: 0)
        var resolved: URL?

        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }
            do {
                let installation = try await resolver.resolve(requirement)
                resolved = installation.executableURL
            } catch {
                // 解析失败不是错误路径：调用方会回退到既有链路
                NSLog("[JavaResolverBridge] Java 解析未命中：\(error.localizedDescription)")
            }
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            NSLog("[JavaResolverBridge] Java 解析超时（\(Int(timeout))s），回退既有链路")
            return nil
        }
        return resolved
    }
}
