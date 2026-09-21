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
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SL启动器")
        appSupportURL = supportURL
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)

        // 传入缓存目录，避免 CacheManager 内部访问 AppContext.shared 造成递归锁
        cacheManager = CacheManager(cacheRoot: supportURL.appendingPathComponent("Cache"))

        // 启动清理磁盘缓存：翻译缓存等超过 30 天未访问的文件删除（可随时重新生成，控制 Cache 目录体积）。
        //
        // 隔离修正：`cleanDiskCache(olderThan:)` 声明在 `CacheManager`，该类未显式标注隔离，被工程
        // 默认隔离（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）推断为 `@MainActor`，属主 actor 隔离
        // 方法；`Task.detached` 不继承任何 actor 隔离，在其闭包内同步调用会触发
        // 「main actor-isolated instance method cannot be called from outside of the actor」告警
        // （Swift 6 语言模式下为错误）。此处改用 `Task(priority:operation:)`——它继承当前 actor
        // 上下文，并显式标注 `@MainActor`，使调用在主 actor 上完成；清理是启动期一次性的目录枚举，
        // 不落在滚动等高频路径上。
        // 依据：《Concurrency》Unstructured Concurrency —— `Task.detached` 不继承 actor 隔离、优先级
        //       与任务局部状态，`Task { }` 继承当前任务的 actor 隔离；`@MainActor` 闭包标注须写在
        //       捕获列表之前、`in` 之前。
        // 依据：《Concurrency》The Main Actor —— `@MainActor` 函数只在主 actor 上运行，从主 actor
        //       代码中可同步调用，从非主 actor 代码调用必须 `await` 切换。
        // 官方链接：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
        Task(priority: .utility) { @MainActor [cacheManager] in
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