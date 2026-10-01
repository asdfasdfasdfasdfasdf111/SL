//
//  VersionFilterUseCaseTests.swift
//  qwqTests
//
//  覆盖 `Features/Game/Module/VersionFilterUseCase.swift`（版本三分桶规则的唯一实现处）。
//
//  **为什么值得测**：这是「正式版 / 测试版 / 远古版」分类的**唯一规则来源**
//  （既有 `GameVersionFilter.filteredIDs` 已改为它的适配器，分类列表与详情页共用）。
//  规则本身有两条**必须逐字对齐**的细节：
//
//  1. **测试版排除愚人节**（愚人节归远古版）—— 注释原话：「`type == "snapshot"` 或 `"pending"`，
//     且不是愚人节版本（愚人节归远古版）」；
//  2. **远古版包含全部愚人节版本**（不论其清单 type 是什么）。
//
//  另一条**反直觉且被注释特别强调**的契约：`filter(_:subCategory: nil)` 返回**空列表**，
//  「与既有 `GameVersionFilter` 的 `.none` 分支一致，**调用方不得把它当作「不过滤」**。
//  需要全部版本请用 `.all`」。这条最容易被"顺手改成返回全部"，故单独钉死。
//

import XCTest
@testable import qwq

final class VersionFilterUseCaseTests: XCTestCase {

    private let useCase = VersionFilterUseCase()

    private func info(_ id: String, type: String) -> MinecraftVersionInfo {
        MinecraftVersionInfo(manifestEntry: ["id": id, "type": type])!
    }

    /// 覆盖全部分支的样本集
    private var sample: [MinecraftVersionInfo] {
        [
            info("1.20.1", type: "release"),        // 正式版
            info("1.20.2-pre1", type: "pre-release"), // 未归入三分桶（kind == .prerelease）
            info("1.21-rc1", type: "rc"),           // 同上（.rc）
            info("24w14potato", type: "snapshot"),  // 快照 + 愚人节 ⇒ 归远古版
            info("23w33a", type: "snapshot"),       // 普通快照 ⇒ 测试版
            info("26.3-snapshot-7", type: "snapshot"), // 新版命名快照 ⇒ 测试版
            info("1.20.5-pending", type: "pending"),   // pending ⇒ 测试版
            info("a1.2.6", type: "old_alpha"),      // 远古版
            info("b1.7.3", type: "old_beta"),       // 远古版
            info("weird-version", type: "totally-unknown"), // kind == nil ⇒ 只出现在 .all
        ]
    }

    private func ids(_ list: [MinecraftVersionInfo]) -> [String] { list.map(\.id) }

    // MARK: - .all

    /// `.all` 原样返回（**保持输入顺序**）
    func testAllReturnsEverythingInInputOrder() async {
        let input = sample
        XCTAssertEqual(ids(useCase.filter(input, into: .all)), ids(input))
    }

    /// `kind == nil`（未识别 type）的条目**只**出现在 `.all` 中
    func testUnrecognizedKindAppearsOnlyInAll() async {
        let input = sample
        for category in [VersionCatalogCategory.release, .snapshot, .ancient] {
            XCTAssertFalse(ids(useCase.filter(input, into: category)).contains("weird-version"),
                           "未识别 type 不应落入 \(category)")
        }
        XCTAssertTrue(ids(useCase.filter(input, into: .all)).contains("weird-version"))
    }

    // MARK: - 正式版

    func testReleaseBucket() async {
        XCTAssertEqual(ids(useCase.filter(sample, into: .release)), ["1.20.1"])
    }

    /// `pre-release` / `rc` **不**归正式版（它们有各自的 kind，不进三分桶）
    func testPreReleaseAndRCAreNotInReleaseBucket() async {
        let got = ids(useCase.filter(sample, into: .release))
        XCTAssertFalse(got.contains("1.20.2-pre1"))
        XCTAssertFalse(got.contains("1.21-rc1"))
    }

    // MARK: - 测试版（快照）

    /// `snapshot` 与 `pending` 都算测试版；愚人节快照**被排除**
    func testSnapshotBucketIncludesSnapshotAndPendingButExcludesAprilFool() async {
        let got = ids(useCase.filter(sample, into: .snapshot))
        XCTAssertTrue(got.contains("23w33a"), "普通周快照属于测试版")
        XCTAssertTrue(got.contains("26.3-snapshot-7"), "新版命名快照属于测试版")
        XCTAssertTrue(got.contains("1.20.5-pending"), "pending 属于测试版")
        XCTAssertFalse(got.contains("24w14potato"), "愚人节版本必须排除出测试版")
    }

    // MARK: - 远古版

    /// `old_alpha` / `old_beta` + **全部愚人节版本**（不论清单 type）
    func testAncientBucketIncludesAlphaBetaAndAllAprilFools() async {
        let got = ids(useCase.filter(sample, into: .ancient))
        XCTAssertTrue(got.contains("a1.2.6"))
        XCTAssertTrue(got.contains("b1.7.3"))
        XCTAssertTrue(got.contains("24w14potato"), "愚人节版本归远古版")
    }

    /// **同一愚人节版本不得同时出现在两个桶里**（分桶是互斥的）
    func testAprilFoolVersionIsOnlyInAncient() async {
        let snapshotIDs = ids(useCase.filter(sample, into: .snapshot))
        let ancientIDs = ids(useCase.filter(sample, into: .ancient))
        XCTAssertTrue(ancientIDs.contains("24w14potato"))
        XCTAssertFalse(snapshotIDs.contains("24w14potato"))
    }

    /// 三个桶 + 未识别类型 = 全体（逐条只落一处）
    func testBucketsAreDisjointAndCoverTheRest() async {
        let buckets = [VersionCatalogCategory.release, .snapshot, .ancient]
            .map { Set(ids(useCase.filter(sample, into: $0))) }
        let union = buckets.reduce(into: Set<String>()) { $0.formUnion($1) }
        for i in 0..<buckets.count {
            for j in (i + 1)..<buckets.count {
                XCTAssertTrue(buckets[i].isDisjoint(with: buckets[j]),
                              "第 \(i) 与第 \(j) 个桶必须互斥")
            }
        }
        // 未进任何桶的只剩 kind == nil 与 prerelease/rc
        let notBucketed = Set(ids(sample)).subtracting(union)
        XCTAssertEqual(notBucketed, ["1.20.2-pre1", "1.21-rc1", "weird-version"])
    }

    // MARK: - 保持顺序

    /// 过滤**保持输入顺序**（注释明说），不重排
    func testFilteringPreservesInputOrder() async {
        let input = [info("b1.7.3", type: "old_beta"), info("a1.2.6", type: "old_alpha")]
        XCTAssertEqual(ids(useCase.filter(input, into: .ancient)), ["b1.7.3", "a1.2.6"])
    }

    /// 空输入 ⇒ 空输出（每个桶）
    func testEmptyInputYieldsEmptyForEveryBucket() async {
        for category in VersionCatalogCategory.allCases {
            XCTAssertTrue(useCase.filter([], into: category).isEmpty)
        }
    }

    // MARK: - subCategory 版重载

    /// ⚠️ **注释特别强调**：`nil` 返回**空列表**，**不得**被当作「不过滤」
    func testNilSubCategoryReturnsEmptyNotEverything() async {
        XCTAssertTrue(useCase.filter(sample, subCategory: nil).isEmpty,
                      "nil 表示「未选中子分类」⇒ 空列表；要全部版本请用 .all")
        XCTAssertTrue(useCase.ids(sample, subCategory: nil).isEmpty)
    }

    /// 三个子分类各自映射到对应桶
    func testSubCategoryMapping() async {
        XCTAssertEqual(ids(useCase.filter(sample, subCategory: .release)),
                       ids(useCase.filter(sample, into: .release)))
        XCTAssertEqual(ids(useCase.filter(sample, subCategory: .snapshot)),
                       ids(useCase.filter(sample, into: .snapshot)))
        XCTAssertEqual(ids(useCase.filter(sample, subCategory: .ancient)),
                       ids(useCase.filter(sample, into: .ancient)))
    }

    // MARK: - VersionCatalogCategory 自身

    /// `.all` 没有对应的侧边栏条目（`subCategory` 为 nil）；其余三个一一对应
    func testCategorySubCategoryMapping() async {
        XCTAssertNil(VersionCatalogCategory.all.subCategory, ".all 不是侧边栏条目")
        XCTAssertEqual(VersionCatalogCategory.release.subCategory, .release)
        XCTAssertEqual(VersionCatalogCategory.snapshot.subCategory, .snapshot)
        XCTAssertEqual(VersionCatalogCategory.ancient.subCategory, .ancient)
    }

    /// `init(subCategory:)` 与 `subCategory` 互逆
    func testSubCategoryRoundTrip() async {
        for category in VersionCatalogCategory.allCases {
            XCTAssertEqual(VersionCatalogCategory(subCategory: category.subCategory), category,
                           "\(category) 往返不一致")
        }
        XCTAssertEqual(VersionCatalogCategory(subCategory: nil), .all, "nil ⇒ .all")
    }

    /// `.all` 的 rawValue 是「全部版本」（中文，同时作 id）
    func testCategoryRawValues() async {
        XCTAssertEqual(VersionCatalogCategory.release.rawValue, "正式版")
        XCTAssertEqual(VersionCatalogCategory.snapshot.rawValue, "测试版")
        XCTAssertEqual(VersionCatalogCategory.ancient.rawValue, "远古版")
        XCTAssertEqual(VersionCatalogCategory.all.rawValue, "全部版本")
        for c in VersionCatalogCategory.allCases {
            XCTAssertEqual(c.id, c.rawValue)
        }
    }

    // MARK: - ids

    /// `ids` 等价于「过滤后取版本号」
    func testIDsMirrorsFilteredVersions() async {
        XCTAssertEqual(useCase.ids(sample, subCategory: .release),
                       useCase.filter(sample, subCategory: .release).map(\.id))
    }
}
