//
//  SidebarHighlightTests.swift
//  qwqTests
//
//  覆盖 `UI/SidebarHighlight.swift`。
//
//  **为什么值得测**：文件头点明了一个「坏了没有报错」的坑：
//
//  > `offsets` 与 `index(for:)` 是**成对的**：后者的返回值就是前者的下标。
//  > 两处必须同步改，否则高亮条会落在错误的行上 —— 而且不会有编译错误或运行时提示，
//  > 症状只是「高亮歪了一格」。
//
//  因此本文件把**整张配对表**钉死：index(for:) 的每个输出都必须对应 offsets 的一个
//  合法下标，且偏移量严格递增（不递增 = 高亮条会重叠/倒退）。
//

import XCTest
@testable import qwq

final class SidebarHighlightTests: XCTestCase {

    /// `offsets` 共 8 项（3 个游戏子分类 + 5 个一级分类），首项 12 是顶部留白
    func testOffsetsHasEightEntries() async {
        XCTAssertEqual(SidebarHighlight.offsets.count, 8)
        XCTAssertEqual(SidebarHighlight.offsets.first, 12, "首项 12 是顶部留白")
    }

    /// ⚠️ **成对不变量**：index(for:) 的全部 8 个输出必须落在 offsets 合法下标 0...7
    func testAllIndexesAreValidOffsetsSubscripts() async {
        for section in GameSidebarSection.allCases {
            let subs: [GameSubCategory?] = section == .game ? [.release, .snapshot, .ancient, nil] : [nil]
            for sub in subs {
                let idx = SidebarHighlight.index(for: section, sub: sub)
                XCTAssertTrue((0..<SidebarHighlight.offsets.count).contains(idx),
                              "\(section)+\(String(describing: sub)) → index \(idx) 越界（offsets 只有 \(SidebarHighlight.offsets.count) 项）")
            }
        }
    }

    /// ⚠️ **配对表本体**：每个 section/子分类 对应唯一固定下标（改了这里 = 高亮歪一格）
    func testIndexTable() async {
        XCTAssertEqual(SidebarHighlight.index(for: .game, sub: nil), 0, "游戏一级头部是 0（文件头注明不是 1）")
        XCTAssertEqual(SidebarHighlight.index(for: .game, sub: .release), 1)
        XCTAssertEqual(SidebarHighlight.index(for: .game, sub: .snapshot), 2)
        XCTAssertEqual(SidebarHighlight.index(for: .game, sub: .ancient), 3)
        XCTAssertEqual(SidebarHighlight.index(for: .mod, sub: nil), 4)
        XCTAssertEqual(SidebarHighlight.index(for: .resourcePack, sub: nil), 5)
        XCTAssertEqual(SidebarHighlight.index(for: .shader, sub: nil), 6)
        XCTAssertEqual(SidebarHighlight.index(for: .modpack, sub: nil), 7)
    }

    /// ⚠️ **不重叠不变量**：8 个 index() 输出互不相同 ⇒ 高亮条不会两行重叠
    func testAllIndexesAreDistinct() async {
        let all = GameSidebarSection.allCases.flatMap { s -> [Int] in
            if s == .game { return [SidebarHighlight.index(for: s, sub: nil),
                                    SidebarHighlight.index(for: s, sub: .release),
                                    SidebarHighlight.index(for: s, sub: .snapshot),
                                    SidebarHighlight.index(for: s, sub: .ancient)] }
            return [SidebarHighlight.index(for: s, sub: nil)]
        }
        XCTAssertEqual(Set(all).count, 8, "8 个高亮位置必须互不相同")
    }

    /// ⚠️ **单调不变量**：offsets 严格递增 ⇒ 高亮条只会向下移动
    func testOffsetsAreStrictlyIncreasing() async {
        for i in 1..<SidebarHighlight.offsets.count {
            XCTAssertGreaterThan(SidebarHighlight.offsets[i], SidebarHighlight.offsets[i-1],
                                 "offset[\(i)] 必须大于 offset[\(i-1)]（否则高亮条重叠/倒退）")
        }
    }

    /// 行高表 36/28/28/28（游戏区）+ 36×4（其余）累加出的值：12, 48, 76, 104, 132, 168, 204, 240
    func testOffsetsAreCumulativeHeights() async {
        let expected: [CGFloat] = [12, 48, 76, 104, 132, 168, 204, 240]
        XCTAssertEqual(SidebarHighlight.offsets, expected)
    }
}
