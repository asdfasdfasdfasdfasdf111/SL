//
//  CommunityNameResolverTests.swift
//  qwqTests
//
//  覆盖 `Features/Translation/CommunityNameResolver.extractNames`
//  （MC 百科搜索页 HTML → 候选英文名）。
//
//  **为什么值得测**：这是中文搜索接社区定译名的取数核心，页面结构靠正则解析，
//  标题里混着 `<em>` 高亮、HTML 实体、「[缩写]」前缀、括号别名，还有页脚那行
//  「地址」锚文本是 URL 本身的干扰项 —— 每一样都可能解析歪。
//

import XCTest
@testable import qwq

final class CommunityNameResolverTests: XCTestCase {

    /// 按真实搜索页结构拼的最小 fixture（结果区 + 页脚地址行，逐字对照过线上页面）。
    private let fixture = """
    <div class="result-item"><div class="head"><a target="_blank" href="https://www.mcmod.cn/class/5009.html">[DH] Distant Horizons</a></div><div class="body">概述…</div><div class="foot"><span class="info"><span>地址：</span><span class="value"><a target="_blank" href="https://www.mcmod.cn/class/5009.html">www.mcmod.cn/class/5009.html</a></span></span></div></div>
    <div class="result-item"><div class="head"><a href="https://www.mcmod.cn/class/22048.html">Distant Horizons GTNH 版 (Distant Horizons Standalone)</a></div><div class="body">…</div></div>
    <div class="result-item"><div class="head"><a href="https://www.mcmod.cn/class/26945.html">自然<em>地</em>平线 &amp; 天空</a></div><div class="body">…</div></div>
    """

    /// 首条结果「[DH] Distant Horizons」：[缩写] 前缀应被剥掉，
    /// 剩下的正是 Modrinth 目录里能被 substring 命中的项目名
    func testExtractsNameStrippingBracketPrefix() async {
        let names = CommunityNameResolver.extractNames(fromSearchHTML: fixture)
        XCTAssertEqual(names.first, "Distant Horizons")
    }

    /// 页脚「地址」行与结果标题共用同一批 class 链接，但它的锚文本是 URL 本身 —— 不能当候选名
    func testFootURLAnchorIsDropped() async {
        let names = CommunityNameResolver.extractNames(fromSearchHTML: fixture)
        XCTAssertFalse(names.contains { $0.contains("mcmod.cn") })
    }

    /// 「A (B)」标题：括号里的 B 往往才是 Modrinth 项目名，应单独成候选
    func testParenAliasBecomesStandaloneCandidate() async {
        let names = CommunityNameResolver.extractNames(fromSearchHTML: fixture)
        XCTAssertTrue(names.contains("Distant Horizons Standalone"))
    }

    /// `<em>` 关键词高亮与 `&amp;` 实体应被剥干净
    func testEmHighlightAndEntityAreStripped() async {
        let names = CommunityNameResolver.extractNames(fromSearchHTML: fixture)
        XCTAssertTrue(names.contains("自然地平线 & 天空"))
    }

    /// 候选名去重（同一模组的标题与括号别名可能撞车）
    func testDeduplicatesCandidates() async {
        let names = CommunityNameResolver.extractNames(fromSearchHTML: fixture)
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// 只认指向 /class/<id>.html（模组资料页）的锚：
    /// 分类目录页与帖子页的链接不产候选名
    func testNonClassLinksAreIgnored() async {
        let html = #"<a href="//www.mcmod.cn/class/category/24-1.html">分类目录</a><a href="https://www.mcmod.cn/post/1.html">帖子</a>"#
        XCTAssertTrue(CommunityNameResolver.extractNames(fromSearchHTML: html).isEmpty)
    }
}
