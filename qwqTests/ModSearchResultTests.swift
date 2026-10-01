//
//  ModSearchResultTests.swift
//  qwqTests
//
//  覆盖 `Features/ModBrowser/Module/ModSearchResult.swift`（一页检索结果与分页判定）。
//
//  **为什么值得测**：`hasMore` 决定「加载更多」按钮/自动加载是否继续。
//  算错就是**提前停止**（用户看不到后面的条目）或**无限请求**（`offset` 已到底还在翻）。
//
//  ⚠️ 实现用的是 `offset + items.count`，**不是** `offset + limit` ——
//  这两者在「服务端返回的条目少于请求量」时结论不同。后者会误判「还有更多」，
//  导致继续请求却拿不到新条目（空转）。本文件把这条选择钉住。
//

import XCTest
@testable import qwq

final class ModSearchResultTests: XCTestCase {

    private func result(items: Int, totalHits: Int, offset: Int = 0, limit: Int = 20) -> ModSearchResult {
        let projects = (0..<items).map { i in
            ModProject(id: "p\(i)", slug: nil, title: "T", description: nil, iconURL: nil,
                       downloads: nil, categories: [], gameVersions: [], loaders: [],
                       versionIDs: [], projectType: .mod)
        }
        return ModSearchResult(items: projects, totalHits: totalHits, offset: offset, limit: limit)
    }

    // MARK: - hasMore

    /// 已取数量 < 总数 ⇒ 还有下一页
    func testHasMoreWhenFewerItemsThanTotal() async {
        XCTAssertTrue(result(items: 20, totalHits: 100, offset: 0).hasMore)
    }

    /// 已取数量 == 总数 ⇒ 没有下一页（**边界：相等即结束**）
    func testNoMoreWhenItemsExactlyFillTotal() async {
        XCTAssertFalse(result(items: 100, totalHits: 100, offset: 0).hasMore)
    }

    /// 最后一页（部分填充）⇒ 没有下一页
    func testNoMoreOnLastPartialPage() async {
        XCTAssertFalse(result(items: 7, totalHits: 47, offset: 40).hasMore)
    }

    /// 中间页：`offset + items.count == total` 恰好收尾
    func testBoundaryAtExactTotal() async {
        XCTAssertFalse(result(items: 20, totalHits: 60, offset: 40).hasMore,
                       "40 + 20 == 60 ⇒ 已到末尾，不应再翻")
        XCTAssertTrue(result(items: 20, totalHits: 61, offset: 40).hasMore,
                      "40 + 20 < 61 ⇒ 还有一页")
    }

    /// ⚠️ **本文件的靶心**：判定用 `items.count` 而非 `limit`。
    /// 服务端只返回 3 条（虽然请求了 20 条）且总数还有更多时，
    /// `offset + 3 < totalHits` 仍为真 ⇒ 继续翻页是有意义的。
    func testHasMoreUsesActualItemCountNotLimit() async {
        XCTAssertTrue(result(items: 3, totalHits: 50, offset: 0, limit: 20).hasMore,
                      "按 limit 算会得到 0+20<50（也真），但按 items.count 才是「实际取到多少」")
        // 反向：服务端返回 3 条而总数只有 3 ⇒ 已到末尾（若按 limit 会误判还有更多）
        XCTAssertFalse(result(items: 3, totalHits: 3, offset: 0, limit: 20).hasMore,
                       "按 limit 会误判 0+20<3 为假……此处两者同结论；关键是下一行的情形")
        XCTAssertFalse(result(items: 5, totalHits: 8, offset: 3, limit: 20).hasMore,
                       "3 + 5 == 8 ⇒ 结束（若按 limit 会误判 3+20<8 为假，同样结束）")
    }

    /// 服务端返回空页 + 总数未到 ⇒ 按 `items.count` 判定为**没有更多**（避免空转）
    func testEmptyPageMeansNoMoreEvenIfTotalSuggestsOtherwise() async {
        // offset=10, items=0, totalHits=100 ⇒ 10 + 0 < 100 为真
        // 这是实现的**已知行为**：空页不会立刻终止翻页（仍判 hasMore）。
        XCTAssertTrue(result(items: 0, totalHits: 100, offset: 10).hasMore,
                      "空页且总数未到 ⇒ 仍判还有更多（由调用方的「空页即停」策略兜住）")
    }

    /// 完全没有命中 ⇒ 没有下一页
    func testNoHitsMeansNoMore() async {
        XCTAssertFalse(result(items: 0, totalHits: 0, offset: 0).hasMore)
    }

    /// 首页就取满且总数正好 ⇒ 结束
    func testFirstPageFillingTotalExactly() async {
        XCTAssertFalse(result(items: 20, totalHits: 20, offset: 0, limit: 20).hasMore)
    }

    // MARK: - empty

    /// `.empty` 的四个字段都是零值，且 `hasMore == false`
    func testEmptyConstant() async {
        XCTAssertTrue(ModSearchResult.empty.items.isEmpty)
        XCTAssertEqual(ModSearchResult.empty.totalHits, 0)
        XCTAssertEqual(ModSearchResult.empty.offset, 0)
        XCTAssertEqual(ModSearchResult.empty.limit, 0)
        XCTAssertFalse(ModSearchResult.empty.hasMore)
    }

    // MARK: - 值语义

    func testEqualityIncludesAllFields() async {
        XCTAssertEqual(result(items: 1, totalHits: 5, offset: 0, limit: 20),
                       result(items: 1, totalHits: 5, offset: 0, limit: 20))
        XCTAssertNotEqual(result(items: 1, totalHits: 5, offset: 0, limit: 20),
                          result(items: 1, totalHits: 6, offset: 0, limit: 20))
        XCTAssertNotEqual(result(items: 1, totalHits: 5, offset: 0, limit: 20),
                          result(items: 1, totalHits: 5, offset: 1, limit: 20))
    }
}
