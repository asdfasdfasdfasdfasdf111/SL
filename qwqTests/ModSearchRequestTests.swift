//
//  ModSearchRequestTests.swift
//  qwqTests
//
//  覆盖 `Features/ModBrowser/Module/ModSearchRequest.swift`（检索入参 + 翻页）。
//
//  **为什么值得测**：`nextPage()` 是「加载更多」的核心 —— 偏移量算错就会出现
//  **重复条目**或**跳过条目**，而两者在界面上都不报错，只表现为列表内容不对。
//
//  另有一条**刻意的能力边界**写在文件头：本模型**不提供 loader / 游戏版本过滤**，
//  因为分类页走的那条检索入口只支持按 `project_type` 检索
//  （源码原话：「写了也无人实现，属『凭空发明能力』」）。本文件用「字段集合」把它钉住。
//

import XCTest
@testable import qwq

final class ModSearchRequestTests: XCTestCase {

    // MARK: - 默认值

    func testDefaults() async {
        let request = ModSearchRequest(projectType: .mod)
        XCTAssertEqual(request.query, "", "默认空关键词 = 该分类下的默认列表")
        XCTAssertEqual(request.offset, 0)
        XCTAssertEqual(request.limit, 30, "既有分类页取 30")
    }

    /// 文件头明说「不提供 loader / 游戏版本过滤」——
    /// 用可构造的字段集合把这条边界固定住：一旦有人加了字段，本用例会红。
    func testModelDeliberatelyHasNoLoaderOrGameVersionFilter() async {
        let request = ModSearchRequest(query: "q", projectType: .shader, offset: 10, limit: 5)
        // 能影响检索的输入只有这四个；没有 loader / gameVersion / facets 之类的入口。
        XCTAssertEqual(request.query, "q")
        XCTAssertEqual(request.projectType, .shader)
        XCTAssertEqual(request.offset, 10)
        XCTAssertEqual(request.limit, 5)
    }

    // MARK: - nextPage

    /// 翻页：偏移量顺推一页，其余字段不变
    func testNextPageAdvancesOffsetByLimit() async {
        let first = ModSearchRequest(query: "sodium", projectType: .mod, offset: 0, limit: 30)
        let second = first.nextPage()

        XCTAssertEqual(second.offset, 30)
        XCTAssertEqual(second.query, "sodium")
        XCTAssertEqual(second.projectType, .mod)
        XCTAssertEqual(second.limit, 30)
    }

    /// 连翻多页：偏移量线性累加，不重叠、不跳号
    func testConsecutivePagesDoNotOverlapOrSkip() async {
        var request = ModSearchRequest(query: "", projectType: .modpack, offset: 0, limit: 25)
        var windows: [Range<Int>] = []
        for _ in 0..<5 {
            windows.append(request.offset..<(request.offset + request.limit))
            request = request.nextPage()
        }

        XCTAssertEqual(windows.map(\.lowerBound), [0, 25, 50, 75, 100])
        for (a, b) in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound, "相邻页必须首尾相接：不重叠也不跳号")
        }
    }

    /// `limit` 非默认值也按它推进
    func testNextPageHonorsCustomLimit() async {
        let request = ModSearchRequest(projectType: .mod, offset: 7, limit: 3)
        XCTAssertEqual(request.nextPage().offset, 10)
    }

    /// `nextPage` 不改动原值（值类型）
    func testNextPageDoesNotMutateOriginal() async {
        let original = ModSearchRequest(query: "a", projectType: .mod, offset: 0, limit: 30)
        _ = original.nextPage()
        XCTAssertEqual(original.offset, 0, "ModSearchRequest 是 struct，翻页返回新值")
    }

    // MARK: - 值语义

    func testEqualityIncludesAllFields() async {
        let a = ModSearchRequest(query: "q", projectType: .mod, offset: 0, limit: 30)
        let b = ModSearchRequest(query: "q", projectType: .mod, offset: 0, limit: 30)
        XCTAssertEqual(a, b)

        XCTAssertNotEqual(a, ModSearchRequest(query: "q2", projectType: .mod, offset: 0, limit: 30))
        XCTAssertNotEqual(a, ModSearchRequest(query: "q", projectType: .shader, offset: 0, limit: 30))
        XCTAssertNotEqual(a, ModSearchRequest(query: "q", projectType: .mod, offset: 1, limit: 30))
        XCTAssertNotEqual(a, ModSearchRequest(query: "q", projectType: .mod, offset: 0, limit: 10))
    }

    func testUsableInSet() async {
        let requests: Set<ModSearchRequest> = [
            ModSearchRequest(projectType: .mod, offset: 0),
            ModSearchRequest(projectType: .mod, offset: 0),
            ModSearchRequest(projectType: .mod, offset: 30),
        ]
        XCTAssertEqual(requests.count, 2)
    }
}
