//
//  NetFileChecker.swift
//  SL启动器
//
//  文件四合一校验（ActualSize / MinSize / Hash / IsJson）。
//  自 NetDownloader.swift 按职责物理拆出，原第 16-90 行，逻辑、常量与文案均未改动。
//  本类型为公开 API：被预检、下载后校验与多处调用方直接使用，可见性与签名保持不变。
//

import Foundation
import CryptoKit

// MARK: - FileChecker（移植自上游 PCL2 的 ModBase.vb / FileChecker）

/// 一次文件校验所需的全部条件。每个条件都允许「不检查」——
/// 用负数或 nil 表示关闭，因此**默认构造出来的实例相当于「什么都不查」**。
/// 校验的执行在 `check(_:)`，而「已有文件能否直接复用」的决策在下载预检里。
public struct FileChecker {
    /// 期望的精确字节数；**-1 表示不校验**。
    /// ⚠️ 不要传 0：0 是有效值，含义会变成「要求文件必须恰好为空」。
    public var actualSize: Int64 = -1
    /// 期望的最小字节数（只要求 `>= minSize`）；**-1 表示不校验**。
    /// 用于「只想确认文件下完整了、但拿不到精确大小」的场景。
    public var minSize: Int64 = -1
    /// 期望的摘要值（十六进制文本，比较时大小写不敏感）；nil 表示不校验。
    /// 用哪种算法由**字符串长度**推断，分派规则见 `check(_:)` 内的说明。
    public var hash: String? = nil
    /// 是否允许「本地已有该文件就直接跳过下载」。
    /// ⚠️ 本类型只**存储**这个开关，判定逻辑在
    /// SLCore/Download/NetFilePreflight.swift —— 那里在决定复用前会先过一遍 `check`。
    public var canUseExistsFile: Bool = true
    /// 是否额外要求内容是可解析的 JSON。用于清单类文件 ——
    /// 只查大小/哈希是查不出「文件被截断成半份、但仍是合法 JSON 前缀」这类损坏的。
    public var isJson: Bool = false

    /// 全部参数都有默认值，`FileChecker()` 即「不做任何校验」。
    public init(actualSize: Int64 = -1, minSize: Int64 = -1, hash: String? = nil, canUseExistsFile: Bool = true, isJson: Bool = false) {
        self.actualSize = actualSize
        self.minSize = minSize
        self.hash = hash
        self.canUseExistsFile = canUseExistsFile
        self.isJson = isJson
    }

    /// 校验顺序固定为：文件存在 → actualSize → minSize → hash → isJson，
    /// **遇到第一个不通过的条件立即返回**。返回值是面向用户的文案（会直接展示），
    /// 因此调用方不应把它再包一层「校验失败：」之类的废话。
    ///
    /// 通过返回 nil，失败返回错误描述文本。
    ///
    /// ⚠️ 并发约定：本方法是【同步重活】——`hash` 分支会用 `FileHandle` 循环读取 1MB 块做整文件
    /// 哈希（MD5/SHA1/SHA256），在哪个线程调用就在哪个线程阻塞，可能耗时数百 ms～数秒。
    /// **禁止在主线程调用**；现有唯一主调用点 `SLLaunchBridge.swift:146` 已在后台线程，安全。
    /// 本方法标 `nonisolated` 仅表示「无 actor 隔离状态」，不代表「轻量」——调用方务必自行置于后台。
    public nonisolated func check(_ path: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return "文件不存在：\(path.lastPathComponent)"
        }
        if actualSize >= 0, actualSize != size {
            return "文件大小应为 \(actualSize) B，实际为 \(size) B"
        }
        if minSize >= 0, minSize > size {
            return "文件大小应大于 \(minSize) B，实际为 \(size) B"
        }
        if let hash, !hash.isEmpty {
            let actual: String
            // 按摘要文本长度分派算法：长度 < 35 → MD5（32 位），== 64 → SHA256，
            // 其余一律 SHA1（40 位）。
            // ⚠️ 这是**靠长度猜算法**，边界很脆：任何 35~63 位、且不是 64 的摘要
            // （例如 SHA-224 的 56 位）都会掉进 SHA1 分支并必然失败，
            // 报出来的是「哈希校验失败」，看起来像文件坏了，实际是算法猜错了。
            if hash.count < 35 {
                actual = Self.md5OfFile(path) ?? ""
            } else if hash.count == 64 {
                actual = Self.sha256OfFile(path) ?? ""
            } else {
                actual = Self.sha1OfFile(path) ?? ""
            }
            guard actual.lowercased() == hash.lowercased() else {
                return "文件哈希校验失败：期望 \(hash)，实际 \(actual)"
            }
        }
        if isJson {
            guard let data = try? Data(contentsOf: path), !data.isEmpty else {
                return "读取到的文件为空"
            }
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return "不是有效的 json 文件"
            }
        }
        return nil
    }

    /// 流式整文件摘要（按 1MB 块读，内存占用与文件大小无关）。
    /// 做成泛型是为了让三种算法共享同一段循环 —— 只需换一个 hasher 实例。
    ///
    /// ⚠️ 读取中途出错时 `try?` 会让循环**静默结束**，返回的是「已读部分的摘要」，
    /// 于是 I/O 错误最终会以「哈希校验失败」的形式报给用户，而不是「文件读不了」。
    /// 文件打不开时返回 nil，调用方在 `check` 里用空串兜底 —— 同样表现为不匹配。
    private nonisolated static func hashOfFile<H: HashFunction>(_ path: URL, _ hasher: H) -> String? {
        var hasher = hasher
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // 下面三个入口只是把具体的算法实例喂给 hashOfFile，算法选择由调用方的 hash 长度决定。
    // MD5 / SHA1 在 CryptoKit 里归入 Insecure（已不安全）—— 这里用它们只为对齐
    // Mojang 官方清单给出的校验值，不承担任何安全职责。
    private nonisolated static func md5OfFile(_ path: URL) -> String? {
        hashOfFile(path, Insecure.MD5())
    }

    private nonisolated static func sha256OfFile(_ path: URL) -> String? {
        hashOfFile(path, SHA256())
    }

    private nonisolated static func sha1OfFile(_ path: URL) -> String? {
        hashOfFile(path, Insecure.SHA1())
    }
}
