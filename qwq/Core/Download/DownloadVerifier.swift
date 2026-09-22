//
//  DownloadVerifier.swift
//  SL启动器
//
//  下载结果校验。旧实现是 `FileChecker.check` 返回可选错误字符串，
//  成功/失败靠「返回 nil」表达；这里改为 throws，调用方无法忽略校验结果。
//

import Foundation
import CryptoKit

/// 校验已落盘文件是否符合预期。
///
/// 三个参数均为可选，传 nil 表示跳过该项校验；三项全为 nil 时只确认文件存在。
public protocol DownloadVerifier: Sendable {
    func verify(fileAt url: URL, expectedSize: Int64?, sha1: String?, sha256: String?) throws
}

/// 基于 CryptoKit 的流式校验实现。
///
/// 逐块读取（1 MiB）而非整文件载入，避免大文件（原版 jar、资源包）把内存打满。
public struct CryptoKitDownloadVerifier: DownloadVerifier {
    /// 单次读取块大小。
    private let chunkSize = 1 << 20

    public init() {}

    public func verify(fileAt url: URL, expectedSize: Int64?, sha1: String?, sha256: String?) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DownloadError.unknown("文件不存在：\(url.lastPathComponent)")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw DownloadError.unknown("无法读取文件大小：\(url.lastPathComponent)")
        }

        if let expectedSize, expectedSize >= 0, size != expectedSize {
            throw DownloadError.unknown("文件大小应为 \(expectedSize) B，实际为 \(size) B")
        }

        if let sha256, !sha256.isEmpty {
            let actual = try hashOfFile(at: url, using: SHA256())
            guard actual == sha256.lowercased() else {
                throw DownloadError.checksumMismatch
            }
        }

        if let sha1, !sha1.isEmpty {
            let actual = try hashOfFile(at: url, using: Insecure.SHA1())
            guard actual == sha1.lowercased() else {
                throw DownloadError.checksumMismatch
            }
        }
    }

    private func hashOfFile<H: HashFunction>(at url: URL, using hasher: H) throws -> String {
        var hasher = hasher
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
