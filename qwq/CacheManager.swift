import Foundation

// MARK: - 统一缓存管理器（LRU 内存缓存 + 磁盘持久化 + 内存压力响应）

/// 替代各处散落的 UserDefaults 大对象存储和静态字典缓存
/// - 内存缓存：LRU 淘汰，响应内存警告自动清空
/// - 磁盘缓存：按 key 分文件存储，避免 UserDefaults 膨胀
final class CacheManager {
    private let diskRoot: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var memCache = LRUCache<String, Data>(maxCost: 32 * 1024 * 1024) // 32MB

    init(cacheRoot: URL) {
        diskRoot = cacheRoot
        try? fileManager.createDirectory(at: diskRoot, withIntermediateDirectories: true)
    }

    // MARK: - 内存缓存

    func memoryGet(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return memCache.value(forKey: key)
    }

    func memorySet(_ key: String, data: Data, cost: Int = -1) {
        lock.lock(); defer { lock.unlock() }
        memCache.setValue(data, forKey: key, cost: cost > 0 ? cost : data.count)
    }

    func memoryRemove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        memCache.removeValue(forKey: key)
    }

    /// 内存缓存按比例裁剪（如内存压力时保留最近使用的 50%），比全清更平滑
    func trimMemory(toFraction fraction: Double) {
        lock.lock(); defer { lock.unlock() }
        memCache.trim(toCost: Int(Double(memCache.currentCost) * fraction))
    }

    func clearMemory() {
        lock.lock(); defer { lock.unlock() }
        memCache.removeAll()
    }

    // MARK: - 磁盘缓存
    // 注意：磁盘方法一律【不持 lock】。文件 IO 天然线程安全（写用 .atomic 原子替换），
    // 若在持 lock 期间做 Data(contentsOf:) 等磁盘操作，后台批量预热（如翻译缓存扫描）
    // 会长时间占用全局锁，导致主线程查内存缓存时排队等待 → 列表卡顿。
    // 锁内只允许微秒级的内存操作，磁盘读写全部在锁外完成。

    func diskGet(_ key: String) -> Data? {
        let url = diskURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    func diskSet(_ key: String, data: Data) {
        let url = diskURL(for: key)
        let dir = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func diskRemove(_ key: String) {
        try? fileManager.removeItem(at: diskURL(for: key))
    }

    func diskExists(_ key: String) -> Bool {
        fileManager.fileExists(atPath: diskURL(for: key).path)
    }

    // MARK: - 便捷：Codable 对象
    // 读取链路：锁内查内存（µs）→ 未命中则锁外读磁盘 → 命中回写内存（锁内）。
    // 这样后台线程做磁盘读时【不占用锁】，主线程 memoryObject/object 永远瞬时返回。

    func object<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        if let data = memoryGet(key) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        guard let data = diskGet(key) else { return nil }
        if let obj = try? JSONDecoder().decode(T.self, from: data) {
            memorySet(key, data: data)
            return obj
        }
        return nil
    }

    /// 仅查内存缓存（不触碰磁盘），用于批量快速扫描场景
    func memoryObject<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = memoryGet(key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func setObject<T: Codable>(_ object: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(object) else { return }
        memorySet(key, data: data)   // 锁内：内存写（µs）
        diskSet(key, data: data)     // 锁外：磁盘写（IO 在锁外，不阻塞其他线程查内存）
    }

    // MARK: - 纯文本缓存（翻译等高频字符串场景）
    // 相比 object/setObject 省去 JSON 引号转义与编解码；磁盘格式为 UTF-8 明文，
    // 读取时兼容旧版 JSON 字符串格式（"..."），一次解析、自动回写为明文。

    private static func decodeString(_ data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(String.self, from: data) { return decoded }
        return String(data: data, encoding: .utf8)
    }

    /// 读文本缓存：内存 → 磁盘（明文，兼容旧 JSON）→ 回写内存。磁盘 IO 全程在锁外。
    func textGet(_ key: String) -> String? {
        if let data = memoryGet(key) {
            return Self.decodeString(data)
        }
        guard let data = diskGet(key), let text = Self.decodeString(data), !text.isEmpty else { return nil }
        memorySet(key, data: Data(text.utf8))
        return text
    }

    /// 仅查内存文本缓存（不触碰磁盘）
    func memoryText(_ key: String) -> String? {
        guard let data = memoryGet(key) else { return nil }
        return Self.decodeString(data)
    }

    /// 写文本缓存：内存（锁内）+ 磁盘明文（锁外）
    func setText(_ text: String, forKey key: String) {
        let data = Data(text.utf8)
        memorySet(key, data: data)
        diskSet(key, data: data)
    }

    /// 批量预取磁盘文本缓存到内存（翻译预热专用）。
    /// 先一次性枚举磁盘收集已存在的文件名（readdir 级，无文件内容 IO），
    /// 再只对命中文件读盘，替代「对每个 key 各做一次 fileExists + 读」的随机 IO。
    /// 返回成功读到的 [key: text]，调用方可直接合并进 UI 状态。
    func prefetchText(keys: [String]) -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        var existing = Set<String>()
        if let topDirs = try? fileManager.contentsOfDirectory(atPath: diskRoot.path) {
            for dir in topDirs {
                let subPath = diskRoot.appendingPathComponent(dir).path
                if let names = try? fileManager.contentsOfDirectory(atPath: subPath) {
                    existing.formUnion(names)
                }
            }
        }
        guard !existing.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for key in keys where existing.contains(key) {
            guard let data = diskGet(key), let text = Self.decodeString(data), !text.isEmpty else { continue }
            memorySet(key, data: Data(text.utf8))
            result[key] = text
        }
        return result
    }

    func removeObject(forKey key: String) {
        memoryRemove(key)
        diskRemove(key)
    }

    // MARK: - 便捷：UserDefaults 兼容（小数据迁移用）

    func userDefaultsGet<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        if let obj = object(type, forKey: key) { return obj }
        // 回退读 UserDefaults（迁移期）
        if let data = UserDefaults.standard.data(forKey: key),
           let obj = try? JSONDecoder().decode(T.self, from: data) {
            setObject(obj, forKey: key)
            return obj
        }
        return nil
    }

    // MARK: - Utility

    private func diskURL(for key: String) -> URL {
        // 两层散列目录避免单目录文件过多
        let hash = key.sha1Prefix(2)
        return diskRoot.appendingPathComponent("\(hash)/\(key)")
    }

    /// 清理超过指定天数的磁盘缓存
    func cleanDiskCache(olderThan days: Int = 7) {
        guard let enumerator = fileManager.enumerator(at: diskRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for case let url as URL in enumerator {
            guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modDate = attrs.contentModificationDate,
                  modDate < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}

// MARK: - LRU 缓存

private final class LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key; self.value = value; self.cost = cost
        }
    }

    private var dict: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private var totalCost = 0
    private let maxCost: Int

    init(maxCost: Int) { self.maxCost = maxCost }

    /// 当前占用成本（供外部按比例裁剪）
    var currentCost: Int { totalCost }

    func value(forKey key: Key) -> Value? {
        guard let node = dict[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    func setValue(_ value: Value, forKey key: Key, cost: Int) {
        if let node = dict[key] {
            totalCost -= node.cost
            node.value = value
            node.cost = cost
            totalCost += cost
            moveToHead(node)
        } else {
            let node = Node(key: key, value: value, cost: cost)
            dict[key] = node
            addToHead(node)
            totalCost += cost
        }
        trim(toCost: maxCost)
    }

    /// 从最久未使用的一端裁剪，直到总成本 ≤ target
    func trim(toCost target: Int) {
        while totalCost > target, let tail = tail {
            dict.removeValue(forKey: tail.key)
            removeNode(tail)
            totalCost -= tail.cost
        }
    }

    func removeValue(forKey key: Key) {
        guard let node = dict[key] else { return }
        dict.removeValue(forKey: key)
        removeNode(node)
        totalCost -= node.cost
    }

    func removeAll() {
        dict.removeAll()
        head = nil; tail = nil
        totalCost = 0
    }

    private func addToHead(_ node: Node) {
        node.next = head; node.prev = nil
        head?.prev = node; head = node
        if tail == nil { tail = node }
    }

    private func removeNode(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        removeNode(node)
        addToHead(node)
    }
}

// MARK: - String SHA1 helper

private extension String {
    func sha1Prefix(_ len: Int) -> String {
        guard let data = data(using: .utf8) else { return "00" }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.prefix(len).map { String(format: "%02x", $0) }.joined()
    }
}

import CommonCrypto