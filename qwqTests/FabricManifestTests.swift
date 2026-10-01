//
//  FabricManifestTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/Mod/Loader/Fabric/FabricManifest.swift`
//  （Fabric 加载器版本清单条目）。
//
//  **为什么值得测**：`parse(_:)` 把 Fabric meta API 的响应解析成条目数组，
//  而「取最新稳定版」的调用方按 `stable` 过滤。字段取错（例如把 `loader.stable`
//  读成顶层 `stable`）会让启动器**挑到测试版加载器**，或在全是稳定版时报「没有可用版本」。
//
//  `parse` 的失败语义也要钉住：非法 JSON **抛出**（不是返回空数组）——
//  调用方据此区分「解析失败」与「响应确实是空列表」。
//

import XCTest
@testable import qwq

final class FabricManifestTests: XCTestCase {

    private func parse(_ json: String) throws -> [FabricManifest] {
        try FabricManifest.parse(Data(json.utf8))
    }

    func testParseReadsNestedLoaderFields() async throws {
        let manifests = try parse("""
        [ { "loader": { "version": "0.15.11", "stable": true } },
          { "loader": { "version": "0.16.0-beta.1", "stable": false } } ]
        """)
        XCTAssertEqual(manifests.count, 2)
        XCTAssertEqual(manifests[0].loaderVersion, "0.15.11")
        XCTAssertTrue(manifests[0].stable)
        XCTAssertEqual(manifests[1].loaderVersion, "0.16.0-beta.1")
        XCTAssertFalse(manifests[1].stable)
    }

    /// ⚠️ 字段路径是 **`loader.version` / `loader.stable`**（嵌套），
    /// 不是顶层 —— 写错会取到空串 / false，从而挑不出稳定版
    func testTopLevelFieldsAreNotUsed() async throws {
        let manifests = try parse("""
        [ { "version": "顶层不该被读", "stable": true, "loader": { "version": "", "stable": false } } ]
        """)
        XCTAssertEqual(manifests[0].loaderVersion, "",
                       "实现只读 loader.version；顶层 version 不参与")
        XCTAssertFalse(manifests[0].stable, "实现只读 loader.stable")
    }

    /// 空数组 ⇒ 空数组（解析成功但无条目，与「解析失败」不同）
    func testEmptyArrayYieldsEmpty() async throws {
        XCTAssertTrue(try parse("[]").isEmpty)
    }

    /// 缺字段 ⇒ SwiftyJSON 默认值（空串 / false），不崩
    func testMissingFieldsFallBackToDefaults() async throws {
        let manifests = try parse("[ { } ]")
        XCTAssertEqual(manifests[0].loaderVersion, "")
        XCTAssertFalse(manifests[0].stable)
    }

    /// ⚠️ 非法 JSON ⇒ **抛出**（而不是静默返回空数组）
    func testInvalidJSONThrows() async {
        await XCTAssertThrowsErrorAsync(try FabricManifest.parse(Data("{ not json".utf8)))
    }

    /// 顶层不是数组（例如对象）⇒ `arrayValue` 为空 ⇒ 空数组，不抛错
    func testNonArrayTopLevelYieldsEmpty() async throws {
        XCTAssertTrue(try parse(#"{ "loader": { "version": "x" } }"#).isEmpty)
    }

    /// `Identifiable`：每个实例的 `id` 唯一（列表渲染用它做 identity）
    func testEachInstanceHasUniqueID() async throws {
        let manifests = try parse("""
        [ { "loader": { "version": "1", "stable": true } },
          { "loader": { "version": "1", "stable": true } } ]
        """)
        XCTAssertNotEqual(manifests[0].id, manifests[1].id,
                          "两条内容相同的条目也必须有不同 id（否则列表复用会错）")
    }

    /// `id` 可变（`public var id`），可被外部重置
    func testIDIsMutable() async throws {
        let manifests = try parse(#"[ { "loader": { "version": "1", "stable": true } } ]"#)
        let newID = UUID()
        manifests[0].id = newID
        XCTAssertEqual(manifests[0].id, newID)
    }

    /// 是 `class`（引用类型）：`let` 数组里的元素仍可改 `id`
    func testIsReferenceType() async throws {
        let manifests = try parse(#"[ { "loader": { "version": "1", "stable": true } } ]"#)
        let alias = manifests[0]
        alias.id = UUID()
        XCTAssertEqual(manifests[0].id, alias.id, "FabricManifest 是 class，共享同一实例")
    }

    /// 能按 `stable` 过滤出稳定版（调用方「取最新稳定版」的实际用法）
    func testFilteringStableVersions() async throws {
        let manifests = try parse("""
        [ { "loader": { "version": "0.16.0-beta.1", "stable": false } },
          { "loader": { "version": "0.15.11", "stable": true } },
          { "loader": { "version": "0.16.0-beta.2", "stable": false } } ]
        """)
        let stable = manifests.filter(\.stable)
        XCTAssertEqual(stable.map(\.loaderVersion), ["0.15.11"])
    }
}

/// `XCTAssertThrowsError` 的 autoclosure 不支持 `async` 上下文，故自行包一层。
private func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () throws -> Any,
                                       file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try expression()
        XCTFail("本应抛出错误，但正常返回了", file: file, line: line)
    } catch {
        // 预期
    }
}
