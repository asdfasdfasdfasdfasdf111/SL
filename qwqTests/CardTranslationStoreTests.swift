//
//  CardTranslationStoreTests.swift
//  qwqTests
//
//  覆盖 `Features/Translation/CardTranslationStore.swift`。
//
//  **为什么值得测**：它是「翻译结果」的内存上限裁剪 —— 写满 2000 条后
//  只保留「正在翻译」的活跃条目，其余淘汰。这套规则有两个实现细节容易写错：
//
//  1. `set` 的触发条件是 **`dict[id] == nil` 且满 2000** —— 覆盖已存在条目时
//     **不裁剪**（否则写一个值可能误删一堆）；
//  2. `merge` 的触发条件是 **`dict.count + batch.count > 2000`**（不是先 merge 再判）——
//     且裁剪发生在 merge **之前**，裁完再并。
//
//  另有一条文件头自述的语义：活跃集为空 ⇒ 裁剪结果为空字典，与原「整体清空」等价。
//

import XCTest
@testable import qwq

final class CardTranslationStoreTests: XCTestCase {

    // MARK: - set

    /// 未超限 ⇒ 直接写入，不做任何裁剪
    func testSetWritesWithoutTrimWhenUnderLimit() async {
        var dict: [String: String] = [:]
        CardTranslationStore.set(&dict, id: "a", value: "译A", active: [])
        XCTAssertEqual(dict, ["a": "译A"])
    }

    /// ⚠️ 覆盖**已存在**的 key 时不触发裁剪（`dict[id] == nil` 才判超限）
    func testSetDoesNotTrimWhenOverwritingExistingKey() async {
        var dict = Dictionary(uniqueKeysWithValues: (0..<2000).map { ("k\($0)", "v\($0)") })
        dict["k0"] = "旧值"   // 让 k0 存在

        CardTranslationStore.set(&dict, id: "k0", value: "新值", active: [])

        XCTAssertEqual(dict["k0"], "新值", "写已存在的 key 应直接覆盖")
        XCTAssertEqual(dict.count, 2000, "覆盖不应触发裁剪")
    }

    /// 超限 + 新 key ⇒ 先裁剪（只留 active ids），再写入
    func testSetTrimsToActiveThenWrites() async {
        var dict = Dictionary(uniqueKeysWithValues: (0..<2000).map { ("k\($0)", "v\($0)") })

        CardTranslationStore.set(&dict, id: "brand-new", value: "译新", active: ["k5", "k9"])

        XCTAssertEqual(dict["brand-new"], "译新", "新 key 必须写入")
        XCTAssertEqual(dict["k5"], "v5", "活跃条目保留")
        XCTAssertEqual(dict["k9"], "v9", "活跃条目保留")
        XCTAssertNil(dict["k1"], "非活跃条目被裁剪")
        XCTAssertEqual(dict.count, 3, "只剩两个活跃 + 一个新写入")
    }

    /// 活跃集为空 + 超限 ⇒ 裁成空字典再写入（文件头自述：与「整体清空」等价）
    func testSetWithEmptyActiveClearsEverything() async {
        var dict = Dictionary(uniqueKeysWithValues: (0..<2000).map { ("k\($0)", "v\($0)") })

        CardTranslationStore.set(&dict, id: "x", value: "译", active: [])

        XCTAssertEqual(dict, ["x": "译"])
    }

    /// 正好 2000（不满 2001）⇒ 不触发裁剪
    func testSetAtExactLimitDoesNotTrim() async {
        var dict = Dictionary(uniqueKeysWithValues: (0..<1999).map { ("k\($0)", "v\($0)") })  // 1999 条
        CardTranslationStore.set(&dict, id: "last", value: "v", active: [])
        XCTAssertEqual(dict.count, 2000, "加到正好 2000 不应裁剪")
    }

    // MARK: - merge

    /// 合并后不超限 ⇒ 直接合并，不裁剪
    func testMergeWithoutOverflowKeepsAll() async {
        var dict = ["a": "1"]
        CardTranslationStore.merge(&dict, batch: ["b": "2", "c": "3"], active: [])
        XCTAssertEqual(dict, ["a": "1", "b": "2", "c": "3"])
    }

    /// 合并后超限 ⇒ 先裁剪（只留 active + batch 全量），再合并
    func testMergeTrimsWhenCombinedOverLimit() async {
        var dict = Dictionary(uniqueKeysWithValues: (0..<1990).map { ("k\($0)", "v\($0)") })

        CardTranslationStore.merge(&dict, batch: ["a": "A", "b": "B"], active: ["k0", "k1"])

        XCTAssertEqual(dict["k0"], "v0", "活跃旧条目保留")
        XCTAssertEqual(dict["k1"], "v1")
        XCTAssertEqual(dict["a"], "A", "新 batch 全量并入（不被裁剪）")
        XCTAssertEqual(dict["b"], "B")
        XCTAssertNil(dict["k5"], "非活跃旧条目被裁剪")
        XCTAssertEqual(dict.count, 4, "两个活跃 + batch 两条")
    }

    /// ⚠️ 判据是 `dict.count + batch.count > maxEntries`（不是先合并再判）
    /// —— 边界：1999 + 2 > 2000 ⇒ 裁剪；1998 + 2 = 2000 ⇒ 不裁剪
    func testMergeOverflowBoundary() async {
        var under = Dictionary(uniqueKeysWithValues: (0..<1998).map { ("k\($0)", "v\($0)") })
        CardTranslationStore.merge(&under, batch: ["a": "A", "b": "B"], active: [])
        XCTAssertEqual(under.count, 2000, "1998 + 2 = 2000 不裁剪")

        var over = Dictionary(uniqueKeysWithValues: (0..<1999).map { ("k\($0)", "v\($0)") })
        CardTranslationStore.merge(&over, batch: ["a": "A", "b": "B"], active: [])
        XCTAssertEqual(over.count, 2, "1999 + 2 > 2000 ⇒ 先裁剪成空再并 batch")
    }

    /// merge 覆盖已存在的 key 时新值胜出（`merge(batch) { _, new in new }`）
    func testMergeNewValueWinsOnConflict() async {
        var dict = ["k": "旧"]
        CardTranslationStore.merge(&dict, batch: ["k": "新"], active: [])
        XCTAssertEqual(dict["k"], "新")
    }

    // MARK: - 常量

    func testMaxEntriesConstant() async {
        XCTAssertEqual(CardTranslationStore.maxEntries, 2000)
    }
}
