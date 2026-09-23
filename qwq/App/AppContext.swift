import Foundation

// MARK: - 统一应用上下文（依赖注入容器，替代散落的单例）

/// 集中管理所有共享资源，避免各组件各自创建 URLSession/Process 导致资源浪费
final class AppContext {
    static let shared = AppContext()

    // MARK: - 共享网络层

    /// 通用下载（30s 请求超时，10min 资源超时，8 并发）。
    /// 禁用系统代理直连：下载目标为微软 JDK / Azul CDN（国内直连可达），
    /// 系统代理出口 TLS 转发失败会报 SecureConnectionFailed（与 Requests.swift 统一直连会话一致）
    let downloadSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 600
        c.httpMaximumConnectionsPerHost = 8
        c.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024)
        return URLSession(configuration: c)
    }()

    /// API 请求（10s 请求超时，15s 资源超时，4 并发）
    let apiSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 15
        c.httpMaximumConnectionsPerHost = 4
        c.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024)
        return URLSession(configuration: c)
    }()

    /// 翻译服务（8s 请求超时，12s 资源超时）
    let translateSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 12
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()

    // MARK: - 进程池

    let processPool = ProcessPool(maxConcurrent: 3)

    // MARK: - 文件管理器

    let fileManager = FileManager.default

    /// App Support 目录
    let appSupportURL: URL

    // MARK: - 缓存管理（在 init 中初始化，避免循环依赖）

    let cacheManager: CacheManager

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        let supportURL = URL.applicationSupportDirectory
            .appendingPathComponent("SL启动器")
        appSupportURL = supportURL
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)

        // 传入缓存目录，避免 CacheManager 内部访问 AppContext.shared 造成递归锁
        cacheManager = CacheManager(cacheRoot: supportURL.appendingPathComponent("Cache"))

        // 启动清理磁盘缓存：删除翻译缓存等超过 30 天未访问的文件（可随时重新生成，控制 Cache 目录体积）。
        //
        // 隔离修正 v2（第四轮治理）：
        // - `cleanDiskCache(olderThan:)` 已标 `nonisolated`——函数体只访问 `diskRoot`（`let URL`，Sendable）
        //   与 `fileManager`（非隔离计算属性），不碰任何 @Published / 主 actor 隔离状态，可安全脱离主 actor。
        // - `CacheManager` 现为 `@unchecked Sendable`（内部 `memCache` 由 `lock` 串行化、磁盘方法用
        //   `fileManager` 原子写，线程安全），因此可被 `Task.detached` 的捕获列表按值捕获。
        // - 改用 `Task.detached`（不继承任何 actor 隔离）将整段目录枚举落到后台协作线程池，
        //   冷启动首帧不再被 `enumerator(at:)` + 逐文件 `resourceValues` 拖住数百 ms～数秒。
        // 依据：《Concurrency》Unstructured Concurrency —— `Task.detached` 不继承 actor 隔离，闭包体
        //       运行在协作线程池；调用 `nonisolated` 方法无需 `await`，不会切回主 actor。
        // 官方链接：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
        Task.detached(priority: .utility) { [cacheManager] in
            cacheManager.cleanDiskCache(olderThan: 30)
        }

        // 响应内存压力（macOS 上没有 NSApplication.didReceiveMemoryWarning，使用 DispatchSource）
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
        source.setEventHandler { [weak self] in
            // 半清而非全清：保留最近使用的一半（LRU 裁剪），避免压力过后所有缓存
            // 重新从磁盘/网络回填；真正的临界压力由系统触发多次事件逐步收紧
            self?.cacheManager.trimMemory(toFraction: 0.5)
            DownloadCategoryView.clearStaticCaches()
        }
        source.resume()
        memoryPressureSource = source
    }

    deinit {
        memoryPressureSource?.cancel()
    }
}