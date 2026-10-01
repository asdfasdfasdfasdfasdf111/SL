//
//  LoaderNameResolverTests.swift
//  qwqTests
//
//  覆盖 `Features/ModBrowser/ModLoader.swift`（`displayName` / `assetName`）
//  与 `Features/Download/LoaderNameResolver.swift`（加载器 → UI 资源名）。
//
//  **为什么值得测**：两者都决定**界面上显示什么图标/名字**。错了不崩，
//  只是把 Forge 的牌子挂到 NeoForge 上（或反过来），用户看到的是错的信息。
//  两处都 0 测试触达。
//
//  本文件重点钉住三条**注释点名**的性质：
//  1. `ModLoader` 的 `rawValue` 是**小写**、`assetName` 是**大小写混排**
//     ——「别把其中一个当另一个用」；
//  2. `assetName` **不是单射**：`rift` 与 `unknown` 都映射到 `"fabric"`
//     ——「不能用 assetName 反推加载器类型」；
//  3. `LoaderNameResolver` 的子串模糊匹配里 **`neoforge` 必须排在 `forge` 之前**
//     —— 否则 `"neoforge"` 会先命中 `contains("forge")` 被误判成 `Forge`。
//

import XCTest
@testable import qwq

final class LoaderNameResolverTests: XCTestCase {

    // MARK: - ModLoader.displayName

    func testDisplayNames() async {
        XCTAssertEqual(ModLoader.fabric.displayName, "Fabric")
        XCTAssertEqual(ModLoader.forge.displayName, "Forge")
        XCTAssertEqual(ModLoader.quilt.displayName, "Quilt")
        XCTAssertEqual(ModLoader.neoforge.displayName, "NeoForge")
        XCTAssertEqual(ModLoader.rift.displayName, "Rift")
        XCTAssertEqual(ModLoader.unknown.displayName, "Unknown")
    }

    // MARK: - ModLoader.assetName

    func testAssetNames() async {
        XCTAssertEqual(ModLoader.fabric.assetName, "fabric")
        XCTAssertEqual(ModLoader.forge.assetName, "Forge")
        XCTAssertEqual(ModLoader.quilt.assetName, "Quilt")
        XCTAssertEqual(ModLoader.neoforge.assetName, "NeoForged", "注意是 NeoForged（带 d），不是 NeoForge")
    }

    /// 两处**刻意的不一致**：`rift` 与 `unknown` 都借用 Fabric 的图标
    func testAssetNameDeliberateFallbacksToFabric() async {
        XCTAssertEqual(ModLoader.rift.assetName, "fabric", "Rift 已停维护，借 Fabric 图标")
        XCTAssertEqual(ModLoader.unknown.assetName, "fabric", "unknown 回落成中性图标")
    }

    /// `assetName` **不是单射** ⇒ 不能用它反推加载器类型（注释明说）
    func testAssetNameIsNotInjective() async {
        let fabricLike = ModLoader.allCases.filter { $0.assetName == "fabric" }
        XCTAssertEqual(Set(fabricLike), [.fabric, .rift, .unknown],
                       "三个加载器共用同一资源名，故 assetName 无法反推类型")
    }

    /// `rawValue` 全小写（与 Modrinth 接口对齐），而 `assetName` 有大小写混排
    func testRawValueIsLowercaseWhileAssetNameIsMixedCase() async {
        for loader in ModLoader.allCases {
            XCTAssertEqual(loader.rawValue, loader.rawValue.lowercased(),
                           "\(loader) 的 rawValue 必须全小写")
        }
        XCTAssertEqual(ModLoader.forge.rawValue, "forge")
        XCTAssertEqual(ModLoader.forge.assetName, "Forge")
        XCTAssertEqual(ModLoader.neoforge.rawValue, "neoforge")
        XCTAssertEqual(ModLoader.neoforge.assetName, "NeoForged")
    }

    /// `rawValue` 往返
    func testRawValueRoundTrip() async {
        for loader in ModLoader.allCases {
            XCTAssertEqual(ModLoader(rawValue: loader.rawValue), loader)
        }
        XCTAssertNil(ModLoader(rawValue: "Forge"), "大写拼写不是合法 rawValue（rawValue 全小写）")
    }

    func testAllCasesCount() async {
        XCTAssertEqual(ModLoader.allCases.count, 6)
    }

    // MARK: - LoaderNameResolver.assetName(for:)

    func testAssetNameLookupIsCaseInsensitive() async {
        XCTAssertEqual(LoaderNameResolver.assetName(for: "fabric"), "fabric")
        XCTAssertEqual(LoaderNameResolver.assetName(for: "FORGE"), "Forge")
        XCTAssertEqual(LoaderNameResolver.assetName(for: "NeoForge"), "NeoForged")
        XCTAssertEqual(LoaderNameResolver.assetName(for: "neoforged"), "NeoForged")
        XCTAssertEqual(LoaderNameResolver.assetName(for: "Quilt"), "Quilt")
    }

    /// 未知 key 回退 `"fabric"`（与 `ModLoader.unknown` 同口径）
    func testAssetNameFallsBackToFabricForUnknownKey() async {
        XCTAssertEqual(LoaderNameResolver.assetName(for: "liteloader"), "fabric")
        XCTAssertEqual(LoaderNameResolver.assetName(for: ""), "fabric")
    }

    /// `rift` 在映射表里指向 `"fabric"`
    func testRiftMapsToFabric() async {
        XCTAssertEqual(LoaderNameResolver.assetName(for: "rift"), "fabric")
    }

    // MARK: - LoaderNameResolver.name(forVersion:localLoaders:fallback:)

    /// 优先级 1：本地扫描结果
    func testLocalDetectionTakesPriorityOverVersionString() async {
        let result = LoaderNameResolver.name(forVersion: "1.20.1-forge",
                                             localLoaders: ["1.20.1-forge": .quilt],
                                             fallback: "fabric")
        XCTAssertEqual(result, "Quilt", "本地扫描结果优先于版本字符串后缀")
    }

    /// 版本字符串后缀（`1.20.1-Forge`）—— 大小写不敏感
    func testVersionSuffixIsParsed() async {
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "1.20.1-Forge", localLoaders: [:], fallback: ""),
                       "Forge")
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "1.20.1-fabric", localLoaders: [:], fallback: ""),
                       "fabric")
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "1.20.1-neoforged", localLoaders: [:], fallback: ""),
                       "NeoForged")
    }

    /// 带多段后缀的真实版本名（`26.3-snapshot-3-Fabric`）
    func testMultiSegmentSuffix() async {
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "26.3-snapshot-3-Fabric",
                                               localLoaders: [:], fallback: ""),
                       "fabric")
    }

    /// 后缀扫描是**从后往前** ⇒ 多个可识别段时，**最后**那个胜出
    func testLastRecognizableSuffixWins() async {
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "1.0-forge-fabric",
                                               localLoaders: [:], fallback: ""),
                       "fabric", "从后往前扫描，末段 fabric 覆盖前段 forge")
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "1.0-fabric-forge",
                                               localLoaders: [:], fallback: ""),
                       "Forge")
    }

    /// **注释点名的顺序陷阱**：子串匹配里 `neoforge` 必须先于 `forge`
    /// —— 否则 `"neoforge"` 会先命中 `contains("forge")` 被误判成 `Forge`。
    func testSubstringMatchChecksNeoForgeBeforeForge() async {
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "mybuildneoforge",
                                               localLoaders: [:], fallback: ""),
                       "NeoForged",
                       "含 neoforge 的串必须先命中 NeoForged，不能被 forge 抢先")
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "mybuildneoforged",
                                               localLoaders: [:], fallback: ""),
                       "NeoForged")
    }

    /// 子串模糊匹配（无连字符时也能认出）
    func testSubstringFuzzyMatch() async {
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "somethingforge", localLoaders: [:], fallback: ""),
                       "Forge")
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "myquiltbuild", localLoaders: [:], fallback: ""),
                       "Quilt")
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "xxfabricxx", localLoaders: [:], fallback: ""),
                       "fabric")
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "riftloader", localLoaders: [:], fallback: ""),
                       "fabric", "rift 的子串也回落到 fabric")
    }

    /// 完全认不出 ⇒ 回退用户选择的 loader
    func testFallsBackToProvidedLoader() async {
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "1.20.1", localLoaders: [:], fallback: "Forge"),
                       "Forge")
    }

    /// 回退值为空 ⇒ 兜底 `"fabric"`（而不是空串）
    func testEmptyFallbackBecomesFabric() async {
        XCTAssertEqual(LoaderNameResolver.name(forVersion: "1.20.1", localLoaders: [:], fallback: ""),
                       "fabric")
    }

    /// 本地扫描命中的 `ModLoader` 走它自己的 `assetName`
    /// ⇒ `rift` / `unknown` 在这里也表现为 `"fabric"`
    func testLocalRiftAndUnknownBothResolveToFabric() async {
        for loader in [ModLoader.rift, .unknown] {
            XCTAssertEqual(LoaderNameResolver.name(forVersion: "v", localLoaders: ["v": loader], fallback: ""),
                           "fabric", "\(loader) 的 assetName 是 fabric")
        }
    }
}
