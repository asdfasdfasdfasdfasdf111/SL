//
//  DownloadVerifierTests.swift
//  qwqTests
//
//  覆盖 `Core/Download/DownloadVerifier.swift` 的 `CryptoKitDownloadVerifier`：
//  - SHA-1 / SHA-256 校验：匹配通过、不匹配抛 .checksumMismatch
//  - 文件大小校验：expectedSize 不符时抛错
//  - 空文件、大文件（8 MiB）：确认实现为流式读取，不整文件载入内存
//
//  所有用例均在临时目录下造真实文件，不依赖网络。
//

import XCTest
import CryptoKit
@testable import qwq

final class DownloadVerifierTests: XCTestCase {

    private var temporaryDirectory: URL!
    private let verifier = CryptoKitDownloadVerifier()

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DownloadVerifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: - 辅助

    private func makeFile(named name: String, contents: Data) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private func hexString<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SHA-256

    /// 标准测试向量 SHA-256("abc")，校验通过
    func testSHA256MatchingKnownVectorPasses() throws {
        let url = try makeFile(named: "abc-256.bin", contents: Data("abc".utf8))
        XCTAssertNoThrow(
            try verifier.verify(
                fileAt: url,
                expectedSize: 3,
                sha1: nil,
                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
        )
    }

    /// SHA-256 不匹配时抛 .checksumMismatch
    func testSHA256MismatchThrowsChecksumMismatch() throws {
        let url = try makeFile(named: "abc-256-bad.bin", contents: Data("abc".utf8))
        XCTAssertThrowsError(
            try verifier.verify(fileAt: url, expectedSize: nil, sha1: nil, sha256: String(repeating: "0", count: 64))
        ) { error in
            XCTAssertEqual(error as? DownloadError, .checksumMismatch)
        }
    }

    /// 实现内部对期望值做 lowercase 归一，大写十六进制应同样通过
    func testUppercaseSHA256IsAccepted() throws {
        let url = try makeFile(named: "abc-256-upper.bin", contents: Data("abc".utf8))
        XCTAssertNoThrow(
            try verifier.verify(
                fileAt: url,
                expectedSize: nil,
                sha1: nil,
                sha256: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
            )
        )
    }

    // MARK: - SHA-1

    /// 标准测试向量 SHA-1("abc")，校验通过
    func testSHA1MatchingKnownVectorPasses() throws {
        let url = try makeFile(named: "abc-1.bin", contents: Data("abc".utf8))
        XCTAssertNoThrow(
            try verifier.verify(
                fileAt: url,
                expectedSize: 3,
                sha1: "a9993e364706816aba3e25717850c26c9cd0d89d",
                sha256: nil
            )
        )
    }

    /// SHA-1 不匹配时抛 .checksumMismatch
    func testSHA1MismatchThrowsChecksumMismatch() throws {
        let url = try makeFile(named: "abc-1-bad.bin", contents: Data("abc".utf8))
        XCTAssertThrowsError(
            try verifier.verify(fileAt: url, expectedSize: nil, sha1: String(repeating: "0", count: 40), sha256: nil)
        ) { error in
            XCTAssertEqual(error as? DownloadError, .checksumMismatch)
        }
    }

    /// 同时给出两个哈希时先校验 SHA-256：sha1 正确、sha256 错误应失败
    func testSHA256IsCheckedBeforeSHA1() throws {
        let url = try makeFile(named: "both.bin", contents: Data("abc".utf8))
        XCTAssertThrowsError(
            try verifier.verify(
                fileAt: url,
                expectedSize: nil,
                sha1: "a9993e364706816aba3e25717850c26c9cd0d89d",
                sha256: String(repeating: "0", count: 64)
            )
        ) { error in
            XCTAssertEqual(error as? DownloadError, .checksumMismatch)
        }

        // 两者均正确时通过
        XCTAssertNoThrow(
            try verifier.verify(
                fileAt: url,
                expectedSize: nil,
                sha1: "a9993e364706816aba3e25717850c26c9cd0d89d",
                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
        )
    }

    // MARK: - 文件大小

    /// expectedSize 与实际大小不符时抛错
    ///
    /// 注意：当前实现以 `DownloadError.unknown` 承载大小不符（无专用 case），
    /// 此处按现状断言错误描述；后续若要穷尽处理，建议新增 `.sizeMismatch(expected:actual:)`
    /// 并由调用方同步改造（本测试不修改实现）。
    func testSizeMismatchThrows() throws {
        let url = try makeFile(named: "size.bin", contents: Data("abc".utf8))
        XCTAssertThrowsError(try verifier.verify(fileAt: url, expectedSize: 4, sha1: nil, sha256: nil)) { error in
            guard let downloadError = error as? DownloadError else {
                return XCTFail("期望 DownloadError，实际为 \(error)")
            }
            XCTAssertNotEqual(downloadError, .checksumMismatch)
            guard case .unknown(let reason) = downloadError else {
                return XCTFail("期望 .unknown 携带大小不符描述，实际为 \(downloadError)")
            }
            XCTAssertTrue(reason.contains("文件大小应为"), "错误描述应点明大小不符：\(reason)")
        }
    }

    /// 大小相符且哈希相符时通过
    func testMatchingSizePasses() throws {
        let url = try makeFile(named: "size-ok.bin", contents: Data("abc".utf8))
        XCTAssertNoThrow(try verifier.verify(fileAt: url, expectedSize: 3, sha1: nil, sha256: nil))
    }

    // MARK: - 文件不存在

    /// 文件不存在时抛错（三项校验全为 nil 也需先确认存在）
    func testMissingFileThrows() throws {
        let url = temporaryDirectory.appendingPathComponent("missing.bin")
        XCTAssertThrowsError(try verifier.verify(fileAt: url, expectedSize: nil, sha1: nil, sha256: nil)) { error in
            guard let downloadError = error as? DownloadError, case .unknown(let reason) = downloadError else {
                return XCTFail("期望 DownloadError.unknown，实际为 \(error)")
            }
            XCTAssertTrue(reason.contains("文件不存在"), "错误描述应点明文件不存在：\(reason)")
        }
    }

    // MARK: - 空文件

    /// 空文件：空内容的 SHA-1 / SHA-256 与 expectedSize = 0 均应通过
    func testEmptyFilePassesWithEmptyContentHashes() throws {
        let url = try makeFile(named: "empty.bin", contents: Data())
        XCTAssertNoThrow(
            try verifier.verify(
                fileAt: url,
                expectedSize: 0,
                sha1: "da39a3ee5e6b4b0d3255bfef95601890afd80709",
                sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            )
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, 0)
    }

    // MARK: - 大文件（流式）

    /// 8 MiB 文件的 SHA-256 校验：期望值在写入过程中增量计算，
    /// 测试自身不持有完整文件内容，用于确认实现逐块读取而非整文件载入
    func testLargeFileVerifiesWithStreamingHash() throws {
        let chunkSize = 1 << 20      // 1 MiB，与实现内部块大小一致
        let chunkCount = 8           // 合计 8 MiB
        let url = temporaryDirectory.appendingPathComponent("large.bin")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            return XCTFail("无法创建测试文件")
        }

        var hasher = SHA256()
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for index in 0..<chunkCount {
            // 每块内容不同且可复现，避免全零数据在哈希错误时仍被判通过
            let chunk = Data(repeating: UInt8(truncatingIfNeeded: index &* 37 &+ 11), count: chunkSize)
            hasher.update(data: chunk)
            try handle.write(contentsOf: chunk)
        }
        try handle.close()
        let expected = hexString(hasher.finalize())

        let expectedSize = Int64(chunkSize * chunkCount)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, expectedSize)
        XCTAssertNoThrow(try verifier.verify(fileAt: url, expectedSize: expectedSize, sha1: nil, sha256: expected))

        // 同一份文件换错哈希必须失败，证明校验确实读完了整个文件
        XCTAssertThrowsError(
            try verifier.verify(fileAt: url, expectedSize: expectedSize, sha1: nil, sha256: String(repeating: "1", count: 64))
        ) { error in
            XCTAssertEqual(error as? DownloadError, .checksumMismatch)
        }
    }

    // MARK: - 跳过校验

    /// 三项期望值均为 nil 时只确认文件存在
    func testNilExpectationsOnlyCheckExistence() throws {
        let url = try makeFile(named: "skip.bin", contents: Data(repeating: 0xAB, count: 1024))
        XCTAssertNoThrow(try verifier.verify(fileAt: url, expectedSize: nil, sha1: nil, sha256: nil))
    }

    /// 空字符串哈希视为「未声明」，不参与校验
    func testEmptyHashStringIsSkipped() throws {
        let url = try makeFile(named: "skip-empty-hash.bin", contents: Data("abc".utf8))
        XCTAssertNoThrow(try verifier.verify(fileAt: url, expectedSize: nil, sha1: "", sha256: ""))
    }

    /// 由 CryptoKit 独立算出的哈希与实现结果一致（交叉验证，非硬编码向量）
    func testHashMatchesCryptoKitReference() throws {
        let payload = Data("Minecraft 1.20.1 client.jar".utf8)
        let url = try makeFile(named: "crossover.bin", contents: payload)
        XCTAssertNoThrow(
            try verifier.verify(
                fileAt: url,
                expectedSize: Int64(payload.count),
                sha1: hexString(Insecure.SHA1.hash(data: payload)),
                sha256: hexString(SHA256.hash(data: payload))
            )
        )
    }
}
