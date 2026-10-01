//
//  MinecraftVersionInfoTests.swift
//  qwqTests
//
//  覆盖 `Features/Game/Module/MinecraftVersionInfo.swift`
//  （`MinecraftVersionInfo` / `ClientManifestSnapshot`）。
//
//  **为什么值得测**：它是「版本浏览」列表的只读快照模型，`init?(manifestEntry:)`
//  决定**哪些清单条目会出现在列表里**（`id` 缺失或为空时整条丢弃）。
//
//  一条注释点名的**设计决定**是本文件的重点：
//
//  > `kind` 用枚举的 `rawValue` 可失败构造，而**不是** `MinecraftVersionKind(rawVersionType:)`
//  > —— 后者回落值是 `.release`，会把未识别 type 误判为正式版，
//  > 与既有 `GameVersionFilter`（未识别 type 不匹配任何分类）行为不符。
//
//  本文件把「同一个 type 走两条构造路径得到不同结果」这件事**并排钉住**，
//  这样若有人把 `kind` 「简化」成 `MinecraftVersionKind(rawVersionType:)`，会立刻变红。
//

import XCTest
@testable import qwq

final class MinecraftVersionInfoTests: XCTestCase {

    private func info(_ entry: [String: Any]) -> MinecraftVersionInfo? {
        MinecraftVersionInfo(manifestEntry: entry)
    }

    // MARK: - init?(manifestEntry:)：id 是唯一硬要求

    /// `id` 缺失 ⇒ 条目丢弃（既有实现用 `compactMap` 过滤，口径一致）
    func testMissingIDDropsEntry() async {
        XCTAssertNil(info(["type": "release"]))
    }

    /// `id` 为空串 ⇒ 同样丢弃（不是「有 id 就收」，而是「非空才收」）
    func testEmptyIDDropsEntry() async {
        XCTAssertNil(info(["id": "", "type": "release"]))
    }

    /// `id` 非字符串（如数字）⇒ 丢弃
    func testNonStringIDDropsEntry() async {
        XCTAssertNil(info(["id": 123, "type": "release"]))
    }

    /// 正常条目：`id` 与 `type` 原样保留
    func testBasicFieldsAreKept() async {
        let v = info(["id": "1.20.1", "type": "release", "releaseTime": "2023-06-12T13:25:51+00:00"])
        XCTAssertEqual(v?.id, "1.20.1")
        XCTAssertEqual(v?.type, "release")
        XCTAssertEqual(v?.releaseTime, "2023-06-12T13:25:51+00:00")
    }

    /// `type` 缺失 ⇒ 退化为 `"unknown"`（**不是** `.release`；同样不落入任何分类）
    func testMissingTypeBecomesUnknownLiteral() async {
        XCTAssertEqual(info(["id": "x"])?.type, "unknown")
    }

    /// `releaseTime` 缺失 ⇒ 空串（而非 nil 或当前时间）
    func testMissingReleaseTimeBecomesEmptyString() async {
        XCTAssertEqual(info(["id": "x"])?.releaseTime, "")
    }

    // MARK: - manifestURL

    func testManifestURLIsParsedFromString() async {
        let v = info(["id": "x", "url": "https://piston-meta.mojang.com/v1/packages/abc/1.20.1.json"])
        XCTAssertEqual(v?.manifestURL?.absoluteString,
                       "https://piston-meta.mojang.com/v1/packages/abc/1.20.1.json")
    }

    /// `url` 缺失 ⇒ nil
    func testMissingURLYieldsNil() async {
        XCTAssertNil(info(["id": "x"])?.manifestURL)
    }

    /// `url` 非法（`URL(string:)` 返回 nil）⇒ 字段为 nil，条目**仍然保留**
    /// （与 `id` 缺失不同：这里丢字段不丢条目）
    func testInvalidURLYieldsNilButEntrySurvives() async {
        let v = info(["id": "x", "url": "http://exa mple.com/has space"])
        XCTAssertNotNil(v, "url 非法不应导致整条丢弃")
        XCTAssertNil(v?.manifestURL)
    }

    /// 从清单条目构造的条目**不带**客户端快照（`client == nil`）
    func testEntryBuiltInfoHasNoClientSnapshot() async {
        XCTAssertNil(info(["id": "x"])?.client)
    }

    // MARK: - kind：可失败构造 vs 回落 .release（本文件的靶心）

    /// 已识别的 `type` ⇒ 对应枚举值
    func testRecognizedTypesMapToKind() async {
        XCTAssertEqual(info(["id": "x", "type": "release"])?.kind, .release)
        XCTAssertEqual(info(["id": "x", "type": "snapshot"])?.kind, .snapshot)
        XCTAssertEqual(info(["id": "x", "type": "pre-release"])?.kind, .prerelease)
        XCTAssertEqual(info(["id": "x", "type": "rc"])?.kind, .rc)
        XCTAssertEqual(info(["id": "x", "type": "old_alpha"])?.kind, .alpha)
        XCTAssertEqual(info(["id": "x", "type": "old_beta"])?.kind, .beta)
        XCTAssertEqual(info(["id": "x", "type": "april_fool"])?.kind, .aprilFool)
        XCTAssertEqual(info(["id": "x", "type": "pending"])?.kind, .pending)
    }

    /// ⚠️ **核心设计决定**：未识别的 `type` ⇒ `kind` 为 **nil**（不落入任何分类），
    /// 而 `type` 原文保留为 `"unknown"`。
    func testUnrecognizedTypeYieldsNilKind() async {
        XCTAssertNil(info(["id": "x"])?.kind, "type 缺失 → \"unknown\" → kind 必须是 nil")
        XCTAssertNil(info(["id": "x", "type": "unknown"])?.kind)
        XCTAssertNil(info(["id": "x", "type": "something-new"])?.kind)
    }

    /// **并排钉住两条构造路径的差异**：同一个未识别字符串，
    /// `MinecraftVersionKind(rawVersionType:)` 回落到 `.release`，
    /// 而 `MinecraftVersionInfo.kind` 必须是 `nil`。
    /// 若有人把 `kind` 「简化」成前者，这条会红。
    func testKindDeliberatelyDiffersFromRawVersionTypeFallback() async {
        let unrecognized = "totally-new-type"

        XCTAssertEqual(MinecraftVersionKind(rawVersionType: unrecognized), .release,
                       "前提：rawVersionType 的回落值确实是 .release")
        XCTAssertNil(info(["id": "x", "type": unrecognized])?.kind,
                     "kind 必须用可失败构造，不能沿用 .release 回落 —— 否则未识别类型被误判为正式版")
    }

    // MARK: - isAprilFool：委托既有实现，不重复造规则

    /// 委托 `GameVersionHelper`：列表内的愚人节版本 ⇒ true
    func testIsAprilFoolDelegatesToHelper() async {
        XCTAssertTrue(info(["id": "24w14potato", "type": "snapshot"])!.isAprilFool)
        XCTAssertFalse(info(["id": "1.20.1", "type": "release"])!.isAprilFool)
    }

    /// 委托关系应当是**逐字一致**：`type` 原文被保留正是为了这一点
    /// （注释：「保存原文可保证与既有过滤规则逐字一致」）
    func testAprilFoolFlagMatchesHelperDirectly() async {
        for (id, type) in [("23w13a_or_b", "snapshot"), ("1.21-pre1", "snapshot"), ("1.20", "release")] {
            let expected = GameVersionHelper.isAprilFoolVersion(id: id, type: type)
            XCTAssertEqual(info(["id": id, "type": type])!.isAprilFool, expected,
                           "\(id)/\(type) 的判定必须与 GameVersionHelper 逐字一致")
        }
    }

    // MARK: - ClientManifestSnapshot：经公开入口解析构造

    /// `ClientManifestSnapshot` 只有 `init(_ manifest:)`（**没有成员逐一 init**：
    /// 结构体一旦自定义了初始化器就不再合成）。所以夹具必须走
    /// `ClientManifest.parse(url:)` —— 与同目录其它测试同构。
    private func snapshot(_ json: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> ClientManifestSnapshot {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-mvinfo-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manifest.json")
        try Data(json.utf8).write(to: url)
        let manifest = try XCTUnwrap(try ClientManifest.parse(url: url), "夹具清单解析失败", file: file, line: line)
        return ClientManifestSnapshot(manifest)
    }

    /// attaching(client:)：不可变更新
    func testAttachingClientPreservesOtherFields() async throws {
        let original = try XCTUnwrap(info([
            "id": "1.20.1", "type": "release",
            "releaseTime": "2023-06-12T13:25:51+00:00",
            "url": "https://example.invalid/1.20.1.json",
        ]))

        let attached = original.attaching(client: try snapshot("""
        { "id": "1.20.1", "mainClass": "net.minecraft.client.main.Main", "type": "release",
          "javaVersion": { "majorVersion": 17 },
          "assetIndex": { "id": "5", "sha1": "aa", "size": 1, "totalSize": 2, "url": "https://example.invalid/5.json" },
          "downloads": { "client": { "url": "https://example.invalid/client.jar", "sha1": "bb", "size": 3 } } }
        """))

        XCTAssertEqual(attached.id, original.id)
        XCTAssertEqual(attached.type, original.type)
        XCTAssertEqual(attached.releaseTime, original.releaseTime)
        XCTAssertEqual(attached.manifestURL, original.manifestURL)
        XCTAssertNotNil(attached.client)
        XCTAssertNil(original.client, "原值不可变，不应被就地改写")
    }

    /// 快照字段直接对应 `ClientManifest` 的公开属性，**存在即取到**
    func testSnapshotCapturesPresentFields() async throws {
        let snap = try snapshot("""
        { "id": "m", "mainClass": "Main", "type": "release",
          "javaVersion": { "majorVersion": 17 },
          "assetIndex": { "id": "5", "sha1": "aa", "size": 1, "totalSize": 2, "url": "https://example.invalid/5.json" },
          "downloads": { "client": { "url": "https://example.invalid/client.jar", "sha1": "bb", "size": 3 } } }
        """)
        XCTAssertEqual(snap.id, "m")
        XCTAssertEqual(snap.mainClass, "Main")
        XCTAssertEqual(snap.type, "release")
        XCTAssertEqual(snap.javaVersion, 17)
        XCTAssertEqual(snap.assetIndexID, "5")
        XCTAssertEqual(snap.clientDownloadURL, "https://example.invalid/client.jar")
    }

    /// 缺失项保持 **nil**，不用默认值顶替（注释：全表字段「缺失时保持 nil」）
    func testSnapshotLeavesMissingFieldsNil() async throws {
        let snap = try snapshot(#"{ "id": "m", "mainClass": "Main", "type": "release" }"#)
        XCTAssertNil(snap.javaVersion, "缺省即 nil，不得填 0 或假值")
        XCTAssertNil(snap.assetIndexID)
        XCTAssertNil(snap.clientDownloadURL)
    }

    /// 快照是可哈希的值类型 ⇒ 同内容相等、可进集合
    func testSnapshotIsHashableValueType() async throws {
        let json = #"{ "id": "m", "mainClass": "Main", "type": "release", "javaVersion": { "majorVersion": 17 } }"#
        let a = try snapshot(json)
        let b = try snapshot(json)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
    }
}
