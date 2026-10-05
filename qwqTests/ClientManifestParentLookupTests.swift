//
//  ClientManifestParentLookupTests.swift
//  qwqTests
//
//  覆盖 `ClientManifest.parse` 里**父清单（inheritsFrom）查找位置**的判定。
//
//  回归背景（2026-10-05 实测）：真实游戏目录里存在「自包含实例」布局 ——
//  父清单被放在实例自己的 `.parent/<父版本 id>.json`（该实例同时带着别的启动器的
//  `.clconfig.json` / `.clmetadata.json`），而 `versions/<父版本 id>/` 并不存在。
//  此前只认标准位置，于是这类实例解析一律失败：`MinecraftInstance.setup()` 返回 false，
//  界面报「无法创建实例: <版本>」，可磁盘上父清单一直都在、内容完整。
//
//  钉住三条性质：
//  1. 标准位置缺失时，回落到实例自带的 `.parent/`；
//  2. 两处都存在时，**标准位置优先**（安装流程的产出是权威，不被旁路布局顶掉）；
//  3. 两处都没有 → 返回 nil（不抛错，保持既有「解析失败即没有实例」的语义）。
//

import XCTest
@testable import qwq

final class ClientManifestParentLookupTests: XCTestCase {

    /// 造一个临时游戏目录，返回 (根目录, 实例清单 URL)
    private func makeGameRoot(
        childJSON: String,
        standardParent: String?,
        bundledParent: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (root: URL, childURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-parent-lookup-\(UUID().uuidString)", isDirectory: true)
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        let childDir = versions.appendingPathComponent("1.20.1-Forge", isDirectory: true)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)

        let childURL = childDir.appendingPathComponent("1.20.1-Forge.json")
        try Data(childJSON.utf8).write(to: childURL)

        if let standardParent {
            let dir = versions.appendingPathComponent("1.20.1", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(standardParent.utf8).write(to: dir.appendingPathComponent("1.20.1.json"))
        }
        if let bundledParent {
            let dir = childDir.appendingPathComponent(".parent", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(bundledParent.utf8).write(to: dir.appendingPathComponent("1.20.1.json"))
        }
        return (root, childURL)
    }

    private func child() -> String {
        #"{"id":"1.20.1-Forge","inheritsFrom":"1.20.1","mainClass":"forge.Main","arguments":{"game":["--child"]}}"#
    }

    private func parent(marker: String) -> String {
        #"{"id":"1.20.1","mainClass":"net.minecraft.client.main.Main","arguments":{"game":["\#(marker)"]}}"#
    }

    private func parse(root: URL, childURL: URL) throws -> ClientManifest? {
        let dir = MinecraftDirectory(rootURL: root, name: "临时目录")
        return try ClientManifest.parse(url: childURL, minecraftDirectory: dir)
    }

    /// 标准位置缺失、父清单只在实例自带的 `.parent/` 里 → 仍然要能解析出来（本次修复点）。
    func testBundledDotParentIsUsedWhenStandardLocationMissing() async throws {
        let (root, childURL) = try makeGameRoot(
            childJSON: child(),
            standardParent: nil,
            bundledParent: parent(marker: "--bundled-parent")
        )
        let manifest = try XCTUnwrap(try parse(root: root, childURL: childURL),
                                     "父清单在 .parent/ 里时必须能解析出实例")
        let args = manifest.getArguments().getAllowedGameArguments()
        XCTAssertTrue(args.contains("--bundled-parent"), "父版本的参数应被合并进来：\(args)")
        XCTAssertTrue(args.contains("--child"), "子版本的参数应被保留：\(args)")
        XCTAssertEqual(manifest.mainClass, "forge.Main", "mainClass 取子版本（Forge）的")
    }

    /// 两处都存在 → 标准位置优先（防止旁路布局顶掉安装流程的产出）。
    func testStandardLocationWinsOverBundledDotParent() async throws {
        let (root, childURL) = try makeGameRoot(
            childJSON: child(),
            standardParent: parent(marker: "--standard-parent"),
            bundledParent: parent(marker: "--bundled-parent")
        )
        let manifest = try XCTUnwrap(try parse(root: root, childURL: childURL))
        let args = manifest.getArguments().getAllowedGameArguments()
        XCTAssertTrue(args.contains("--standard-parent"), "应使用 versions/ 下的父清单：\(args)")
        XCTAssertFalse(args.contains("--bundled-parent"), "不该用 .parent/ 里的那份：\(args)")
    }

    /// 两处都没有 → 返回 nil（既有语义：解析不出实例，而不是抛错）。
    func testMissingParentEverywhereReturnsNil() async throws {
        let (root, childURL) = try makeGameRoot(
            childJSON: child(),
            standardParent: nil,
            bundledParent: nil
        )
        let manifest = try parse(root: root, childURL: childURL)
        XCTAssertNil(manifest, "父清单两处都不存在时应判定为解析失败")
    }
}
