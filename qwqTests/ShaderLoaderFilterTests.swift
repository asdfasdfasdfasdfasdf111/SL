//
//  ShaderLoaderFilterTests.swift
//  qwqTests
//
//  覆盖 `Features/Download/ShaderLoaderFilter.swift`（光影详情页的加载器展示过滤）。
//
//  **为什么值得测**：它决定光影详情页**显示哪几个加载器标签**。两条实现事实需要固定：
//
//  1. 去重走 `Array(Set(projectLoaders.map { $0.lowercased() }))` ⇒ 结果**顺序不确定**
//     （`Set` 无序遍历）。因此本文件的断言一律比**集合**而非数组顺序 ——
//     若将来有人把界面顺序当契约，必须先改实现；
//  2. 光影页在白名单过滤后**若为空则回退**默认列表 `["iris", "optifine"]`
//     —— 注意这个默认值是**硬编码**的，与该文件的 `shaderOnlyLoaders` 内容必须一致。
//

import XCTest
@testable import qwq

final class ShaderLoaderFilterTests: XCTestCase {

    // MARK: - 非光影页

    /// 非光影页：返回项目声明的加载器（小写化后去重），不做白名单过滤
    func testNonShaderPageReturnsDeclaredLoadersLowercased() async {
        let result = ShaderLoaderFilter.filtered(projectLoaders: ["Fabric", "Forge"],
                                                 pageType: .mod)
        XCTAssertEqual(Set(result), ["fabric", "forge"])
    }

    /// 去重：大小写不同视为同一个
    func testNonShaderPageDeduplicatesCaseInsensitively() async {
        let result = ShaderLoaderFilter.filtered(projectLoaders: ["Fabric", "fabric", "FABRIC"],
                                                 pageType: .mod)
        XCTAssertEqual(result, ["fabric"], "去重后只剩一个（已小写）")
    }

    /// 非光影页且项目未声明加载器 ⇒ 空数组（**不**走光影的默认回退）
    func testNonShaderPageWithNoLoadersReturnsEmpty() async {
        for page in [DetailPageType.mod, .resourcePack, .modpack, .loaderSelector] {
            XCTAssertTrue(ShaderLoaderFilter.filtered(projectLoaders: [], pageType: page).isEmpty,
                          "\(page) 未声明加载器时应为空，不得回退")
        }
    }

    /// ⚠️ 结果来自 `Set` 遍历 ⇒ **顺序不确定**。本用例只断言集合相等，
    /// 顺便把「顺序不可依赖」这件事写进断言消息。
    func testLoaderOrderIsNotGuaranteed() async {
        let result = ShaderLoaderFilter.filtered(projectLoaders: ["Fabric", "Forge", "Quilt", "NeoForge"],
                                                 pageType: .mod)
        XCTAssertEqual(Set(result), ["fabric", "forge", "quilt", "neoforge"])
        XCTAssertEqual(result.count, 4, "顺序由 Set 遍历决定，不可作为契约")
    }

    // MARK: - 光影页

    /// 光影页：只保留白名单内的加载器
    func testShaderPageKeepsOnlyWhitelistedLoaders() async {
        let result = ShaderLoaderFilter.filtered(projectLoaders: ["iris", "fabric", "forge"],
                                                 pageType: .shader)
        XCTAssertEqual(result, ["iris"], "fabric / forge 属模组加载器，在光影页被过滤")
    }

    /// 白名单是 `iris` 与 `optifine`（小写）
    func testShaderOnlyLoadersWhitelist() async {
        XCTAssertEqual(ShaderLoaderFilter.shaderOnlyLoaders, ["iris", "optifine"])
    }

    /// 大小写不敏感：`Iris` / `OptiFine` 同样命中白名单（比较前 `lowercased()`）
    func testWhitelistMatchingIsCaseInsensitive() async {
        let result = ShaderLoaderFilter.filtered(projectLoaders: ["Iris", "OptiFine"],
                                                 pageType: .shader)
        XCTAssertEqual(Set(result), ["iris", "optifine"])
    }

    /// 项目声明的光影加载器**全部**被过滤掉 ⇒ 回退默认列表
    func testShaderPageFallsBackWhenNoWhitelistedLoaderSurvives() async {
        let result = ShaderLoaderFilter.filtered(projectLoaders: ["fabric", "forge"],
                                                 pageType: .shader)
        XCTAssertEqual(result, ["iris", "optifine"], "没有任何光影加载器时回退默认列表")
    }

    /// 项目一个加载器都没声明 ⇒ 同样回退默认列表
    func testShaderPageFallsBackWhenProjectDeclaresNothing() async {
        let result = ShaderLoaderFilter.filtered(projectLoaders: [], pageType: .shader)
        XCTAssertEqual(result, ["iris", "optifine"])
    }

    /// 回退列表的取值必须与白名单**同集合**（一个是硬编码数组、一个是 Set，
    /// 分开维护就有漂移风险）
    func testFallbackListMatchesWhitelist() async {
        let fallback = ShaderLoaderFilter.filtered(projectLoaders: [], pageType: .shader)
        XCTAssertEqual(Set(fallback), ShaderLoaderFilter.shaderOnlyLoaders,
                       "回退列表与白名单必须同集合，否则光影页会显示白名单外的加载器")
    }

    /// 回退列表顺序是**确定的**硬编码顺序（与上一条的「Set 顺序不定」形成对照）
    func testFallbackListHasDeterministicOrder() async {
        XCTAssertEqual(ShaderLoaderFilter.filtered(projectLoaders: [], pageType: .shader),
                       ["iris", "optifine"],
                       "回退值是写死的数组字面量，顺序确定")
    }

    /// 只有一个命中也保留（不回退）
    func testShaderPageKeepsSingleWhitelistedLoader() async {
        let result = ShaderLoaderFilter.filtered(projectLoaders: ["optifine"], pageType: .shader)
        XCTAssertEqual(result, ["optifine"])
    }
}
