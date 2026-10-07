//
//  CommunityNameResolverTests.swift
//  qwqTests
//
//  覆盖 `Features/Translation/CommunityNameResolver.extractAnchors`
//  （MC 百科搜索页 HTML → 定译名候选，含「中文 (English)」配对与校验）。
//
//  **为什么值得测**：这是中文搜索接社区定译名的取数核心。这里曾出过两起真实事故：
//  ① 页头 `figcaption` 是轮播图库的图注、内容随刷新轮换，把卡片名整句变成
//     「这张照片是在渲染距离 12/512 下拍摄的」（已因此**删除**资料页抓取路径，
//     中文名只信搜索页标题的「中文 (English)」配对 + 校验）；
//  ② 标题里混着 `<em>` 高亮、HTML 实体、「[缩写]」前缀、页脚 URL 干扰项，解析歪一个
//     候选词就少搜到一片模组。
//

import XCTest
@testable import qwq

final class CommunityNameResolverTests: XCTestCase {

    /// 按真实搜索页结构拼的最小 fixture（结果区 + 页脚地址行，逐字对照过线上页面）。
    private let fixture = """
    <div class="result-item"><div class="head"><a target="_blank" href="https://www.mcmod.cn/class/5009.html">[DH] Distant Horizons</a></div><div class="body">概述…</div><div class="foot"><span class="info"><span>地址：</span><span class="value"><a target="_blank" href="https://www.mcmod.cn/class/5009.html">www.mcmod.cn/class/5009.html</a></span></span></div></div>
    <div class="result-item"><div class="head"><a href="https://www.mcmod.cn/class/36.html">[OF]高清修复 (OptiFine)</a></div><div class="body">…</div></div>
    <div class="result-item"><div class="head"><a href="https://www.mcmod.cn/class/22048.html">Distant Horizons GTNH 版 (Distant Horizons Standalone)</a></div><div class="body">…</div></div>
    <div class="result-item"><div class="head"><a href="https://www.mcmod.cn/class/26945.html">自然<em>地</em>平线 &amp; 天空</a></div><div class="body">…</div></div>
    """

    // MARK: - 基础抽取

    /// 首条结果「[DH] Distant Horizons」：[缩写] 前缀应被剥掉。
    /// 该词条主标题就是英文（页面上没有稳定中文名字段），chinese 应为 nil ——
    /// 卡片保持英文名，但英文名照常作为中文搜索的过滤候选。
    func testExtractsEnglishNameWithoutChinese() async {
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: fixture)
        let dh = anchors.first { $0.english == "Distant Horizons" }
        XCTAssertNotNil(dh)
        XCTAssertNil(dh?.chinese, "DH 的百科主标题是英文，不应伪造中文名")
    }

    /// 页脚「地址」行与结果标题共用同一批 class 链接，但它的锚文本是 URL 本身 —— 不能当候选名
    func testFootURLAnchorIsDropped() async {
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: fixture)
        XCTAssertFalse(anchors.contains { $0.english.contains("mcmod.cn") })
    }

    /// `<em>` 关键词高亮与 `&amp;` 实体应被剥干净
    func testEmHighlightAndEntityAreStripped() async {
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: fixture)
        XCTAssertTrue(anchors.contains { $0.english == "自然地平线 & 天空" && $0.chinese == nil })
    }

    /// 只认指向 /class/<id>.html（模组资料页）的锚：分类目录页与帖子页不产候选
    func testNonClassLinksAreIgnored() async {
        let html = #"<a href="//www.mcmod.cn/class/category/24-1.html">分类目录</a><a href="https://www.mcmod.cn/post/1.html">帖子</a>"#
        XCTAssertTrue(CommunityNameResolver.extractAnchors(fromSearchHTML: html).isEmpty)
    }

    // MARK: - 「中文 (English)」配对

    /// 「[OF]高清修复 (OptiFine)」：括号前是校验通过的中文 ⇒ 括号内是英文名、
    /// 括号前是定译中文名 —— 这对数据就是「卡片显示名换定译名」的来源
    func testChineseEnglishPairExtracted() async {
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: fixture)
        let pair = anchors.first { $0.english == "OptiFine" }
        XCTAssertEqual(pair?.chinese, "高清修复")
    }

    /// 括号前不是中文（如「Distant Horizons GTNH 版 (Distant Horizons Standalone)」
    /// 的括号内是别名、括号前含拉丁）——整标题作为英文候选，括号内容降级为纯过滤别名
    func testNonChineseBaseFallsBackToEnglishWithAlias() async {
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: fixture)
        let gtnh = anchors.first { $0.english == "Distant Horizons GTNH 版 (Distant Horizons Standalone)" }
        XCTAssertNotNil(gtnh, "非中文基底的标题应整体作为英文候选")
        XCTAssertEqual(gtnh?.aliases, ["Distant Horizons Standalone"])
        XCTAssertNil(gtnh?.chinese)
    }

    /// 「中文 (English)」配对过校验：中文部分超长（图注式句子）⇒ 不配对
    func testOverlongChineseBaseIsRejected() async {
        let long = "这张图片是在游戏渲染距离为12和模组渲染距离为152的情况下拍摄的"
        let html = #"<a href="https://www.mcmod.cn/class/777.html">"# + long +
                   #" (Some Mod)</a>"#
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: html)
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(anchors[0].chinese, nil, "图注式长句不能当中文名")
    }

    /// 中文部分带句读标点 ⇒ 不配对（模组名不会是一句话）
    func testChineseBaseWithSentencePunctuationIsRejected() async {
        let html = #"<a href="https://www.mcmod.cn/class/778.html">很好的模组，值得一玩 (Nice Mod)</a>"#
        let anchors = CommunityNameResolver.extractAnchors(fromSearchHTML: html)
        XCTAssertNil(anchors[0].chinese)
    }
}
