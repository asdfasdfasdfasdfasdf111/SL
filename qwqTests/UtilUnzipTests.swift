//
//  UtilUnzipTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Utils/Util.swift` 的 `unzip(archiveURL:destination:replace:)`
//  的**路径穿越（ZIP Slip）防护**语义。
//
//  为什么值得测：`Util.unzip` 是全库解压落盘的共用入口（natives / 资源包 / 模组安装等
//  都走它），其防护逻辑（`qwq/SLCore/Utils/Util.swift` 的 unzip 内）拒绝两类危险条目：
//    - 绝对路径（归一化后以 `/` 开头）——会写到目标目录之外
//    - 含 `..` 的路径（归一化后仍含 `..` 段）——会穿越到上级目录
//  该防护是 2026-10 前的安全修复（CHANGELOG「修复解压 ZIP 的路径穿越（ZIP Slip）漏洞」），
//  但此前**没有任何用例钉住它**——本文件把三类危险形态（`..`、绝对路径、反斜杠变体）
//  与两条正常语义（普通条目解压、目录条目自建）一起钉死，防止回归。
//
//  语义注意：防护判定为「跳过危险条目，不计失败」——`unzip` 对只含危险条目的归档
//  仍返回 `true`（被跳过 ≠ 解压失败），但危险内容**绝不落盘**。本文件的断言核心是
//  「不落盘」而非「返回值」，与源码注释（"主动跳过危险条目属安全决策"）一致。
//
//  用例一律 async（宿主 abort 规避，见 `qwqTests/TESTING.md`）。
//
//  注释引用约定：一律写「文件 + 符号/场景」，不写行号。
//

import XCTest
import ZIPFoundation
@testable import qwq

final class UtilUnzipTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-util-unzip-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// 现造一个 zip：`entries` 为「条目路径 → 内容」。用默认 `.none` 压缩，避开压缩路径。
    private func makeArchive(_ entries: [String: String]) throws -> URL {
        let url = workDir.appendingPathComponent("src-\(UUID().uuidString).zip")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, content) in entries {
            let src = workDir.appendingPathComponent("src-\(UUID().uuidString)")
            try Data(content.utf8).write(to: src)
            try archive.addEntry(with: name, fileURL: src)
        }
        return url
    }

    /// 目标目录：解压前后的内容快照都用它。
    private func makeDestination() throws -> URL {
        let dest = workDir.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        return dest
    }

    // MARK: - 危险条目：拒绝落盘

    /// 含 `..` 的条目（`../evil.txt`）被跳过：目标目录之外不产生文件，
    /// 目标目录内也不产生该条目。
    func testDotDotTraversalEntryIsNotWrittenOutsideDestination() async throws {
        let archiveURL = try makeArchive(["../evil.txt": "pwn"])
        let dest = try makeDestination()
        let destParent = dest.deletingLastPathComponent()

        let result = Util.unzip(archiveURL: archiveURL, destination: dest)

        XCTAssertTrue(result, "危险条目被跳过属安全决策，不算解压失败（源码语义）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destParent.appendingPathComponent("evil.txt").path),
                       "`..` 条目不得写到目标目录之外")
        // 目标目录本身也不应残留该条目名
        let createdFiles = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        XCTAssertTrue(createdFiles.isEmpty, "危险条目不得落入目标目录")
    }

    /// 嵌套 `..`（`sub/../../evil.txt`）归一化后仍含 `..` 段，同样拒绝。
    func testNestedDotDotEntryIsRejected() async throws {
        let archiveURL = try makeArchive(["sub/../../evil.txt": "pwn"])
        let dest = try makeDestination()
        let destParent = dest.deletingLastPathComponent()

        _ = Util.unzip(archiveURL: archiveURL, destination: dest)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destParent.appendingPathComponent("evil.txt").path))
        let createdFiles = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        XCTAssertTrue(createdFiles.isEmpty)
    }

    /// 绝对路径条目（`/tmp/evil.txt`）被拒绝：不允许写入目标目录之外。
    func testAbsolutePathEntryIsRejected() async throws {
        let archiveURL = try makeArchive(["/tmp/sl-unzip-evil-\(UUID().uuidString).txt": "pwn"])
        let dest = try makeDestination()

        _ = Util.unzip(archiveURL: archiveURL, destination: dest)

        let createdFiles = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        XCTAssertTrue(createdFiles.isEmpty, "绝对路径条目不得落入目标目录")
    }

    /// 反斜杠变体（`..\\evil.txt`）：源码先把 `\` 归一化为 `/` 再判定，同样拒绝。
    func testBackslashDotDotEntryIsRejected() async throws {
        let archiveURL = try makeArchive(["..\\evil.txt": "pwn"])
        let dest = try makeDestination()
        let destParent = dest.deletingLastPathComponent()

        _ = Util.unzip(archiveURL: archiveURL, destination: dest)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destParent.appendingPathComponent("evil.txt").path))
        let createdFiles = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        XCTAssertTrue(createdFiles.isEmpty)
    }

    // MARK: - 正常语义：不误伤

    /// 普通条目正常解压到目标目录（防护不得误伤合法路径）。
    func testNormalEntryIsExtractedToDestination() async throws {
        let archiveURL = try makeArchive(["a/b.txt": "hello"])
        let dest = try makeDestination()

        let result = Util.unzip(archiveURL: archiveURL, destination: dest)

        XCTAssertTrue(result)
        let written = try String(contentsOf: dest.appendingPathComponent("a/b.txt"), encoding: .utf8)
        XCTAssertEqual(written, "hello")
    }

    /// 归档中混入危险条目 + 正常条目：危险被跳过、正常照常解压。
    func testMixedArchiveSkipsDangerousAndExtractsSafe() async throws {
        let archiveURL = try makeArchive(["../evil.txt": "pwn", "good.txt": "ok"])
        let dest = try makeDestination()

        let result = Util.unzip(archiveURL: archiveURL, destination: dest)

        XCTAssertTrue(result)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("good.txt"), encoding: .utf8), "ok")
        let createdFiles = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        XCTAssertEqual(createdFiles, ["good.txt"], "只有安全条目落入目标目录")
    }

    /// 目录条目语义：目录条目被解出时自建目录，且**不误删**刚解出的子树
    ///（`replace = true` 下目录条目命中 `fileExists` 时不应走删除分支）。
    func testDirectoryEntryCreatesDirectoryAndKeepsChildren() async throws {
        let archiveURL = try makeArchive(["dir/nested.txt": "child"])
        let dest = try makeDestination()

        let result = Util.unzip(archiveURL: archiveURL, destination: dest)

        XCTAssertTrue(result)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("dir/nested.txt"), encoding: .utf8), "child",
                       "目录条目与文件条目共存时，子文件不得被目录条目的 replace 删除")
    }
}
