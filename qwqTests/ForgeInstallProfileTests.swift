//
//  ForgeInstallProfileTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/Mod/Loader/Forge/ForgeInstallProfile.swift`
//  （Forge/NeoForge 安装 profile 与其中的 processor）。
//
//  **为什么值得测**：processor 是 Forge 安装的最后一步（跑二进制补丁），
//  它的三个派生字段都有**容易写错的规则**：
//
//  1. `isAvailableOnClient` 的实现是
//     `sides.contains("server") && sides.count == 1 ? false : true`
//     —— 只有**恰好** `["server"]` 才判为「仅服务端、客户端不需执行」；
//     `["server","client"]` 因 `count != 1` 仍判 true。写成
//     `sides.contains("server")` 会把双端通用 processor 误跳过，安装结果不完整。
//  2. `classpath` 是「清单里的类路径逐个转 maven 路径」**再追加 jarPath** ——
//     jar 必须排在**最后**（它同时被 `jarPath` 单独引用）。
//  3. `jarPath` 是 `Util.toPath(mavenCoordinate:)` 的结果，即**已解析的落盘相对路径**，
//     不是 maven 坐标原文。
//

import XCTest
import SwiftyJSON
@testable import qwq

final class ForgeInstallProfileTests: XCTestCase {

    private func profile(_ json: String) throws -> ForgeInstallProfile {
        ForgeInstallProfile(json: try JSON(data: Data(json.utf8)))
    }

    private func profileWithProcessors(_ processorsJSON: String) throws -> ForgeInstallProfile {
        try profile(#"{ "data": {}, "processors": \#(processorsJSON), "libraries": [] }"#)
    }

    // MARK: - data

    /// `data` 只取每项的 **`client`** 子字段（不是整项）
    func testDataReadsClientSubfield() async throws {
        let p = try profile("""
        { "data": { "MC_VERSION": { "client": "1.20.1", "server": "1.20.1" },
                    "BINPATCH": { "client": "/tmp/binpatch", "server": "" } },
          "processors": [], "libraries": [] }
        """)
        XCTAssertEqual(p.data, ["MC_VERSION": "1.20.1", "BINPATCH": "/tmp/binpatch"])
    }

    /// `data` 项缺少 `client` ⇒ 空串（不崩、不臆造）
    func testDataMissingClientBecomesEmptyString() async throws {
        let p = try profile(#"{ "data": { "X": { "server": "s" } }, "processors": [], "libraries": [] }"#)
        XCTAssertEqual(p.data["X"], "")
    }

    /// 完全没有 `data` ⇒ 空字典
    func testMissingDataYieldsEmptyDictionary() async throws {
        let p = try profile(#"{ "processors": [], "libraries": [] }"#)
        XCTAssertTrue(p.data.isEmpty)
    }

    // MARK: - Processor.isAvailableOnClient（本文件的靶心）

    /// 恰好 `["server"]` ⇒ **false**（仅服务端，客户端不执行）
    func testProcessorWithOnlyServerSideIsNotAvailableOnClient() async throws {
        let p = try profileWithProcessors(#"[ { "sides": ["server"], "jar": "g:a:1" } ]"#)
        XCTAssertFalse(p.processors[0].isAvailableOnClient)
    }

    /// ⚠️ `["server","client"]` ⇒ **true**（`count == 1` 不成立）
    /// 若误写成 `sides.contains("server")`，双端通用 processor 会被错误跳过
    func testProcessorWithBothSidesIsAvailableOnClient() async throws {
        let p = try profileWithProcessors(#"[ { "sides": ["server", "client"], "jar": "g:a:1" } ]"#)
        XCTAssertTrue(p.processors[0].isAvailableOnClient,
                      "count != 1 ⇒ 仍判可在客户端执行（不能只看 contains）")
    }

    /// `["client"]` ⇒ true
    func testProcessorWithOnlyClientSideIsAvailableOnClient() async throws {
        let p = try profileWithProcessors(#"[ { "sides": ["client"], "jar": "g:a:1" } ]"#)
        XCTAssertTrue(p.processors[0].isAvailableOnClient)
    }

    /// **没有 `sides` 字段** ⇒ 空数组 ⇒ true（默认在客户端执行）
    func testProcessorWithoutSidesDefaultsToAvailableOnClient() async throws {
        let p = try profileWithProcessors(#"[ { "jar": "g:a:1" } ]"#)
        XCTAssertTrue(p.processors[0].isAvailableOnClient)
    }

    /// `sides` 为空数组 ⇒ true
    func testProcessorWithEmptySidesIsAvailableOnClient() async throws {
        let p = try profileWithProcessors(#"[ { "sides": [], "jar": "g:a:1" } ]"#)
        XCTAssertTrue(p.processors[0].isAvailableOnClient)
    }

    // MARK: - jarPath / classpath

    /// `jarPath` 是**已解析的 maven 路径**，不是坐标原文
    func testJarPathIsResolvedMavenPath() async throws {
        let p = try profileWithProcessors(#"[ { "jar": "net.minecraftforge:forge:1.20.1-47.2.0:universal" } ]"#)
        XCTAssertEqual(p.processors[0].jarPath,
                       "net/minecraftforge/forge/1.20.1-47.2.0/forge-1.20.1-47.2.0-universal.jar")
        XCTAssertFalse(p.processors[0].jarPath.contains(":"), "结果是路径，不应残留 maven 冒号")
    }

    /// `classpath` 逐项转路径，**jarPath 追加在最后**
    func testClasspathAppendsJarPathLast() async throws {
        let p = try profileWithProcessors("""
        [ { "jar": "g:j:1",
            "classpath": ["a:b:1", "c:d:2"] } ]
        """)
        let cp = p.processors[0].classpath
        XCTAssertEqual(cp.count, 3)
        XCTAssertEqual(cp[0], "a/b/1/b-1.jar")
        XCTAssertEqual(cp[1], "c/d/2/d-2.jar")
        XCTAssertEqual(cp[2], p.processors[0].jarPath, "jar 必须排在 classpath 最后")
    }

    /// 没有 `classpath` ⇒ 只有 jarPath 一项
    func testClasspathWithoutListContainsOnlyJarPath() async throws {
        let p = try profileWithProcessors(#"[ { "jar": "g:j:1" } ]"#)
        XCTAssertEqual(p.processors[0].classpath, [p.processors[0].jarPath])
    }

    /// `args` 原样保留（参数里的 `${...}` 占位符由后续替换，这里不做处理）
    func testArgsAreKeptVerbatim() async throws {
        let p = try profileWithProcessors(#"[ { "jar": "g:j:1", "args": ["--in", "${SIDE}", "--out", "${BINPATCH}"] } ]"#)
        XCTAssertEqual(p.processors[0].args, ["--in", "${SIDE}", "--out", "${BINPATCH}"])
    }

    // MARK: - libraries

    /// `libraries` 复用 `ClientManifest.Library` 的解析（坐标为空的条目被丢弃）
    func testLibrariesAreParsedAndEmptyNamesDropped() async throws {
        let p = try profile("""
        { "data": {}, "processors": [],
          "libraries": [ { "name": "g:a:1", "downloads": { "artifact": { "path": "p", "url": "u", "sha1": "s", "size": 1 } } },
                         { "name": "" } ] }
        """)
        XCTAssertEqual(p.libraries.count, 1, "坐标为空的条目应被 compactMap 丢弃")
        XCTAssertEqual(p.libraries[0].name, "g:a:1")
    }

    /// 空 profile ⇒ 全空，不崩
    func testEmptyProfile() async throws {
        let p = try profile("{}")
        XCTAssertTrue(p.data.isEmpty)
        XCTAssertTrue(p.processors.isEmpty)
        XCTAssertTrue(p.libraries.isEmpty)
    }
}
