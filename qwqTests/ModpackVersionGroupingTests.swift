//
//  ModpackVersionGroupingTests.swift
//  qwqTests
//
//  覆盖 `Features/Download/ModpackVersionGrouping.swift`（整合包版本按游戏版本去重）。
//
//  **为什么值得测**：它决定整合包详情页**显示哪些版本**。源码注释自列了两条
//  「与字面描述不完全一致」的事实，本文件逐条钉住：
//
//  1. 只用 `game_versions.first` 当键 —— 一个包版本若声明多个游戏版本，
//     除第一个之外的版本**不会**单独出现（于是某些游戏版本在列表里根本没有对应项）；
//  2. 排序降序由 `GameVersionHelper.compare` 判定，**不是字符串比较**
//     （字符串排序会把 1.10 排在 1.9 前面）。
//
//  另有一条注释点名的事实：返回的是**视图而非副本** —— 结果里的 `ModpackVersion`
//  与入参是同一批对象引用。
//

import XCTest
@testable import qwq

final class ModpackVersionGroupingTests: XCTestCase {

    private func version(_ id: String,
                         gameVersions: [String],
                         name: String = "v") -> ModpackVersion {
        ModpackVersion(id: id,
                       name: name,
                       version_number: id,
                       game_versions: gameVersions,
                       loaders: ["fabric"],
                       files: [])
    }

    private func ids(_ result: [(gameVersion: String, version: ModpackVersion)]) -> [String] {
        result.map(\.version.id)
    }

    // MARK: - 去重语义

    /// 同一游戏版本出现多次 ⇒ 只保留**第一次出现**的那个包版本
    func testKeepsFirstOccurrencePerGameVersion() async {
        let result = ModpackVersionGrouping.uniqueGameVersions([
            version("first", gameVersions: ["1.20.1"]),
            version("second", gameVersions: ["1.20.1"]),
            version("third", gameVersions: ["1.20.1"]),
        ])
        XCTAssertEqual(ids(result), ["first"])
    }

    /// 不同游戏版本各自保留
    func testDistinctGameVersionsAreAllKept() async {
        let result = ModpackVersionGrouping.uniqueGameVersions([
            version("a", gameVersions: ["1.20.1"]),
            version("b", gameVersions: ["1.19.2"]),
            version("c", gameVersions: ["1.16.5"]),
        ])
        XCTAssertEqual(Set(ids(result)), ["a", "b", "c"])
    }

    /// **注释点名的事实 1**：只用 `game_versions.first` 当键 ⇒
    /// 一个包版本声明多个游戏版本时，只有第一个会出现在结果里
    func testOnlyFirstGameVersionIsUsedAsKey() async {
        let result = ModpackVersionGrouping.uniqueGameVersions([
            version("multi", gameVersions: ["1.20.1", "1.19.2", "1.18.2"]),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.gameVersion, "1.20.1")
        XCTAssertFalse(result.contains { $0.gameVersion == "1.19.2" },
                       "第二个及之后的游戏版本不会单独出现（已知事实）")
    }

    /// `game_versions` 为空 ⇒ 该项被**整条跳过**（`if let gv = v.game_versions.first`）
    func testEntryWithoutGameVersionsIsSkipped() async {
        let result = ModpackVersionGrouping.uniqueGameVersions([
            version("no-versions", gameVersions: []),
            version("ok", gameVersions: ["1.20.1"]),
        ])
        XCTAssertEqual(ids(result), ["ok"])
    }

    /// 空输入 ⇒ 空输出
    func testEmptyInputYieldsEmptyOutput() async {
        XCTAssertTrue(ModpackVersionGrouping.uniqueGameVersions([]).isEmpty)
    }

    // MARK: - 排序

    /// **注释点名的事实 2**：降序用的是 `GameVersionHelper.compare`（数值段比较），
    /// 所以 `1.10` 排在 `1.9` **前面** —— 字符串排序会排反。
    func testSortingIsSemanticNotLexicographic() async {
        let result = ModpackVersionGrouping.uniqueGameVersions([
            version("v19", gameVersions: ["1.9"]),
            version("v110", gameVersions: ["1.10"]),
            version("v1201", gameVersions: ["1.20.1"]),
        ])
        XCTAssertEqual(result.map(\.gameVersion), ["1.20.1", "1.10", "1.9"])
    }

    /// 缺位按 0 补 ⇒ `1.20` 与 `1.20.0` 会被 `compare` 判等。
    /// 但去重键是**原字符串**（`seen` 是 `Set<String>`），所以两者各自成为一组，
    /// 且相对顺序由排序的稳定性以外的因素决定 —— 这里只钉「两条都在」。
    func testEqualByCompareButDifferentStringsBothSurvive() async {
        let result = ModpackVersionGrouping.uniqueGameVersions([
            version("a", gameVersions: ["1.20"]),
            version("b", gameVersions: ["1.20.0"]),
        ])
        XCTAssertEqual(Set(result.map(\.gameVersion)), ["1.20", "1.20.0"],
                       "去重键是原字符串，故 compare 判等的两者仍各自成组")
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - 视图而非副本

    /// 注释点名：返回结果里的 `ModpackVersion` 与入参是**同一批对象引用**。
    /// `ModpackVersion` 是 `struct`，所以「同一引用」的可观测形式是
    /// **取出的元素与入参数组里的元素全等**（值相等即满足 `Equatable` 合成语义）。
    func testResultElementsMatchInputElements() async {
        let input = [
            version("a", gameVersions: ["1.20.1"], name: "A"),
            version("b", gameVersions: ["1.19.2"], name: "B"),
        ]
        let result = ModpackVersionGrouping.uniqueGameVersions(input)
        for (gv, v) in result {
            XCTAssertTrue(input.contains { $0.id == v.id && $0.game_versions.first == gv },
                          "结果里的包版本必须来自入参，不得凭空构造")
        }
    }
}
