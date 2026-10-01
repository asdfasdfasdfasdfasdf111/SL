//
//  ArchiveUtilTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Utils/ArchiveUtil.swift`（zip / jar 只读取值工具）。
//
//  **为什么值得测**：它在三个方法里用了**三种不同的失败表达**，而源码逐条写明了各自
//  的语义与代价：「归档打不开」与「没有这个条目」这两件不同的事，
//  在 `hasEntry` / `getEntry` 里被**合并成同一个返回值**：
//
//  | 方法 | 归档打不开 | 条目不存在 | 能否区分 |
//  | --- | --- | --- | --- |
//  | `hasEntry` | `false` + 打日志 | `false` | ❌ 不能 |
//  | `getEntry` | `nil`，**不打日志** | `nil` | ❌ 不能 |
//  | `getEntryOrThrow` | **抛出**底层错误 | 抛 `MyLocalizedError("项 X 不存在")` | ✅ 能 |
//
//  把这三种表达钉住，是为了让调用方不会误以为 `hasEntry == false` 就等于「条目缺失」——
//  源码原话：「调用方无法区分『没有这个条目』与『这个归档根本读不了』」。
//
//  夹具用 ZIPFoundation 的写接口现造真 zip（`compressionMethod` 取默认 `.none`，
//  避开压缩路径，让 fixture 只依赖「能写能读」这件事本身）。
//

import XCTest
import ZIPFoundation
@testable import qwq

final class ArchiveUtilTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-archive-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// 现造一个 zip；`entries` 为「条目路径 → 内容」
    private func makeArchive(_ entries: [String: String]) throws -> URL {
        let url = workDir.appendingPathComponent("test-\(UUID().uuidString).zip")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, content) in entries {
            let src = workDir.appendingPathComponent("src-\(UUID().uuidString)")
            try Data(content.utf8).write(to: src)
            try archive.addEntry(with: name, fileURL: src)
        }
        return url
    }

    // MARK: - hasEntry

    func testHasEntryFindsExistingEntry() async throws {
        let url = try makeArchive(["META-INF/MANIFEST.MF": "Manifest-Version: 1.0"])
        XCTAssertTrue(ArchiveUtil.hasEntry(url: url, name: "META-INF/MANIFEST.MF"))
    }

    func testHasEntryReturnsFalseForMissingEntry() async throws {
        let url = try makeArchive(["a.txt": "a"])
        XCTAssertFalse(ArchiveUtil.hasEntry(url: url, name: "b.txt"))
    }

    /// ⚠️ **注释点名的合并语义**：归档**根本打不开**时 `hasEntry` 同样返回 `false`，
    /// 与「条目不存在」不可区分（日志里才会写「无法读取归档」）。
    func testHasEntryReturnsFalseForUnopenableArchive() async {
        let missing = workDir.appendingPathComponent("does-not-exist.zip")
        XCTAssertFalse(ArchiveUtil.hasEntry(url: missing, name: "a.txt"))

        let notAZip = workDir.appendingPathComponent("not-a-zip.zip")
        try? Data("这不是 zip".utf8).write(to: notAZip)
        XCTAssertFalse(ArchiveUtil.hasEntry(url: notAZip, name: "a.txt"))
    }

    /// 已打开归档的重载版本（批量查询用，避免重复解析中央目录）
    func testHasEntryArchiveOverload() async throws {
        let url = try makeArchive(["a.txt": "a"])
        let archive = try Archive(url: url, accessMode: .read)
        XCTAssertTrue(ArchiveUtil.hasEntry(archive: archive, name: "a.txt"))
        XCTAssertFalse(ArchiveUtil.hasEntry(archive: archive, name: "zzz.txt"))
    }

    // MARK: - getEntryOrThrow

    func testGetEntryOrThrowReturnsContent() async throws {
        let url = try makeArchive(["MANIFEST.MF": "Main-Class: Foo\n"])
        let data = try ArchiveUtil.getEntryOrThrow(url: url, name: "MANIFEST.MF")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Main-Class: Foo\n")
    }

    /// ⚠️ 条目不存在 ⇒ 抛 `MyLocalizedError`，文案是「项 <name> 不存在」
    func testGetEntryOrThrowThrowsForMissingEntry() async throws {
        let url = try makeArchive(["a.txt": "a"])
        XCTAssertThrowsError(try ArchiveUtil.getEntryOrThrow(url: url, name: "missing.txt")) { error in
            XCTAssertTrue(error is MyLocalizedError, "应为 MyLocalizedError，实际 \(type(of: error))")
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "项 missing.txt 不存在")
        }
    }

    /// ⚠️ 归档打不开 ⇒ **底层错误直接上抛**（与「条目不存在」是两种不同错误）
    func testGetEntryOrThrowThrowsForUnopenableArchive() async {
        let url = workDir.appendingPathComponent("absent.zip")
        XCTAssertThrowsError(try ArchiveUtil.getEntryOrThrow(url: url, name: "a.txt"))
    }

    /// 已打开归档的重载版本
    func testGetEntryOrThrowArchiveOverload() async throws {
        let url = try makeArchive(["x/y.txt": "hi"])
        let archive = try Archive(url: url, accessMode: .read)
        let data = try ArchiveUtil.getEntryOrThrow(archive: archive, name: "x/y.txt")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hi")
    }

    // MARK: - getEntry（静默版本）

    func testGetEntryReturnsContent() async throws {
        let url = try makeArchive(["a.txt": "abc"])
        let data = ArchiveUtil.getEntry(url: url, name: "a.txt")
        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "abc")
    }

    /// ⚠️ 条目不存在与归档打不开**都返回 nil**，且都不打日志（注释：「因此它适合
    /// 『有没有都行』的探测，不适合需要区分失败原因的场景」）
    func testGetEntryReturnsNilForBothFailureKinds() async throws {
        let valid = try makeArchive(["a.txt": "a"])
        XCTAssertNil(ArchiveUtil.getEntry(url: valid, name: "missing.txt"), "条目不存在 ⇒ nil")

        let broken = workDir.appendingPathComponent("broken.zip")
        try? Data("not a zip".utf8).write(to: broken)
        XCTAssertNil(ArchiveUtil.getEntry(url: broken, name: "a.txt"), "归档打不开 ⇒ 同样 nil")
    }

    // MARK: - 内容保真

    /// 二进制内容逐字节保真（不是「读出来差不多」）
    func testBinaryContentIsPreservedByteForByte() async throws {
        let bytes: [UInt8] = (0...255).map { UInt8($0) }
        let url = workDir.appendingPathComponent("bin.zip")
        let archive = try Archive(url: url, accessMode: .create)
        let src = workDir.appendingPathComponent("src-bin")
        try Data(bytes).write(to: src)
        try archive.addEntry(with: "blob.bin", fileURL: src)

        let data = try ArchiveUtil.getEntryOrThrow(url: url, name: "blob.bin")
        XCTAssertEqual(Array(data), bytes)
    }

    /// 空条目 ⇒ 空 `Data`（而不是 nil 或抛错）
    func testEmptyEntryYieldsEmptyData() async throws {
        let url = try makeArchive(["empty.txt": ""])
        let data = try ArchiveUtil.getEntryOrThrow(url: url, name: "empty.txt")
        XCTAssertEqual(data.count, 0)
    }

    /// 多个条目各自独立可取，互不串扰
    func testMultipleEntriesAreIndependent() async throws {
        let url = try makeArchive(["a.txt": "AAA", "dir/b.txt": "BBB", "c.txt": "CCC"])
        XCTAssertEqual(String(decoding: try ArchiveUtil.getEntryOrThrow(url: url, name: "a.txt"), as: UTF8.self), "AAA")
        XCTAssertEqual(String(decoding: try ArchiveUtil.getEntryOrThrow(url: url, name: "dir/b.txt"), as: UTF8.self), "BBB")
        XCTAssertEqual(String(decoding: try ArchiveUtil.getEntryOrThrow(url: url, name: "c.txt"), as: UTF8.self), "CCC")
        XCTAssertFalse(ArchiveUtil.hasEntry(url: url, name: "nope.txt"))
    }

    /// 条目名区分大小写（`a.txt` 与 `A.TXT` 是不同条目）
    func testEntryNamesAreCaseSensitive() async throws {
        let url = try makeArchive(["a.txt": "lower"])
        XCTAssertTrue(ArchiveUtil.hasEntry(url: url, name: "a.txt"))
        XCTAssertFalse(ArchiveUtil.hasEntry(url: url, name: "A.TXT"),
                       "zip 条目名区分大小写（本工具不做大小写归一）")
    }
}
