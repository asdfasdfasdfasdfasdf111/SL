//
//  CacheStorage.swift
//  SL启动器
//
//  下载项的本地缓存：**按文件内容的 SHA-1 存放**，索引单独落成 index.json。
//
//  目录布局：
//    <rootURL>/index.json                    索引，name → (hash, type)
//    <rootURL>/SHA-1/<hash 前两位>/<hash>     实际文件内容
//  因为路径由内容决定，**同一份内容只会存在一份**；索引里允许多个 name 指向它，
//  这就是「内容寻址」带来的天然去重。
//
//  并发：对外读写全由一把 `NSRecursiveLock` 串行化。锁必须是**可重入**的 ——
//  `copy` / `add` 会持锁调用同样要加锁的 `save()`。
//
//  Created by YiZhiMCQiu on 2025/7/10.
//

import Foundation
import SwiftyJSON

/// 用于缓存下载项。
public class CacheStorage {
    /// 默认实例：应用支持目录下的 `minecraft/cache`。
    /// 它是 `static let`，首次访问即构造 —— 构造过程会建目录并读一次 index.json。
    public static let `default`: CacheStorage = .init(rootURL: URL.applicationSupportDirectory.appendingPathComponent("minecraft").appendingPathComponent("cache"))
    
    private let rootURL: URL
    /// 内存里的索引镜像。**改它之后必须调 `save()` 才落盘** ——
    /// `add` 里那句「必须先 append 再 save」说的就是这件事。
    private var libraries: [Library]
    /// 保护 `libraries` 与磁盘写入。用**可重入**锁是必需的：
    /// `copy` 持锁时会调用同样要加锁的 `save()`（同一线程二次进入）。
    private let lock = NSRecursiveLock()
    
    /// 打开（必要时创建）一个缓存目录，并尽力读入已有索引。
    /// **不会失败**：目录建不出来、index.json 读不动，都只回落成空索引
    /// （下一次 `save()` 会把磁盘上的旧索引整个覆盖重建）。
    public init(rootURL: URL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let indexURL = rootURL.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                // readToEnd 可能返回 nil（空/损坏文件），强解包会崩；失败走空索引重建
                let fh = try FileHandle(forReadingFrom: indexURL)
                defer { try? fh.close() }
                guard let data = try fh.readToEnd() else {
                    err("index.json 读取为空，重建缓存索引")
                    self.libraries = []
                    return
                }
                let json = try JSON(data: data)
                self.libraries = json["libraries"].arrayValue.map(Library.init)
            } catch {
                err("无法读取 index.json: \(error.localizedDescription)")
                self.libraries = []
            }
        } else {
            self.libraries = []
        }
    }
    
    /// 把内存索引原子写回 index.json（`.atomic` = 先写临时文件再改名，
    /// 避免进程中途被杀留下半截 JSON）。
    /// ⚠️ 返回 Void，失败只记一条日志 —— **调用方无法得知写没写成功**。
    public func save() {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            try encoder.encode(["libraries" : libraries]).write(to: rootURL.appendingPathComponent("index.json"), options: .atomic)
        } catch {
            err("无法保存 libraries: \(error.localizedDescription)")
        }
    }
    
    /// 由内容 SHA-1 推出存放路径：`SHA-1/<前两位>/<完整 hash>`。
    /// 前两位分桶是为了避免单目录下文件数过多（与官方 assets 的布局同理）。
    /// ⚠️ 传入短于 2 位的 hash 不会报错，只会得到不合规范的路径。
    public func getLibraryPath(_ hash: String) -> URL {
        rootURL
            .appendingPathComponent("SHA-1")
            .appendingPathComponent(String(hash.prefix(2)))
            .appendingPathComponent(hash)
    }
    
    /// 把索引里名为 name 的库复制到 `dest`。
    ///
    /// 三条分支语义各不相同：
    /// - `dest` 已存在 → 直接返回 true，**不覆盖、也不比对内容**（「有就当好了」）；
    /// - 索引里有该 name 但内容文件已不在磁盘上 → **顺手把这条索引删掉并落盘**，然后返回 false。
    ///   即本方法带写副作用，不只是读；
    /// - 索引里没有该 name → 返回 false，不报错。
    public func copy(name: String, to dest: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // 目标已存在 → 视为已有，不做 hash 比对（调用方要为「内容其实是旧的」负责）。
        if FileManager.default.fileExists(atPath: dest.path) {
            return true
        }
        // 线性查找；缓存条目量级为几十到几百，未另建索引。
        if let library = libraries.first(where: { $0.name == name }) {
            let path = getLibraryPath(library.hash)
            
            // 索引与磁盘不一致（文件被手工删过 / 上次写盘失败）：
            // 把失效条目剔除并落盘，免得它以后每次都绊这一下。
            guard FileManager.default.fileExists(atPath: path.path) else {
                err("\(library.name) 对应的文件 (\(path.path)) 不存在！")
                libraries.removeAll(where: { $0.hash == library.hash })
                save()
                return false
            }
            
            do {
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: path, to: dest)
                debug("成功拷贝文件: \(name)")
                return true
            } catch {
                err("无法拷贝文件: \(error.localizedDescription)")
            }
        }
        return false
    }
    
    /// 把 `path` 指向的文件登记进缓存：内容按 SHA-1 存一份，索引里加一条 name → hash。
    ///
    /// - name 已存在时**直接返回**，不会更新 hash —— 同一个 name 只认第一次登记的内容；
    /// - 算不出 SHA-1（文件读不了）时记日志并返回，**不抛错**；
    /// - 内容文件已存在时**跳过复制**（hash 相同即内容相同，天然去重）；
    /// - **不会删除源文件**，清理由调用方负责。
    public func add(name: String, path: URL) {
        lock.lock()
        defer { lock.unlock() }
        // 同名只登记一次：即便内容变了也不会更新（要让新内容生效，得先手工清掉旧条目）。
        if libraries.contains(where: { $0.name == name }) {
            return
        }
        
        let hash: String
        do {
            hash = try Util.sha1OfFile(url: path)
        } catch {
            err("无法获取 SHA-1: \(error.localizedDescription)")
            return
        }
        let dest = getLibraryPath(hash)
        let destExists = FileManager.default.fileExists(atPath: dest.path)
        if !destExists {
            do {
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: path, to: dest)
            } catch {
                err("无法复制文件: \(error.localizedDescription)")
                return
            }
        }

        // type 恒为 "jar"：这个缓存只用于依赖库 jar，字段留着是给索引格式留扩展余地。
        libraries.append(.init(name: name, hash: hash, type: "jar"))
        save()  // 必须先 append 再 save，否则磁盘索引缺少本次条目，重启后索引查询不到该库
    }
    
    /// 索引条目。整体 `private`：index.json 的字段格式属于本类型的内部细节，
    /// 外部只能通过 `add` / `copy` 这两个方法间接使用它。
    private struct Library: Codable {
        public let name: String
        public let hash: String
        public let type: String
        
        init(name: String, hash: String, type: String) {
            self.name = name
            self.hash = hash
            self.type = type
        }
        
        init(_ json: JSON) {
            self.name = json["name"].stringValue
            self.hash = json["hash"].stringValue
            self.type = json["type"].stringValue
        }
    }
}
