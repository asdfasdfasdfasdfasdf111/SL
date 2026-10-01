//
//  DetailVersionDecisionTests.swift
//  qwqTests
//
//  覆盖 `Features/Game/DetailVersionDecision.swift`（详情页「默认选中哪个版本」的完整规则）。
//
//  **为什么值得测**：这段规则是为修一个**真实 UI 错乱**抽出来的 —— 源码注释记录了症状：
//  「标题是 1.7.2、加载器却显示当前实例版本 26.2 的 4 张卡片」
//  （根因：26.2 缓存命中 Fabric/Forge/NeoForged/Quilt，而 1.7.2 只有 Forge）。
//  规则本身分支多、且有「**故意回退到 nil**」这种反直觉设计，抽成纯函数后正好逐条钉住。
//
//  两处最容易被「顺手优化」掉的设计（本文件专门守住）：
//  1. `initialSelection` 在游戏版本页且 `itemName` 不在列表时**返回 nil**，
//     **不**回退到 `instanceVersion` —— 否则会重演上面那个错乱；
//  2. `resolveAfterManifest` 在两个函数里都可能返回 **nil 表示「不覆盖现有选择」**，
//     调用方据此**不改**当前选中项；返回非 nil 才去改。
//

import XCTest
@testable import qwq

final class DetailVersionDecisionTests: XCTestCase {

    private let versions = ["26.2", "1.21.1", "1.20.1", "1.7.2"]

    // MARK: - initialSelection：游戏版本页

    /// 游戏版本页：必须选中用户点击的版本（`itemName`）
    func testLoaderSelectorInitialPicksItemName() async {
        XCTAssertEqual(DetailVersionDecision.initialSelection(
            pageType: .loaderSelector, itemName: "1.7.2",
            sortedVersions: versions, instanceVersion: "26.2"), "1.7.2")
    }

    /// ⚠️ **核心反直觉分支**：`itemName` 不在列表时返回 **nil**，**不得**回退到 `instanceVersion`。
    /// 这正是「标题 1.7.2 却显示 26.2 的 4 张卡片」的修法。
    func testLoaderSelectorInitialReturnsNilWhenItemNameMissing() async {
        XCTAssertNil(DetailVersionDecision.initialSelection(
            pageType: .loaderSelector, itemName: "1.7.2",
            sortedVersions: ["26.2"], instanceVersion: "26.2"),
            "itemName 不在列表时应返回 nil 等待 manifest，而不是误选 instanceVersion")
    }

    /// 游戏版本页：列表为空也返回 nil
    func testLoaderSelectorInitialWithEmptyListReturnsNil() async {
        XCTAssertNil(DetailVersionDecision.initialSelection(
            pageType: .loaderSelector, itemName: "1.7.2",
            sortedVersions: [], instanceVersion: "26.2"))
    }

    // MARK: - initialSelection：其他页面

    /// 其他页面：优先当前实例版本
    func testNonLoaderInitialPrefersInstanceVersion() async {
        for page in [DetailPageType.resourcePack, .mod, .shader, .modpack] {
            XCTAssertEqual(DetailVersionDecision.initialSelection(
                pageType: page, itemName: "1.7.2",
                sortedVersions: versions, instanceVersion: "1.20.1"), "1.20.1",
                "\(page) 应优先 instanceVersion")
        }
    }

    /// 其他页面：实例版本不在列表 ⇒ 回退列表首位
    func testNonLoaderInitialFallsBackToFirstWhenInstanceVersionMissing() async {
        XCTAssertEqual(DetailVersionDecision.initialSelection(
            pageType: .mod, itemName: "1.7.2",
            sortedVersions: versions, instanceVersion: "1.99.99"), "26.2")
    }

    /// 其他页面：实例版本为 nil ⇒ 回退列表首位
    func testNonLoaderInitialFallsBackToFirstWhenInstanceVersionNil() async {
        XCTAssertEqual(DetailVersionDecision.initialSelection(
            pageType: .mod, itemName: "1.7.2",
            sortedVersions: versions, instanceVersion: nil), "26.2")
    }

    /// 其他页面：列表为空 ⇒ `sortedVersions.first` 为 nil
    func testNonLoaderInitialWithEmptyListReturnsNil() async {
        XCTAssertNil(DetailVersionDecision.initialSelection(
            pageType: .mod, itemName: "1.7.2",
            sortedVersions: [], instanceVersion: "26.2"))
    }

    /// 其他页面**不看 `itemName`**：即使 itemName 在列表里也仍按 instanceVersion 走
    func testNonLoaderInitialIgnoresItemName() async {
        XCTAssertEqual(DetailVersionDecision.initialSelection(
            pageType: .modpack, itemName: "1.7.2",
            sortedVersions: versions, instanceVersion: "26.2"), "26.2",
            "非游戏版本页不应因 itemName 而改变选择")
    }

    // MARK: - resolveAfterManifest：游戏版本页

    /// 现有选择有效 ⇒ 返回 **nil**（保留，不覆盖 —— 可能是用户手选的）
    func testLoaderSelectorResolveKeepsValidCurrentByReturningNil() async {
        XCTAssertNil(DetailVersionDecision.resolveAfterManifest(
            pageType: .loaderSelector, current: "1.7.2",
            itemName: "1.20.1", sortedVersions: versions),
            "current 有效时必须返回 nil（表示不覆盖）")
    }

    /// 现有选择为空 ⇒ 采用 `itemName`（若在列表）
    func testLoaderSelectorResolveUsesItemNameWhenCurrentEmpty() async {
        XCTAssertEqual(DetailVersionDecision.resolveAfterManifest(
            pageType: .loaderSelector, current: "",
            itemName: "1.7.2", sortedVersions: versions), "1.7.2")
    }

    /// 现有选择不在列表（如 manifest 未就绪时选错）⇒ 改用 `itemName`
    func testLoaderSelectorResolveUsesItemNameWhenCurrentInvalid() async {
        XCTAssertEqual(DetailVersionDecision.resolveAfterManifest(
            pageType: .loaderSelector, current: "9.9.9",
            itemName: "1.7.2", sortedVersions: versions), "1.7.2")
    }

    /// `itemName` 也不在列表 ⇒ 回退列表首位（此处与 `initialSelection` 不同：**允许回退**）
    func testLoaderSelectorResolveFallsBackToFirstWhenBothInvalid() async {
        XCTAssertEqual(DetailVersionDecision.resolveAfterManifest(
            pageType: .loaderSelector, current: "9.9.9",
            itemName: "8.8.8", sortedVersions: versions), "26.2")
    }

    /// 列表为空 ⇒ 回退首位即 nil
    func testLoaderSelectorResolveWithEmptyListReturnsNil() async {
        XCTAssertNil(DetailVersionDecision.resolveAfterManifest(
            pageType: .loaderSelector, current: "9.9.9",
            itemName: "8.8.8", sortedVersions: []))
    }

    // MARK: - resolveAfterManifest：其他页面

    /// 其他页面：现有选择有效 ⇒ nil（不覆盖）
    func testNonLoaderResolveKeepsValidCurrentByReturningNil() async {
        XCTAssertNil(DetailVersionDecision.resolveAfterManifest(
            pageType: .mod, current: "1.20.1",
            itemName: "1.7.2", sortedVersions: versions))
    }

    /// 其他页面：现有选择为空 ⇒ 回退首位
    func testNonLoaderResolveFallsBackWhenCurrentEmpty() async {
        XCTAssertEqual(DetailVersionDecision.resolveAfterManifest(
            pageType: .mod, current: "",
            itemName: "1.7.2", sortedVersions: versions), "26.2")
    }

    /// 其他页面：现有选择不在列表 ⇒ 回退首位
    func testNonLoaderResolveFallsBackWhenCurrentInvalid() async {
        XCTAssertEqual(DetailVersionDecision.resolveAfterManifest(
            pageType: .mod, current: "9.9.9",
            itemName: "1.7.2", sortedVersions: versions), "26.2")
    }

    /// 其他页面**不看 `itemName`**：current 有效时即使 itemName 也在列表里仍返回 nil
    func testNonLoaderResolveIgnoresItemName() async {
        XCTAssertNil(DetailVersionDecision.resolveAfterManifest(
            pageType: .shader, current: "1.7.2",
            itemName: "26.2", sortedVersions: versions))
    }

    /// 其他页面 + 空列表 ⇒ nil
    func testNonLoaderResolveWithEmptyListReturnsNil() async {
        XCTAssertNil(DetailVersionDecision.resolveAfterManifest(
            pageType: .modpack, current: "", itemName: "x", sortedVersions: []))
    }

    // MARK: - 两个函数的共同契约：nil 的两种含义要分清

    /// `initialSelection` 的 nil 含义是「**暂时不决定**」（等 manifest）；
    /// `resolveAfterManifest` 的 nil 含义是「**保持现状**」。
    /// 本用例把这两条语义并排钉住，避免将来有人把其中一个「修成」非 nil。
    func testNilHasDifferentMeaningInEachFunction() async {
        // initialSelection：itemName 缺失 ⇒ nil（不决定）
        XCTAssertNil(DetailVersionDecision.initialSelection(
            pageType: .loaderSelector, itemName: "missing",
            sortedVersions: versions, instanceVersion: "26.2"))

        // resolveAfterManifest：current 有效 ⇒ nil（保持现状）
        XCTAssertNil(DetailVersionDecision.resolveAfterManifest(
            pageType: .loaderSelector, current: "26.2",
            itemName: "missing", sortedVersions: versions))
    }
}
