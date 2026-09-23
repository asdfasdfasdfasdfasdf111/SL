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

public struct FileChecker {
    public var actualSize: Int64 = -1
    public var minSize: Int64 = -1
    public var hash: String? = nil
    public var canUseExistsFile: Bool = true
    public var isJson: Bool = false

    public init(actualSize: Int64 = -1, minSize: Int64 = -1, hash: String? = nil, canUseExistsFile: Bool = true, isJson: Bool = false) {
        self.actualSize = actualSize
        self.minSize = minSize
        self.hash = hash
        self.canUseExistsFile = canUseExistsFile
        self.isJson = isJson
    }

    /// 检查文件。通过返回 nil，失败返回错误描述文本。
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

    private nonisolated static func hashOfFile<H: HashFunction>(_ path: URL, _ hasher: H) -> String? {
        var hasher = hasher
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

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
