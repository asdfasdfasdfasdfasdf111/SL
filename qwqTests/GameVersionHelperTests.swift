//
//  GameVersionHelperTests.swift
//  qwqTests
//
//  覆盖 `Features/Game/GameVersionHelper.swift`（版本比较 / 显示排序 / 愚人节版本判断）。
//
//  **为什么值得测**：`compare` 决定版本列表的**排序**（选版本时看到的第一眼），
//  `isAprilFoolVersion` 决定**要不要把某个版本标成愚人节**。两者出错都不崩，
//  只是把错误的顺序/标签呈现给用户。二者此前均 0 测试触达。
//
//  本文件特别钉住三类**实现怪癖**（都是代码事实，不是新需求）：
//
//  1. `compare` 用 `compactMap { Int($0) }` 切段 ⇒ **非数字段被整段丢弃**：
//     `"1.20.1-rc1"` 退化成 `[1, 20]`，与 `"1.20"` **判等**；
//     `"1.20-pre"` 退化成 `[1]`，于是它 **小于** `"1.19"`。
//  2. `isAprilFoolVersion` 的**列表命中检查在 `guard type == "snapshot"` 之前** ⇒
//     列表内的版本即使 `type` 传 `"release"` 也返回 `true`。
//  3. `id` 会先把 `"point"` 替换成 `"."` 再比对列表。
//

import XCTest
@testable import qwq

final class GameVersionHelperTests: XCTestCase {

    // MARK: - compare：点分数字逐段比较

    func testCompareNumericOrderNotLexicographic() async {
        // 字符串比较会把 "1.10" 排在 "1.9" 前面，这里必须是数值顺序
        XCTAssertLessThan(GameVersionHelper.compare("1.9", "1.10"), 0)
        XCTAssertGreaterThan(GameVersionHelper.compare("1.10", "1.9"), 0)
        XCTAssertLessThan(GameVersionHelper.compare("1.9.4", "1.10"), 0)
    }

    func testCompareEqualVersions() async {
        XCTAssertEqual(GameVersionHelper.compare("1.20.1", "1.20.1"), 0)
    }

    /// 缺位按 0 补 ⇒ `1.20` 与 `1.20.0` 判等
    func testMissingComponentsTreatedAsZero() async {
        XCTAssertEqual(GameVersionHelper.compare("1.20", "1.20.0"), 0)
        XCTAssertEqual(GameVersionHelper.compare("1.20.0", "1.20"), 0)
        XCTAssertLessThan(GameVersionHelper.compare("1.20", "1.20.1"), 0)
    }

    /// 返回的是**差值**而非 ±1（调用方只该用符号，但本用例把事实钉住）
    func testCompareReturnsDifferenceNotSign() async {
        XCTAssertEqual(GameVersionHelper.compare("1.9", "1.10"), -1)
        XCTAssertEqual(GameVersionHelper.compare("1.10", "1.9"), 1)
        XCTAssertEqual(GameVersionHelper.compare("1.2", "1.20"), -18)
    }

    // MARK: - compare 的怪癖：非数字段被丢弃

    /// `"1.20.1-rc1"` 的第三段 `"1-rc1"` 不是整数 ⇒ 被 `compactMap` 丢弃 ⇒ `[1, 20]`
    /// ⇒ 与 `"1.20"` **判等**。这是实现事实，不是期望语义。
    func testPreReleaseSuffixSegmentIsDroppedAndComparesEqual() async {
        XCTAssertEqual(GameVersionHelper.compare("1.20.1-rc1", "1.20"), 0,
                       "非数字段被 compactMap 丢弃，故与 1.20 判等（已知怪癖）")
    }

    /// **更反直觉的一条**：`"1.20-pre"` 的第二段 `"20-pre"` 非整数被丢弃 ⇒ `[1]`
    /// ⇒ 它 **小于** `"1.19"`（`[1]` vs `[1, 19]`）。
    func testVersionWithSuffixOnSecondSegmentComparesLessThanLowerVersion() async {
        XCTAssertLessThan(GameVersionHelper.compare("1.20-pre", "1.19"), 0,
                          "`20-pre` 被丢弃后只剩 [1]，故小于 [1,19]（已知怪癖）")
    }

    /// 纯非数字 id（如快照名）⇒ 数字段为空 ⇒ 与任何纯数字版本比较**小于**（-1），
    /// 而不是判等：`compare` 的循环里 pa=[] 按 0 补齐，`vb=1` → 返回 `0-1 = -1`。
    func testNonNumericIdComparesEqualToNumericVersion() async {
        XCTAssertLessThan(GameVersionHelper.compare("23w33a", "1.20"), 0,
                          "快照名没有可解析的数字段，退化成空数组 → 空数组 < 任何非空版本（已知怪癖）")
    }

    // MARK: - sortForDisplay

    /// 降序排列
    func testSortForDisplayIsDescending() async {
        let sorted = GameVersionHelper.sortForDisplay(["1.9", "1.20.1", "1.10", "1.16.5"], selected: "")
        XCTAssertEqual(sorted, ["1.20.1", "1.16.5", "1.10", "1.9"])
    }

    /// `selected` 非空且存在于列表 ⇒ 置顶（其余仍保持降序）
    func testSortForDisplayPinsSelectedToTop() async {
        let sorted = GameVersionHelper.sortForDisplay(["1.9", "1.20.1", "1.10"], selected: "1.9")
        XCTAssertEqual(sorted, ["1.9", "1.20.1", "1.10"])
    }

    /// `selected` 不在列表里 ⇒ 不插入，结果就是纯降序
    func testSortForDisplayWithUnknownSelectedLeavesOrderUntouched() async {
        let sorted = GameVersionHelper.sortForDisplay(["1.9", "1.20.1"], selected: "1.99.99")
        XCTAssertEqual(sorted, ["1.20.1", "1.9"])
    }

    /// `selected` 为空串 ⇒ 不置顶（避免空串把某个版本顶上去）
    func testEmptySelectedDoesNotPinAnything() async {
        let sorted = GameVersionHelper.sortForDisplay(["1.9", "1.20.1"], selected: "")
        XCTAssertEqual(sorted, ["1.20.1", "1.9"])
    }

    /// 置顶是「移除再插入」而非「交换」⇒ 元素个数不变、无重复
    func testPinningDoesNotDuplicateOrDropEntries() async {
        let input = ["1.9", "1.20.1", "1.10", "1.16.5"]
        let sorted = GameVersionHelper.sortForDisplay(input, selected: "1.10")
        XCTAssertEqual(sorted.count, input.count)
        XCTAssertEqual(Set(sorted), Set(input))
        XCTAssertEqual(sorted.first, "1.10")
    }

    // MARK: - isAprilFoolVersion

    /// 列表内的愚人节版本 ⇒ true
    func testKnownAprilFoolVersionsReturnTrue() async {
        for id in GameVersionHelper.aprilFoolVersions {
            XCTAssertTrue(GameVersionHelper.isAprilFoolVersion(id: id, type: "snapshot"),
                          "\(id) 在愚人节列表内，应判 true")
        }
    }

    /// 大小写不敏感（比对前 `lowercased()`）
    func testAprilFoolListMatchIsCaseInsensitive() async {
        XCTAssertTrue(GameVersionHelper.isAprilFoolVersion(id: "23W13A_OR_B", type: "snapshot"))
    }

    /// `id` 先把 `"point"` 替换成 `"."` 再比对 ⇒ 写成 `v1point34` 也能命中列表里的 `v1.34`
    func testPointIsNormalizedToDotBeforeListLookup() async {
        XCTAssertTrue(GameVersionHelper.isAprilFoolVersion(id: "3d shareware v1point34", type: "snapshot"),
                      "`point` → `.` 的归一化使 v1point34 命中 v1.34")
    }

    /// **顺序怪癖**：列表命中检查在 `guard type == "snapshot"` **之前** ⇒
    /// 列表内版本传 `type: "release"` 仍返回 true
    func testListHitReturnsTrueEvenWhenTypeIsNotSnapshot() async {
        XCTAssertTrue(GameVersionHelper.isAprilFoolVersion(id: "24w14potato", type: "release"),
                      "列表检查先于 type 守卫（实现顺序事实）")
    }

    /// 非列表版本 + 非 snapshot ⇒ false
    func testNonSnapshotUnknownIdReturnsFalse() async {
        XCTAssertFalse(GameVersionHelper.isAprilFoolVersion(id: "1.20.5-foo", type: "release"))
        XCTAssertFalse(GameVersionHelper.isAprilFoolVersion(id: "1.20.5-foo", type: ""))
    }

    /// 新版 Mojang 命名（2026 起）：`26.3-snapshot-7` 是**正式快照**，绝不可判愚人节
    func testNewStyleSnapshotIsNotAprilFool() async {
        XCTAssertFalse(GameVersionHelper.isAprilFoolVersion(id: "26.3-snapshot-7", type: "snapshot"))
        XCTAssertFalse(GameVersionHelper.isAprilFoolVersion(id: "26-snapshot-1", type: "snapshot"))
    }

    /// 旧版标准快照 `23w33a`（**不在**列表里）⇒ 命中周快照格式 ⇒ false
    func testOldStyleWeeklySnapshotIsNotAprilFool() async {
        XCTAssertFalse(GameVersionHelper.isAprilFoolVersion(id: "23w33a", type: "snapshot"))
    }

    /// 而 `15w14a` **同时在**愚人节列表与周快照格式里 —— 列表检查在前 ⇒ **true**。
    /// 这条用来固定「两个格式守卫都不该被误读成充分条件」。
    func testListMembershipWinsOverWeeklySnapshotFormat() async {
        XCTAssertTrue(GameVersionHelper.aprilFoolVersions.contains("15w14a"), "前提：15w14a 是列表成员")
        XCTAssertTrue(GameVersionHelper.isAprilFoolVersion(id: "15w14a", type: "snapshot"),
                      "列表命中先于周快照格式守卫 ⇒ 仍判愚人节")
    }

    /// 没有字母的 id（如 `1.20` / `1.20.1`）⇒ false
    func testVersionWithoutLettersIsNotAprilFool() async {
        XCTAssertFalse(GameVersionHelper.isAprilFoolVersion(id: "1.20", type: "snapshot"))
        XCTAssertFalse(GameVersionHelper.isAprilFoolVersion(id: "1.20.1", type: "snapshot"))
    }

    /// `-pre` / `-rc` 结尾 ⇒ false（预告与候选版不是愚人节）
    func testPreAndReleaseCandidateAreNotAprilFool() async {
        XCTAssertFalse(GameVersionHelper.isAprilFoolVersion(id: "1.21-pre1", type: "snapshot"))
        XCTAssertFalse(GameVersionHelper.isAprilFoolVersion(id: "1.21-rc1", type: "snapshot"))
    }

    /// 含字母、非 pre/rc、非已知格式的快照 ⇒ 落到「兜底 true」
    func testUnknownSnapshotWithLettersFallsThroughToTrue() async {
        XCTAssertTrue(GameVersionHelper.isAprilFoolVersion(id: "1.20.5-somethingweird", type: "snapshot"),
                      "含字母且非 pre/rc 的快照走兜底 true（实现事实）")
    }
}
