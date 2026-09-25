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
        // ⚠️ queue 必须显式给 `.main`：官方对该参数只说「用于执行事件处理器的队列」，
        // 未定义传 nil 时落在哪个队列。而事件最终会触达主 actor 隔离的静态缓存清理
        //（见 `MemoryCacheReclaimer`）—— 从后台队列去碰它就是一次静默的跨隔离访问。
        //
        // ⚠️ 这里**不认识任何具体 UI 类型**：只把「系统内存压力」翻译成应用内事件并发布，
        // 谁需要回收缓存由装配层订阅（`App/MemoryCacheReclaimer.swift`）。
        // 此前实现直接调用 `DownloadCategoryView.clearStaticCaches()` ——
        // 一个 View 上的静态方法，构成 Infrastructure → UI 的反向依赖。
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // 半清而非全清：保留最近使用的一半（LRU 裁剪），避免压力过后所有缓存
            // 重新从磁盘/网络回填；真正的临界压力由系统触发多次事件逐步收紧
            self.cacheManager.trimMemory(toFraction: 0.5)
            // 等级只能从 source 的事件掩码读（`setEventHandler` 的闭包没有入参）。
            // 这里经 `self.memoryPressureSource` 间接取用，**不直接捕获 `source`** ——
            // 否则 source ↔ handler 互相强引用成环，`deinit` 里的 `cancel()` 永远等不到。
            // 因此 `memoryPressureSource` 必须在 `activate()` **之前**赋值，
            // 否则先激活后赋值的那段窗口里读到 nil，会被误判成 `.warning`。
            let level: MemoryPressureLevel = (self.memoryPressureSource?.data.contains(.critical) ?? false)
                ? .critical : .warning
            MemoryPressureBroadcaster.shared.post(level)
        }
        // 官方 Discussion 明文：新建的 dispatch source 处于 inactive 状态，必须显式 `activate()`
        // 才开始派发事件（原写法 `resume()` 虽是旧式等价物，但官方指名的入口是 `activate()`）。
        // 顺序：先赋值、后 activate（理由见上）。
        memoryPressureSource = source
        source.activate()
    }

    deinit {
        memoryPressureSource?.cancel()
    }
}