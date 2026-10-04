//
//  ModLoaderDetectorTests.swift
//  qwqTests
//
//  钉住 `ModBrowser/ModLoaderDetector.swift` 的判据语义，防止「unzip 子进程 → ZIPFoundation
//  内存读取」重构引入回归。文件头注释明确的判定顺序**不可调换**（Quilt 先于 Fabric、NeoForge
//  先于 Forge），本文件特意用「同时含多个标志文件」的 jar 验证顺序不被破坏。
//
//  失败路径（非 zip / 空 jar）必须返回 `.unknown`，与旧 unzip 子进程失败语义一致。
//

import XCTest
@testable import qwq
import ZIPFoundation

final class ModLoaderDetectorTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-modloader-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// 现造一个 jar；`entries` 为「条目路径 → 内容」。
    private func makeJar(_ entries: [String: String]) throws -> URL {
        let url = workDir.appendingPathComponent("mod-\(UUID().uuidString).jar")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, content) in entries {
            let src = workDir.appendingPathComponent("src-\(UUID().uuidString)")
            try Data(content.utf8).write(to: src)
            try archive.addEntry(with: name, fileURL: src)
        }
        return url
    }

    // MARK: - 单标志文件判定

    func testFabricJarDetected() async throws {
        let jar = try makeJar(["fabric.mod.json": "{\"schemaVersion\":1}"])
        XCTAssertEqual(ModLoaderDetector.detect(from: jar), .fabric)
    }

    func testForgeJarDetected() async throws {
        let jar = try makeJar(["META-INF/mods.toml": "modLoader=\"javafml\""])
        XCTAssertEqual(ModLoaderDetector.detect(from: jar), .forge)
    }

    func testNeoForgeJarDetected() async throws {
        let jar = try makeJar(["META-INF/neoforge.mods.toml": "modLoader=\"javafml\""])
        XCTAssertEqual(ModLoaderDetector.detect(from: jar), .neoforge)
    }

    func testRiftJarDetected() async throws {
        let jar = try makeJar(["mod.json": "{\"id\":\"riftmod\"}"])
        XCTAssertEqual(ModLoaderDetector.detect(from: jar), .rift)
    }

    // MARK: - 判定顺序（文件头注释点名的不可调换项）

    /// Quilt 模组通常同时包含 `quilt.mod.json` 与 `fabric.mod.json`（兼容 Fabric 生态）。
    /// 无论条目顺序如何，都必须判成 Quilt —— 先判 Fabric 会把 Quilt 误判成 Fabric。
    func testQuiltTakesPriorityOverFabricRegardlessOfEntryOrder() async throws {
        let jar = try makeJar([
            "fabric.mod.json": "{\"schemaVersion\":1}",
            "quilt.mod.json": "{\"schemaVersion\":1,\"quilt_loader\":{\"group\":\"x\"}}",
        ])
        XCTAssertEqual(ModLoaderDetector.detect(from: jar), .quilt)

        // 反向条目顺序（quilt 先写、fabric 后写）—— 判据是「集合包含」，与顺序无关
        let jar2 = try makeJar([
            "quilt.mod.json": "{\"schemaVersion\":1,\"quilt_loader\":{\"group\":\"x\"}}",
            "fabric.mod.json": "{\"schemaVersion\":1}",
        ])
        XCTAssertEqual(ModLoaderDetector.detect(from: jar2), .quilt)
    }

    /// NeoForge 包可能同时带上旧式 `mods.toml` 作为兼容层 —— 必须判 NeoForge。
    func testNeoForgeTakesPriorityOverForge() async throws {
        let jar = try makeJar([
            "META-INF/mods.toml": "modLoader=\"javafml\"",
            "META-INF/neoforge.mods.toml": "modLoader=\"javafml\"",
        ])
        XCTAssertEqual(ModLoaderDetector.detect(from: jar), .neoforge)
    }

    // MARK: - 失败路径（与旧 unzip 子进程失败语义一致：一律 .unknown）

    func testNonZipFileReturnsUnknown() async throws {
        let notAJar = workDir.appendingPathComponent("not-a-jar.jar")
        try Data("这不是 zip".utf8).write(to: notAJar)
        XCTAssertEqual(ModLoaderDetector.detect(from: notAJar), .unknown)
    }

    func testMissingFileReturnsUnknown() async throws {
        let missing = workDir.appendingPathComponent("does-not-exist.jar")
        XCTAssertEqual(ModLoaderDetector.detect(from: missing), .unknown)
    }

    func testEmptyJarReturnsUnknown() async throws {
        let jar = try makeJar([:])
        XCTAssertEqual(ModLoaderDetector.detect(from: jar), .unknown)
    }

    // MARK: - ArchiveUtil.listEntries（新增 API 的失败语义）

    func testListEntriesListsCentralDirectory() async throws {
        let jar = try makeJar([
            "fabric.mod.json": "{}",
            "assets/x.txt": "x",
        ])
        let entries = ArchiveUtil.listEntries(url: jar)
        XCTAssertNotNil(entries)
        XCTAssertTrue(entries!.contains("fabric.mod.json"))
        XCTAssertTrue(entries!.contains("assets/x.txt"))
    }

    func testListEntriesReturnsNilForNonZip() async throws {
        let notAZip = workDir.appendingPathComponent("bad.jar")
        try Data("not a zip".utf8).write(to: notAZip)
        XCTAssertNil(ArchiveUtil.listEntries(url: notAZip))
    }
}