//
//  GameVersionFilterTests.swift
//  qwqTests
//
//  覆盖 `Features/Game/GameVersionFilter.swift`（`[[String: Any]]` → id 列表的适配器）。
//
//  **为什么值得测**：它是 `VersionFilterUseCase`（规则唯一实现处）的**形态转换层** ——
//  分类列表与详情页都经它取 id。规则本身已在 `VersionFilterUseCaseTests` 覆盖，
//  本文件只钉住**转换层的取舍**，注释逐条写明了：
//  「id 缺失的条目被丢弃、type 缺失等同未识别（不匹配任何分类）、顺序保持输入顺序」。
//
//  ⚠️ 这意味着转换层**会静默丢条目**：清单里少一个 `id`，该版本就从所有分类页消失
//  （但仍在 `.all` 里，若调用方走的是另一条路径）。这类「丢弃」必须显式钉住。
//

import XCTest
@testable import qwq

final class GameVersionFilterTests: XCTestCase {

    private func entry(_ id: String, _ type: String) -> [String: Any] {
        ["id": id, "type": type]
    }

    // MARK: - 三个子分类

    func testReleaseBucket() async {
        let versions = [entry("1.20.1", "release"), entry("23w33a", "snapshot")]
        XCTAssertEqual(GameVersionFilter.filteredIDs(versions, subCategory: .release), ["1.20.1"])
    }

    /// 测试版含标准快照与 pending，**排除愚人节**
    func testSnapshotBucket() async {
        let versions = [
            entry("23w33a", "snapshot"),
            entry("1.20.5-pending", "pending"),
            entry("24w14potato", "snapshot"),   // 愚人节
        ]
        XCTAssertEqual(GameVersionFilter.filteredIDs(versions, subCategory: .snapshot),
                       ["23w33a", "1.20.5-pending"])
    }

    /// 远古版含 old_alpha / old_beta 与**全部愚人节版本**
    func testAncientBucket() async {
        let versions = [
            entry("a1.2.6", "old_alpha"),
            entry("b1.7.3", "old_beta"),
            entry("24w14potato", "snapshot"),   // 愚人节归远古版
        ]
        let got = GameVersionFilter.filteredIDs(versions, subCategory: .ancient)
        XCTAssertEqual(Set(got), ["a1.2.6", "b1.7.3", "24w14potato"])
    }

    // MARK: - 转换层的取舍

    /// ⚠️ **`id` 缺失的条目被静默丢弃**（`compactMap` 语义）
    func testEntriesWithoutIDAreDropped() async {
        let versions: [[String: Any]] = [
            ["type": "release"],                       // 无 id
            ["id": "", "type": "release"],             // 空 id
            ["id": "1.20.1", "type": "release"],       // 正常
        ]
        XCTAssertEqual(GameVersionFilter.filteredIDs(versions, subCategory: .release), ["1.20.1"],
                       "id 缺失或为空的条目被静默丢弃（这是转换层的既定取舍）")
    }

    /// ⚠️ **`type` 缺失等同未识别** ⇒ 不落入任何分类
    func testEntriesWithoutTypeMatchNoCategory() async {
        let versions: [[String: Any]] = [["id": "x"]]
        for sub in [GameSubCategory.release, .snapshot, .ancient] {
            XCTAssertTrue(GameVersionFilter.filteredIDs(versions, subCategory: sub).isEmpty,
                          "type 缺失的条目不应落入 \(sub)")
        }
    }

    /// **保持输入顺序**（注释明说）
    func testOutputPreservesInputOrder() async {
        let versions = [
            entry("1.8", "release"),
            entry("1.12.2", "release"),
            entry("1.7.10", "release"),
        ]
        XCTAssertEqual(GameVersionFilter.filteredIDs(versions, subCategory: .release),
                       ["1.8", "1.12.2", "1.7.10"],
                       "适配器不重排 —— 排序是别处的职责")
    }

    /// `subCategory: nil` ⇒ **空列表**（与 `VersionFilterUseCase` 的契约一致，
    /// 不得被当成「不过滤」）
    func testNilSubCategoryReturnsEmpty() async {
        let versions = [entry("1.20.1", "release")]
        XCTAssertTrue(GameVersionFilter.filteredIDs(versions, subCategory: nil).isEmpty,
                      "nil 表示未选中子分类 ⇒ 空；要全部版本须走别的路径")
    }

    /// 空输入 ⇒ 空输出
    func testEmptyInputYieldsEmpty() async {
        XCTAssertTrue(GameVersionFilter.filteredIDs([], subCategory: .release).isEmpty)
    }

    /// 只返回 **id**（不是完整条目）
    func testReturnsIDsNotEntries() async {
        let versions = [entry("1.20.1", "release")]
        let got = GameVersionFilter.filteredIDs(versions, subCategory: .release)
        XCTAssertEqual(got, ["1.20.1"])
        XCTAssertEqual(got.first, "1.20.1", "元素类型是 String（id），不是字典")
    }

    /// 与 `VersionFilterUseCase` 的口径一致：同一个输入集两条路径结果相同
    /// （适配器存在的意义就是「规则不漂移」）
    func testAdapterAgreesWithUseCase() async {
        let raw = [
            entry("1.20.1", "release"),
            entry("23w33a", "snapshot"),
            entry("24w14potato", "snapshot"),
            entry("a1.2.6", "old_alpha"),
        ]
        let infos = raw.compactMap(MinecraftVersionInfo.init(manifestEntry:))
        let useCase = VersionFilterUseCase()

        for sub in [GameSubCategory.release, .snapshot, .ancient] {
            XCTAssertEqual(GameVersionFilter.filteredIDs(raw, subCategory: sub),
                           useCase.ids(infos, subCategory: sub),
                           "适配器与用例在 \(sub) 上必须给出相同结果")
        }
    }
}
