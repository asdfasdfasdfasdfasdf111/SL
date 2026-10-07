//
//  CommunityNameResolverTests.swift
//  qwqTests
//
//  覆盖 `Features/Translation/CommunityNameResolver` 的两个纯解析函数：
//  `extractAnchors`（MC 百科搜索页 HTML → 英文名/别名/资料页地址）
//  与 `parseClassPage`（资料页 HTML → 英文名 + 定译中文名）。
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

    // MARK: - extractAnchors（搜索页）

    /// 首条结果「[DH] Distant Horizons」：[缩写] 前缀应被剥掉，
    /// 剩下的正是 Modrinth 目录里能被 substring 命中的项目名
    func testExtractsNameStrippingBracketPrefix() async {
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: fixture)
        XCTAssertEqual(anchors.first?.english, "Distant Horizons")
    }

    /// 页脚「地址」行与结果标题共用同一批 class 链接，但它的锚文本是 URL 本身 —— 不能当候选名
    func testFootURLAnchorIsDropped() async {
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: fixture)
        XCTAssertFalse(anchors.contains { $0.english.contains("mcmod.cn") })
    }

    /// 「A (B)」标题：括号里的 B 往往才是 Modrinth 项目名，应单独成别名候选
    func testParenAliasBecomesStandaloneCandidate() async {
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: fixture)
        let gtnh = anchors.first { $0.english.contains("GTNH") }
        XCTAssertEqual(gtnh?.aliases, ["Distant Horizons Standalone"])
    }

    /// `<em>` 关键词高亮与 `&amp;` 实体应被剥干净
    func testEmHighlightAndEntityAreStripped() async {
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: fixture)
        XCTAssertTrue(anchors.contains { $0.english == "自然地平线 & 天空" })
    }

    /// 资料页地址随锚一起抽出（供并发补取中文名），且协议相对写法要补全成 https
    func testClassURLIsCapturedAndNormalized() async {
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: fixture)
        XCTAssertEqual(anchors.first?.classURL, "https://www.mcmod.cn/class/5009.html")
    }

    /// 同一条结果的页脚链接与标题链接指向同一 URL —— 去重后只算一条
    func testDeduplicatesByURL() async {
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: fixture)
        XCTAssertEqual(Set(anchors.map { $0.classURL }).count, anchors.count)
    }

    /// 只认指向 /class/<id>.html（模组资料页）的锚：分类目录页与帖子页不产候选
    func testNonClassLinksAreIgnored() async {
        let html = #"<a href="//www.mcmod.cn/class/category/24-1.html">分类目录</a><a href="https://www.mcmod.cn/post/1.html">帖子</a>"#
        XCTAssertTrue(CommunityNameResolver.extractAnchors(fromSearchHTML: html).isEmpty)
    }

    // MARK: - parseClassPage（资料页）

    /// 资料页结构逐字对照线上 5009 号页（Distant Horizons）：
    /// `<title>[DH]Distant Horizons - MC百科|…</title>` + 头图后的 `<span class="figcaption">遥远的地平线</span>`
    private let classPageFixture = """
    <html><head><title>[DH]Distant Horizons - MC百科|最大的Minecraft中文MOD百科</title></head><body>
    <span class="figure"><img class="lazy" src="//www.mcmod.cn/static/public/images/loading-colourful.gif" data-src="https://i.mcmod.cn/editor/upload/20230628/1687944633_232613_tKrO.webp" width="533" height="300" /><span class="figcaption">遥远的地平线</span></span>
    </body></html>
    """

    func testParseClassPageExtractsBothNames() async {
        let parsed = CommunityNameResolver.parseClassPage(classPageFixture)
        XCTAssertEqual(parsed.english, "Distant Horizons")
        XCTAssertEqual(parsed.chinese, "遥远的地平线")
    }

    /// 无 figcaption 的资料页（少数纯英文条目）中文名记 nil，英文名照常解析
    func testParseClassPageToleratesMissingCaption() async {
        let html = #"<html><head><title>Some Mod - MC百科|最大的Minecraft中文MOD百科</title></head><body>没有图注</body></html>"#
        let parsed = CommunityNameResolver.parseClassPage(html)
        XCTAssertEqual(parsed.english, "Some Mod")
        XCTAssertNil(parsed.chinese)
    }
}
