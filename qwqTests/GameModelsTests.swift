//
//  GameModelsTests.swift
//  qwqTests
//
//  覆盖 `Models/GameModels.swift`（侧边栏分类、标签汉化表、通用下载条目）。
//
//  **为什么值得测**：这个文件里有两处「名字即契约」的设计，改动会**静默失效**：
//
//  1. `GameSubCategory` / `GameSidebarSection` 的 `rawValue` **就是中文显示名**，
//     同时被当作 `id`（列表 identity）；而 `GameSidebarSection` 的五个中文名还承担
//     **页面分派**作用 —— 注释原话：「CategoryContentView 靠 `category.name == "个性化" /
//     "启动" / "游戏"` 这类字符串比较决定渲染哪个页面，改名会导致分派静默落空
//     （走进空网格分支，无编译错误）」。
//  2. `DownloadedItem` **自定义了 `==`，只比 `id` 与 `subtitle`**，刻意忽略
//     `name` / `iconURL` / `tags` —— 注释自认副作用：「名字改了但 subtitle 没变时，
//     会判定为「未变化」而跳过更新」。
//
//  这两条都不是「实现细节」，而是别的代码依赖的行为契约，故逐条钉住。
//

import XCTest
import zlib
@testable import qwq

final class GameModelsTests: XCTestCase {

    // MARK: - 中文 rawValue 即显示名，也是 id

    func testGameSubCategoryRawValuesAreChineseDisplayNames() async {
        XCTAssertEqual(GameSubCategory.release.rawValue, "正式版")
        XCTAssertEqual(GameSubCategory.snapshot.rawValue, "测试版")
        XCTAssertEqual(GameSubCategory.ancient.rawValue, "远古版")
    }

    func testGameSubCategoryIDEqualsRawValue() async {
        for c in GameSubCategory.allCases {
            XCTAssertEqual(c.id, c.rawValue, "\(c) 的 id 必须就是中文 rawValue（列表 identity）")
        }
    }

    func testGameSubCategoryHasThreeCasesInOrder() async {
        XCTAssertEqual(GameSubCategory.allCases, [.release, .snapshot, .ancient])
    }

    /// 侧边栏五个一级分类的中文名 —— **这些字符串承担页面分派**，改名即静默失效
    func testSidebarSectionRawValuesAreChineseDisplayNames() async {
        XCTAssertEqual(GameSidebarSection.game.rawValue, "游戏")
        XCTAssertEqual(GameSidebarSection.mod.rawValue, "模组")
        XCTAssertEqual(GameSidebarSection.resourcePack.rawValue, "资源包")
        XCTAssertEqual(GameSidebarSection.shader.rawValue, "光影")
        XCTAssertEqual(GameSidebarSection.modpack.rawValue, "整合包")
    }

    func testSidebarSectionIDEqualsRawValue() async {
        for s in GameSidebarSection.allCases {
            XCTAssertEqual(s.id, s.rawValue)
        }
    }

    func testSidebarSectionHasFiveCasesInOrder() async {
        XCTAssertEqual(GameSidebarSection.allCases,
                       [.game, .mod, .resourcePack, .shader, .modpack])
    }

    /// 侧边栏图标是 **SF Symbols 名**（不是资产目录名）；拼错只会显示空白，不崩。
    /// 这里钉住当前取值，避免误改成资产名。
    func testSidebarSystemImages() async {
        XCTAssertEqual(GameSidebarSection.game.systemImage, "rectangle.grid.1x2.fill")
        XCTAssertEqual(GameSidebarSection.mod.systemImage, "puzzlepiece.fill")
        XCTAssertEqual(GameSidebarSection.resourcePack.systemImage, "photo.on.rectangle.angled")
        XCTAssertEqual(GameSidebarSection.shader.systemImage, "sparkles")
        XCTAssertEqual(GameSidebarSection.modpack.systemImage, "archivebox.fill")
    }

    /// 每个分类都有非空图标名（漏一个就是空白图标位）
    func testEverySidebarSectionHasSystemImage() async {
        for s in GameSidebarSection.allCases {
            XCTAssertFalse(s.systemImage.isEmpty, "\(s) 缺少图标名")
        }
    }

    /// 五个图标互不相同（重复会让多个分类看起来一样）
    func testSidebarSystemImagesAreDistinct() async {
        let images = GameSidebarSection.allCases.map(\.systemImage)
        XCTAssertEqual(Set(images).count, images.count)
    }

    // MARK: - ModrinthTagMap：白名单语义

    /// 查得到 → 中文；查不到 → 由调用方原样展示英文（本表**不负责兜底**）
    func testTagMapIsWhitelistNotTotalMapping() async {
        XCTAssertEqual(ModrinthTagMap["technology"], "科技")
        XCTAssertEqual(ModrinthTagMap["optimization"], "性能优化")
        XCTAssertNil(ModrinthTagMap["a-tag-added-upstream-later"],
                     "上游新增标签不在表里 ⇒ nil，界面原样显示英文（白名单语义）")
    }

    /// 分辨率标签的取值就是倍率本身，`512x+` 表示「512 及以上」
    func testResolutionTags() async {
        XCTAssertEqual(ModrinthTagMap["8x-"], "极简")
        XCTAssertEqual(ModrinthTagMap["16x"], "16x")
        XCTAssertEqual(ModrinthTagMap["512x+"], "超高清")
    }

    /// 键集合是三类标签的混装（内容 + 分辨率 + 光影特性），故存在同名不同义的风险。
    /// 本用例只钉住「三类都确实在表里」，防止有人按单一来源清理表项。
    func testTagMapCoversAllThreeTagFamilies() async {
        XCTAssertNotNil(ModrinthTagMap["magic"], "内容标签")
        XCTAssertNotNil(ModrinthTagMap["256x"], "分辨率标签")
        XCTAssertNotNil(ModrinthTagMap["path-tracing"], "光影特性标签")
    }

    /// 值全部非空（空串会在界面上渲染成空白标签）
    func testTagMapValuesAreNonEmpty() async {
        for (key, value) in ModrinthTagMap {
            XCTAssertFalse(value.isEmpty, "标签 \(key) 的中文名为空")
        }
    }

    /// 🌟 全库覆盖回归（用户反馈：光影卡片分类显示英文，如 `low` 低性能档）。
    /// 从 bundle 自带的全量目录 gzip 源读取真实 categories 全集，
    /// 断言每一条都能经 `ModrinthTagMap` 译出中文 —— 防止「上游标签新增 / 有人误删表项」
    /// 再次让卡片回显英文 slug（`ContentCard` 对未收录键按原文兜底的代价）。
    /// 判据与 `DetailPageHeader` 的 compactMap（译不出即丢弃）区分：
    /// 卡片路径要求全量可译，详情页路径允许白名单缺项。
    func testTagMapCoversEveryCategoryInBundledCatalog() async {
        guard let gzURL = Bundle.main.url(forResource: "modrinth_catalog", withExtension: "json.gz"),
              let gzData = try? Data(contentsOf: gzURL) else {
            XCTFail("找不到 bundle 内的 modrinth_catalog.json.gz")
            return
        }
        guard let data = Self.gunzipped(gzData),
              let json = try? JSONSerialization.jsonObject(with: data),
              let envelope = json as? [String: Any],
              let items = envelope["items"] as? [[String: Any]] else {
            XCTFail("gzip 解压或目录 JSON 解析失败")
            return
        }
        var seen = Set<String>()
        for item in items {
            // 目录 JSON 用短键：c = categories（其余 i/t/n/d/u/x 是 id/标题/简介/图标等）。
            guard let categories = item["c"] as? [String] else { continue }
            for category in categories {
                let key = category.lowercased()
                if seen.contains(key) { continue }
                seen.insert(key)
                XCTAssertNotNil(ModrinthTagMap[key],
                                "全量目录中未收录的分类 '\(key)' 会在卡片上回显英文，需补 ModrinthTagMap")
            }
        }
        XCTAssertGreaterThan(seen.count, 50, "目录 categories 集合应远大于 50，防止测试空转")
    }

    /// 最小 gzip 解压（系统 libz，windowBits=31 支持 gzip 格式）——
    /// 与 `LocalModCatalog.inflateGzipData` 同法。测试内联而非复用实现，
    /// 避免把生产类的 private 工具暴露成 internal。
    private static func gunzipped(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        return input.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data? in
            let src = srcRaw.bindMemory(to: UInt8.self)
            var stream = z_stream()
            guard let srcBase = src.baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcBase)
            stream.avail_in = uInt(input.count)
            guard inflateInit2_(&stream, 16 + 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            defer { inflateEnd(&stream) }
            var output = Data()
            let buffer = [UInt8](repeating: 0, count: 1 << 16)
            var lastStatus: Int32 = Z_OK
            while true {
                var localBuffer = buffer
                let produced = localBuffer.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
                    guard let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    stream.next_out = dstBase
                    stream.avail_out = uInt(buffer.count)
                    lastStatus = inflate(&stream, Z_NO_FLUSH)
                    if lastStatus == Z_OK || lastStatus == Z_STREAM_END {
                        return buffer.count - Int(stream.avail_out)
                    }
                    return -1
                }
                if produced < 0 { return nil }
                if produced > 0 { output.append(localBuffer, count: produced) }
                if lastStatus == Z_STREAM_END { return output }
                if stream.avail_in == 0 && lastStatus == Z_OK { return nil }
            }
        }
    }

    // MARK: - DownloadedItem 的自定义相等（本文件的靶心）

    private func item(id: String = "p1",
                      name: String = "Name",
                      subtitle: String = "Sub",
                      iconURL: String? = nil,
                      tags: [String] = []) -> DownloadedItem {
        DownloadedItem(id: id, name: name, subtitle: subtitle, iconURL: iconURL, tags: tags)
    }

    /// 自定义 `==` **只看 `id` 与 `subtitle`**
    func testEqualityIgnoresNameIconAndTags() async {
        let a = item(name: "Old", subtitle: "same", iconURL: nil, tags: [])
        let b = item(name: "New", subtitle: "same", iconURL: "https://x/i.png", tags: ["科技"])
        XCTAssertEqual(a, b, "name / iconURL / tags 变化不影响相等（设计如此）")
    }

    /// `id` 不同 ⇒ 不等
    func testDifferentIDMeansNotEqual() async {
        XCTAssertNotEqual(item(id: "a", subtitle: "s"), item(id: "b", subtitle: "s"))
    }

    /// `subtitle` 不同 ⇒ 不等（这是「内容更新」的判据，例如下载量变了）
    func testDifferentSubtitleMeansNotEqual() async {
        XCTAssertNotEqual(item(subtitle: "1.2k downloads"), item(subtitle: "1.3k downloads"))
    }

    /// ⚠️ **注释自认的副作用**：名字改了但 `subtitle` 没变 ⇒ 判为「未变化」，
    /// 列表会**跳过更新**。本用例把这个行为固定住 —— 若有人想「修」它，
    /// 得先明白它是有意为之（用于判断列表要不要刷新），而不是随手改 `==`。
    func testRenamedItemWithUnchangedSubtitleIsConsideredUnchanged() async {
        let before = item(name: "旧名字", subtitle: "固定副标题")
        let after = item(name: "新名字", subtitle: "固定副标题")
        XCTAssertEqual(before, after,
                       "已知副作用：名字变更但 subtitle 未变时判为未变化，列表不会刷新")
    }

    /// 只改 `iconURL` / `tags` ⇒ 同样判为未变化
    func testIconAndTagChangesAloneAreNotDetected() async {
        XCTAssertEqual(item(iconURL: nil, tags: []),
                       item(iconURL: "https://x/new.png", tags: ["魔法"]))
    }

    /// `Codable` 往返：自定义 `==` **不影响**编解码（编码仍含全部字段）
    func testCodableRoundTripKeepsAllFields() async throws {
        let original = item(id: "p", name: "N", subtitle: "S",
                            iconURL: "https://x/i.png", tags: ["科技", "魔法"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DownloadedItem.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.subtitle, original.subtitle)
        XCTAssertEqual(decoded.iconURL, original.iconURL)
        XCTAssertEqual(decoded.tags, original.tags)
    }

    /// 编码后的 JSON **确实包含**被 `==` 忽略的字段（证明忽略只发生在比较层）
    func testEncodedJSONContainsFieldsIgnoredByEquality() async throws {
        let data = try JSONEncoder().encode(item(name: "N", tags: ["科技"]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"name\""), "name 被 == 忽略，但必须参与编码")
        XCTAssertTrue(text.contains("\"tags\""), "tags 被 == 忽略，但必须参与编码")
    }
}
