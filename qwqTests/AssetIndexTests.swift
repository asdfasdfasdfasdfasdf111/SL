//
//  AssetIndexTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/AssetIndex.swift`（资源索引解析）。
//
//  **为什么值得测**：它决定「要下载/校验哪些资源」，而资源对象数以千计，
//  错一个字段就是**静默漏下一批资源**，症状要到游戏里缺贴图/缺声音才显形。
//  它的两个行为边界都写在文件头注释里，本文件逐条钉住：
//
//  1. **不保留字典的 key（逻辑路径）** —— 资源按内容哈希寻址，路径信息在此丢弃。
//     推论：`objects` 是**数组**，两个不同逻辑路径若指向同一个 hash，会产出**两个条目**（不去重）。
//  2. **`appendTo` 的分桶布局** `<base>/<hash 前两位>/<hash>`，且调用方要传
//     `.../assets/objects` 本身而不是版本目录。
//
//  ⚠️ 断言不能依赖 `objects` 的**顺序**：它来自 `json["objects"].dictionaryValue.values`，
//  字典顺序未定义。本文件一律先按 `hash` 排序再比较。
//

import XCTest
@testable import qwq

final class AssetIndexTests: XCTestCase {

    private func parse(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> AssetIndex {
        try AssetIndex.parse(Data(json.utf8))
    }

    private func sortedObjects(_ index: AssetIndex) -> [(hash: String, size: Int32)] {
        index.objects.map { ($0.hash, $0.size) }.sorted { $0.0 < $1.0 }
    }

    // MARK: - 解析

    func testParseExtractsHashAndSize() async throws {
        let index = try parse("""
        { "objects": {
            "minecraft/sounds/a.ogg": { "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size": 1234 },
            "minecraft/textures/b.png": { "hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "size": 56 }
        } }
        """)
        XCTAssertEqual(sortedObjects(index).map(\.hash),
                       ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
        // sortedObjects 按 hash 升序：a… 在前（size 1234）、b… 在后（size 56）
        XCTAssertEqual(sortedObjects(index).map(\.size), [1234, 56])
    }

    /// 空 `objects` ⇒ 空数组（不少见：某些索引只含极少量资源）
    func testParseEmptyObjectsYieldsEmptyArray() async throws {
        XCTAssertTrue(try parse(#"{ "objects": { } }"#).objects.isEmpty)
    }

    /// 完全没有 `objects` 键 ⇒ 同样是空数组（`dictionaryValue` 对缺失键返回空字典）
    func testParseMissingObjectsKeyYieldsEmptyArray() async throws {
        XCTAssertTrue(try parse("{}").objects.isEmpty)
    }

    /// 非法 JSON ⇒ **抛出**（源码注释：「`JSON(data:)` 失败时抛出，调用方负责降级处理」）
    func testParseInvalidJSONThrows() async {
        await XCTAssertThrowsErrorAsync(try AssetIndex.parse(Data("{ not json".utf8)))
    }

    /// 缺字段时用 SwiftyJSON 的默认值（hash → 空串，size → 0），不崩
    func testParseMissingFieldsFallBackToDefaults() async throws {
        let index = try parse(#"{ "objects": { "p": { } } }"#)
        XCTAssertEqual(index.objects.count, 1)
        XCTAssertEqual(index.objects.first?.hash, "")
        XCTAssertEqual(index.objects.first?.size, 0)
    }

    /// 非数字 `size` ⇒ 落到 `int32Value` 的默认 0（不崩）
    func testParseNonNumericSizeFallsBackToZero() async throws {
        let index = try parse(#"{ "objects": { "p": { "hash": "cc", "size": "not-a-number" } } }"#)
        XCTAssertEqual(index.objects.first?.size, 0)
    }

    /// 文件头明说「不保留字典的 key（逻辑路径）」。
    /// 可观测的推论：**同一 hash 挂在两个不同逻辑路径下，会产出两个条目**（不做去重）。
    /// 钉住它，避免将来有人误以为这里已经按 hash 去重。
    func testSameHashUnderTwoLogicalPathsProducesTwoEntries() async throws {
        let index = try parse("""
        { "objects": {
            "minecraft/a.ogg": { "hash": "dddddddddddddddddddddddddddddddddddddddd", "size": 1 },
            "minecraft/b.ogg": { "hash": "dddddddddddddddddddddddddddddddddddddddd", "size": 1 }
        } }
        """)
        XCTAssertEqual(index.objects.count, 2,
                       "解析层不按 hash 去重；两个逻辑路径指向同一内容会产出两个条目")
        XCTAssertEqual(Set(index.objects.map(\.hash)).count, 1)
    }

    // MARK: - Object.appendTo：分桶布局

    /// `<base>/<hash 前两位>/<hash>` —— 官方分桶布局（避免单个 objects/ 堆几万文件）
    func testAppendToUsesTwoCharacterHashBucket() async throws {
        let index = try parse(#"{ "objects": { "p": { "hash": "0123456789abcdef", "size": 1 } } }"#)
        let object = try XCTUnwrap(index.objects.first)
        let base = URL(fileURLWithPath: "/tmp/assets/objects")

        let result = object.appendTo(base)

        XCTAssertEqual(result.path, "/tmp/assets/objects/01/0123456789abcdef")
        XCTAssertEqual(result.lastPathComponent, object.hash, "文件名就是完整 hash")
        XCTAssertEqual(result.deletingLastPathComponent().lastPathComponent, "01", "一级子目录取 hash 前两位")
    }

    /// 调用方传的应当是 `.../assets/objects` 本身 —— 用「版本目录」当 base 时会多一层，
    /// 本用例固定住「base 被原样当作 objects 根」这一语义。
    func testAppendToTreatsBaseAsObjectsRootVerbatim() async throws {
        let index = try parse(#"{ "objects": { "p": { "hash": "abcdef", "size": 1 } } }"#)
        let object = try XCTUnwrap(index.objects.first)

        let relative = URL(fileURLWithPath: "/root")
        XCTAssertEqual(object.appendTo(relative).path, "/root/ab/abcdef")
    }

    /// 边界：hash 只有 1 个字符时 `prefix(2)` 退化为整个串，仍产出 `base/x/x`，不崩
    func testAppendToWithSingleCharacterHashDoesNotCrash() async throws {
        let index = try parse(#"{ "objects": { "p": { "hash": "a", "size": 1 } } }"#)
        let object = try XCTUnwrap(index.objects.first)
        XCTAssertEqual(object.appendTo(URL(fileURLWithPath: "/root")).path, "/root/a/a")
    }

    /// 空 hash（缺字段时的默认值）不得导致崩溃
    func testAppendToWithEmptyHashDoesNotCrash() async throws {
        let index = try parse(#"{ "objects": { "p": { } } }"#)
        let object = try XCTUnwrap(index.objects.first)
        _ = object.appendTo(URL(fileURLWithPath: "/root"))   // 只要不崩即可；路径形态未定义
    }

    /// `appendTo` 只用 hash，与 size 无关
    func testAppendToIgnoresSize() async throws {
        let a = try XCTUnwrap(try parse(#"{ "objects": { "p": { "hash": "ffff", "size": 1 } } }"#).objects.first)
        let b = try XCTUnwrap(try parse(#"{ "objects": { "p": { "hash": "ffff", "size": 999999 } } }"#).objects.first)
        let base = URL(fileURLWithPath: "/root")
        XCTAssertEqual(a.appendTo(base).path, b.appendTo(base).path)
    }

    // MARK: - 手工构造入口

    /// `init(objects:)` 是公开的（注释：「从缓存重建、或测试时手工构造用」），
    /// 但与 `parse` 走的是同一个 `objects` 数组
    func testManualInitKeepsGivenObjects() async throws {
        let parsed = try parse(#"{ "objects": { "p": { "hash": "ab", "size": 7 } } }"#)
        let manual = AssetIndex(objects: parsed.objects)
        XCTAssertEqual(manual.objects.count, 1)
        XCTAssertEqual(manual.objects.first?.hash, "ab")
        XCTAssertEqual(manual.objects.first?.size, 7)
    }
}

/// `XCTAssertThrowsError` 的 autoclosure 不支持 `async` 上下文，
/// 故自行包一层（同 `JavaResolverTests` 的处理方式）。
private func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () throws -> Any,
                                       file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try expression()
        XCTFail("本应抛出错误，但正常返回了", file: file, line: line)
    } catch {
        // 预期
    }
}
