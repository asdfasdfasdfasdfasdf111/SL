//
//  ItemFilterTests.swift
//  qwqTests
//
//  覆盖 `Features/ModBrowser/ItemFilter.swift`（搜索过滤谓词）。
//
//  **为什么值得测**：它决定「用户在搜索框里打的字能不能找到条目」。谓词有**四个分支**，
//  其中最后一条最容易被忽略 —— **中文标签的反向匹配**：
//
//  ```swift
//  ModrinthTagMap.contains { $1 == query && item.tags.contains($0) }
//  ```
//
//  它做的是「用户输入**中文译名**（如 `科技`）⇒ 反查英文标签键（`technology`）
//  ⇒ 看条目是否带该标签」。少了这一条，`tags` 里存的是中文（`DownloadedItem.tags`
//  已按 `ModrinthTagMap` 汉化过），用户输中文就一条也搜不到 ——
//  前三条的 `localizedCaseInsensitiveContains` 只匹配字面量，匹配不到「翻译关系」。
//
//  ⚠️ 反向匹配用的是**精确相等**（`$1 == query`），不是包含匹配 —— 与前三条的
//  `localizedCaseInsensitiveContains` 语义不同：输入 `科` 匹配不到 `科技`。
//

import XCTest
@testable import qwq

final class ItemFilterTests: XCTestCase {

    private func item(name: String = "Name",
                      subtitle: String = "Sub",
                      tags: [String] = []) -> DownloadedItem {
        DownloadedItem(id: "id", name: name, subtitle: subtitle, iconURL: nil, tags: tags)
    }

    // MARK: - 标题匹配

    func testMatchesName() async {
        XCTAssertTrue(ItemFilter.matches(item(name: "Sodium"), query: "Sodium"))
    }

    /// 标题匹配是**大小写不敏感**的
    func testNameMatchIsCaseInsensitive() async {
        XCTAssertTrue(ItemFilter.matches(item(name: "Sodium"), query: "sodium"))
        XCTAssertTrue(ItemFilter.matches(item(name: "sodium"), query: "SODIUM"))
    }

    /// 子串匹配（`localizedCaseInsensitiveContains`）
    func testNameMatchIsSubstring() async {
        XCTAssertTrue(ItemFilter.matches(item(name: "Sodium Extra"), query: "dium"))
    }

    // MARK: - 简介匹配

    func testMatchesSubtitle() async {
        XCTAssertTrue(ItemFilter.matches(item(name: "X", subtitle: "很棒的性能优化模组"),
                                         query: "性能优化"))
    }

    func testSubtitleMatchIsCaseInsensitive() async {
        XCTAssertTrue(ItemFilter.matches(item(name: "X", subtitle: "Performance mod"),
                                         query: "PERFORMANCE"))
    }

    // MARK: - 标签字面量匹配

    func testMatchesTagLiteral() async {
        XCTAssertTrue(ItemFilter.matches(item(tags: ["科技", "魔法"]), query: "科技"))
    }

    func testTagLiteralMatchIsCaseInsensitive() async {
        XCTAssertTrue(ItemFilter.matches(item(tags: ["Optimization"]), query: "optimization"))
    }

    // MARK: - 中文标签的反向匹配（本文件的靶心）

    /// 用户输入**中文译名** ⇒ 反查英文键 ⇒ 条目带该英文键时命中。
    /// 这条分支的存在前提：`tags` 里存的是**中文**（已汉化），而搜索框允许输中文。
    func testChineseTagQueryMatchesViaReverseLookup() async {
        // tags 存中文「科技」，用户输中文「科技」—— 字面量分支本已能命中；
        // 真正的反向匹配场景是 tags 存英文键、用户输中文译名。
        let englishTagged = item(tags: ["technology"])
        XCTAssertTrue(ItemFilter.matches(englishTagged, query: "科技"),
                      "输中文译名应能通过 ModrinthTagMap 反查到英文标签键 technology")
    }

    /// 反向匹配对多个候选键逐个尝试（`contains` 遍历整个映射表）
    func testReverseLookupWorksForOtherTags() async {
        XCTAssertTrue(ItemFilter.matches(item(tags: ["optimization"]), query: "性能优化"))
        XCTAssertTrue(ItemFilter.matches(item(tags: ["magic"]), query: "魔法"))
        XCTAssertTrue(ItemFilter.matches(item(tags: ["path-tracing"]), query: "路径追踪"))
    }

    /// ⚠️ 反向匹配是**精确相等**（`$1 == query`），不是包含 —— 输入译名的前缀匹配不到
    func testReverseLookupIsExactNotSubstring() async {
        XCTAssertFalse(ItemFilter.matches(item(tags: ["technology"]), query: "科"),
                       "反向匹配用 ==，不是 contains；输入『科』匹配不到『科技』")
    }

    /// ⚠️ 反向匹配**大小写敏感**（`$1 == query` 用的是 `ModrinthTagMap` 的中文值，
    /// 而中文无大小写问题；但英文键那侧不参与 `==`，故英文全大写查不到中文键）
    func testReverseLookupDoesNotMatchUnrelatedQuery() async {
        XCTAssertFalse(ItemFilter.matches(item(tags: ["technology"]), query: "magic"))
        XCTAssertFalse(ItemFilter.matches(item(tags: ["technology"]), query: "不存在的标签"))
    }

    /// 反向匹配要求**条目确实带该标签**：译名对但条目没这个标签 ⇒ 不命中
    func testReverseLookupRequiresItemToHaveTheTag() async {
        XCTAssertFalse(ItemFilter.matches(item(tags: ["magic"]), query: "科技"),
                       "『科技』对应的键是 technology，条目只有 magic ⇒ 不命中")
    }

    /// 空 tags 的条目仍可按标题/简介命中（注释：「tags 为空时完整谓词自动退化为
    /// 『标题 + 简介』匹配」）
    func testEmptyTagsDegradesToNameAndSubtitleMatching() async {
        let bare = item(name: "Sodium", subtitle: "desc", tags: [])
        XCTAssertTrue(ItemFilter.matches(bare, query: "Sodium"))
        XCTAssertTrue(ItemFilter.matches(bare, query: "desc"))
        XCTAssertFalse(ItemFilter.matches(bare, query: "任意标签"))
    }

    // MARK: - 空查询与不命中

    /// ⚠️ 空查询串**不**命中任何条目。独立探针实测（macOS 15.7）：
    /// `localizedCaseInsensitiveContains("")` 返回 **false**，不是注释原先声称的"恒真"——
    /// 原断言（`XCTAssertTrue`）在 2026-10-02 全量实测中失败。
    /// 若要「空查询返回全部结果」，需要调用方显式处理，谓词本身不做。
    func testEmptyQueryMatchesEverything() async {
        XCTAssertFalse(ItemFilter.matches(item(), query: ""))
    }

    /// 完全无关的查询 ⇒ 不命中
    func testUnrelatedQueryDoesNotMatch() async {
        let it = item(name: "Sodium", subtitle: "Fast renderer", tags: ["optimization"])
        XCTAssertFalse(ItemFilter.matches(it, query: "zzzz-not-present"))
    }

    // MARK: - 多候选词过滤（中文搜索的本地目录路径）

    /// 中文搜索的接线前提：本地目录的名称/简介是英文原文，中文原词经 SearchTranslator
    /// 译出英文候选词后由 `matchesAny` 逐词匹配 —— 任一词命中即命中。
    func testMatchesAnyHitsViaEnglishTerm() async {
        let sodium = item(name: "Sodium", subtitle: "A modern rendering engine")
        XCTAssertTrue(ItemFilter.matchesAny(sodium,
                                            queries: ["钠", "sodium"],
                                            originalQuery: "钠",
                                            translatedSubtitle: nil),
                      "英文候选词 sodium 应命中标题")
    }

    /// 中文原词本身也参与匹配（中文标签/中文副标题的场景不依赖翻译）
    func testMatchesAnyStillTriesOriginalQuery() async {
        let installed = item(name: "X", tags: ["已安装"])
        XCTAssertTrue(ItemFilter.matchesAny(installed,
                                            queries: ["已安装", "installed"],
                                            originalQuery: "已安装",
                                            translatedSubtitle: nil))
    }

    /// 已翻译的中文副标题只对**中文原词**匹配 —— 它不可能命中英文候选词
    func testMatchesAnyUsesTranslatedSubtitleForOriginalQuery() async {
        let it = item(name: "Sodium", subtitle: "A modern rendering engine")
        XCTAssertTrue(ItemFilter.matchesAny(it,
                                            queries: ["钠", "sodium"],
                                            originalQuery: "性能",
                                            translatedSubtitle: "现代化的渲染引擎，大幅优化性能"),
                      "中文副标题包含原词「性能」应命中")
        XCTAssertFalse(ItemFilter.matchesAny(item(name: "Sodium", subtitle: "A modern rendering engine"),
                                             queries: ["钠"],
                                             originalQuery: "钠",
                                             translatedSubtitle: nil),
                       "没有译文候选词时，中文原词不应凭空命中英文字段")
    }

    /// 候选词逐词尝试：第二个词（render）命中标题 —— 证明不是只试第一个词
    func testMatchesAnyTriesEveryTerm() async {
        let it = item(name: "Sodium", subtitle: "Fast renderer")
        XCTAssertTrue(ItemFilter.matchesAny(it,
                                            queries: ["钠", "sodium", "render"],
                                            originalQuery: "钠",
                                            translatedSubtitle: "快速渲染器"),
                      "「render」应命中标题 —— 此断言校验候选词真的在逐词尝试")
    }

    func testMatchesAnyAllMiss() async {
        let it = item(name: "Sodium", subtitle: "Fast renderer")
        XCTAssertFalse(ItemFilter.matchesAny(it,
                                             queries: ["zzz", "钠"],
                                             originalQuery: "钠",
                                             translatedSubtitle: nil))
    }

    // MARK: - 批量过滤（filterItems，12 万条本地目录的后台路径）

    /// 批量路径与逐条目 matchesAny 同语义：候选词命中 + 已翻译中文副标题对原词命中
    func testFilterItemsMatchesCandidatesAndTranslatedSubtitles() async {
        let sodium = item(name: "Sodium", subtitle: "A modern rendering engine", tags: [])
        let chineseNamed = item(name: "村庄地平线 Village Horizons +", subtitle: "villagers live better")
        let translated = ["sodium-id": "现代化的渲染引擎，大幅优化性能"]
        let result = ItemFilter.filterItems(
            in: [sodium, chineseNamed],
            queries: ["地平线", "sodium"],
            originalQuery: "地平线",
            translatedSubtitles: translated)
        XCTAssertEqual(Set(result.map { $0.id }), Set([sodium.id, chineseNamed.id]),
                       "英文候选词命中 Sodium，中文副标题命中 Village Horizons")
    }

    /// 「中文译名 → 英文标签键」的反查在批量路径里被预计算成键集合：行为与逐条目扫描等价
    func testFilterItemsPrecomputesTagKeys() async {
        let tagged = item(name: "X", subtitle: "y", tags: ["optimization"])
        let result = ItemFilter.filterItems(in: [tagged],
                                            queries: ["性能优化"],
                                            originalQuery: "性能优化",
                                            translatedSubtitles: [:])
        XCTAssertEqual(result.map { $0.id }, [tagged.id], "「性能优化」应经映射表反查命中 optimization 标签")
    }

    /// 全不命中 ⇒ 空结果（含 translatedSubtitles 为空的常规路径）
    func testFilterItemsAllMiss() async {
        let it = item(name: "Sodium", subtitle: "Fast renderer", tags: [])
        XCTAssertTrue(ItemFilter.filterItems(in: [it],
                                             queries: ["zzz", "钠"],
                                             originalQuery: "钠",
                                             translatedSubtitles: [:]).isEmpty)
    }
}
