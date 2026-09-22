//
//  DefaultDownloadVerifier.swift
//  SL启动器
//
//  适配器：下载结果校验。
//  - 协议方法复用已有的 `CryptoKitDownloadVerifier`（流式 SHA1/SHA256 + 大小）；
//  - 另提供与旧 `FileChecker.check` 完全等价的入口，供「行为不得变化」的迁移阶段使用：
//    旧实现按哈希长度自动判定算法（<35 → MD5，==64 → SHA256，其余 → SHA1）、大小写不敏感比较、
//    支持 minSize 与 isJson，这些语义无法全部塞进协议签名（只有 size/sha1/sha256 三个入参）。
//

import Foundation

/// 默认校验器：CryptoKit 实现 + FileChecker 等价入口。
public struct DefaultDownloadVerifier: DownloadVerifier {

    private let crypto = CryptoKitDownloadVerifier()

    public init() {}

    // MARK: - DownloadVerifier

    public func verify(fileAt url: URL, expectedSize: Int64?, sha1: String?, sha256: String?) throws {
        try crypto.verify(fileAt: url, expectedSize: expectedSize, sha1: sha1, sha256: sha256)
    }

    // MARK: - 与 FileChecker 行为一致的入口

    /// 完全委托旧 `FileChecker.check`，保证「算法自动判定 / 大小写 / 错误类型」逐字一致。
    /// `FileChecker` 的失败返回值是描述文本，这里按前缀映射为 `DownloadError`：
    /// 哈希不符 → `checksumMismatch`，其余（大小、不存在、JSON）→ `unknown(原因)`。
    public func verify(fileAt url: URL, checker: FileChecker) throws {
        guard let failure = checker.check(url) else { return }
        if failure.hasPrefix("文件哈希校验失败") {
            throw DownloadError.checksumMismatch
        }
        throw DownloadError.unknown(failure)
    }

    // MARK: - DownloadRequest → FileChecker

    /// 把请求里的期望值翻译成旧引擎的 `FileChecker`。
    ///
    /// - 哈希优先级：sha256 → sha1；旧引擎按字符串长度自行判定算法，两种长度不会互相误判，
    ///   因此这里只需挑出非空的一个（MD5 在 `DownloadRequest` 中无对应字段，见 MIGRATION.md）；
    /// - `expectedSize` 映射为 `actualSize`（必须相等）；旧 `minSize` / `isJson` 在请求中无对应字段；
    /// - 无任何期望值时仍然返回 check，而不是 nil：`FileChecker(actualSize: -1, hash: nil).check`
    ///   对已存在文件返回 nil，与旧链路「无校验要求时存在即跳过」的语义一致。
    public static func checker(for request: DownloadRequest) -> FileChecker {
        var hash: String?
        if let sha256 = request.sha256, !sha256.isEmpty {
            hash = sha256
        } else if let sha1 = request.sha1, !sha1.isEmpty {
            hash = sha1
        }
        return FileChecker(actualSize: request.expectedSize ?? -1, hash: hash)
    }
}
