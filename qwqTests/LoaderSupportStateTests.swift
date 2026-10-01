//
//  LoaderSupportStateTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/Mod/Loader/LoaderSupportState.swift`
//  （`LoaderState` / `LoaderSupportChecker.LoaderSupportResult`）。
//
//  **为什么值得测**：`LoaderSupportResult` 的**三态区分是缓存正确性的前提** ——
//  源码逐条写明了为什么不能合并：
//
//  - `.supported([String])`：明确检测到这些加载器
//  - `.notSupported`：API **明确返回**「该版本无此加载器」（404/410/空数组）→ **可缓存空结果**
//  - `.unavailable`：结果**未知**（网络失败 / 5xx / 超时）→ **不得写入缓存**，
//    UI 显示「暂时无法获取」而非「不支持」
//
//  一旦把 `.unavailable` 误判成 `.notSupported`，一次网络抖动就会被**永久缓存**成
//  「这个版本不支持该加载器」—— 用户再也装不上。本文件把三态的边界钉住。
//

import XCTest
@testable import qwq

final class LoaderSupportStateTests: XCTestCase {

    typealias Result = LoaderSupportChecker.LoaderSupportResult

    // MARK: - loaders

    /// `.supported` 返回其携带的列表（**可为空**：那是「检测成功但一个都没支持」）
    func testSupportedReturnsItsLoaders() async {
        XCTAssertEqual(Result.supported(["fabric", "quilt"]).loaders, ["fabric", "quilt"])
    }

    /// `.supported([])` 是合法状态：检测明确成功、但没有任何受支持加载器
    func testSupportedEmptyIsValidAndDistinctFromNotSupported() async {
        let empty = Result.supported([])
        XCTAssertEqual(empty.loaders, [])
        XCTAssertFalse(empty.isUnavailable)
        XCTAssertNotEqual(empty, .notSupported, "「检测成功但为空」与「明确不支持」是两个状态")
    }

    /// `.notSupported` 与 `.unavailable` 的 `loaders` 恒为空
    func testNonSupportedHaveEmptyLoaders() async {
        XCTAssertEqual(Result.notSupported.loaders, [])
        XCTAssertEqual(Result.unavailable.loaders, [])
    }

    // MARK: - isUnavailable

    func testOnlyUnavailableIsUnavailable() async {
        XCTAssertTrue(Result.unavailable.isUnavailable)
        XCTAssertFalse(Result.notSupported.isUnavailable, "明确「不支持」不是「未知」，可缓存")
        XCTAssertFalse(Result.supported([]).isUnavailable)
        XCTAssertFalse(Result.supported(["fabric"]).isUnavailable)
    }

    /// 三态互不相等（缓存判断依赖这一点）
    func testThreeStatesAreDistinct() async {
        XCTAssertNotEqual(Result.notSupported, .unavailable)
        XCTAssertNotEqual(Result.supported([]), .unavailable)
        XCTAssertNotEqual(Result.supported([]), .notSupported)
    }

    /// `.supported` 的相等看**列表内容与顺序**（合成 Equatable）
    func testSupportedEqualityComparesLoaderList() async {
        XCTAssertEqual(Result.supported(["a", "b"]), .supported(["a", "b"]))
        XCTAssertNotEqual(Result.supported(["a", "b"]), .supported(["b", "a"]),
                          "列表顺序参与相等判断")
        XCTAssertNotEqual(Result.supported(["a"]), .supported(["a", "b"]))
    }

    // MARK: - LoaderState（逐卡片渲染状态）

    /// 四个状态齐备且互不相等（UI 按它决定显示什么）
    func testLoaderStateCasesAreDistinct() async {
        let states: [LoaderState] = [.checking, .supported, .notSupported, .unavailable]
        XCTAssertEqual(Set(states.map { "\($0)" }).count, 4)
        XCTAssertNotEqual(LoaderState.checking, .supported)
        XCTAssertNotEqual(LoaderState.supported, .notSupported)
        XCTAssertNotEqual(LoaderState.notSupported, .unavailable)
    }

    /// `LoaderState` 是 `Equatable`（UI 用它做状态比较）
    func testLoaderStateIsEquatable() async {
        XCTAssertEqual(LoaderState.checking, .checking)
        XCTAssertEqual(LoaderState.unavailable, .unavailable)
    }

    /// `LoaderState` 与 `LoaderSupportResult` 是**两层**：前者逐卡片、后者是聚合三态。
    /// 本用例只固定「两者都存在且语义不同」这件事，避免将来被合并成一个类型。
    func testLoaderStateAndResultAreSeparateLayers() async {
        let perCard: LoaderState = .checking
        let aggregate: Result = .unavailable
        XCTAssertNotEqual("\(perCard)", "\(aggregate)", "逐卡片状态与聚合结果不是同一个类型")
    }
}
