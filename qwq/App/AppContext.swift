import Foundation

/// Application-wide infrastructure container.
///
/// The container remains a compatibility singleton while callers migrate to
/// explicit module dependencies. It owns shared infrastructure only; feature
/// state belongs to its feature module.
final class AppContext {
    static let shared = AppContext()

    let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024)
        return URLSession(configuration: configuration)
    }()

    let apiSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024)
        return URLSession(configuration: configuration)
    }()

    let translateSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    let processPool = ProcessPool(maxConcurrent: 3)
    let fileManager = FileManager.default
    let appSupportURL: URL
    let cacheManager: CacheManager
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SL启动器")
        appSupportURL = supportURL
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        cacheManager = CacheManager(cacheRoot: supportURL.appendingPathComponent("Cache"))

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
        source.setEventHandler { [weak self] in
            self?.cacheManager.trimMemory(toFraction: 0.5)
            self?.processPool.clearMemoryCaches()
            DownloadCategoryView.clearStaticCaches()
        }
        source.resume()
        memoryPressureSource = source

        let cache = cacheManager
        Task.detached(priority: .utility) {
            cache.cleanDiskCache(olderThan: 30)
        }
    }

    deinit {
        memoryPressureSource?.cancel()
    }
}
