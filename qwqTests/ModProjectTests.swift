//
//  ModProjectTests.swift
//  qwqTests
//
//  覆盖 `Features/ModBrowser/Module/ModProject.swift`。
//
//  **为什么值得测**：同一份 Modrinth 项目在工程里有**四种并存的表达**
//  （`ModrinthMod` 搜索命中 / `ModrinthProject` 详情响应 / `LocalModCatalog.Item` 本地全量目录 /
//  `DownloadedItem` 分类页渲染单元），本文件把它们收敛为 `ModProject`。
//
//  四个转换 init **各自丢失的字段不同**，且源码逐条写明了：
//  - 搜索命中：不带分类 ⇒ `categories` 为空；带 `versionIDs`；
//  - 详情响应：**不返回简介、图标、下载量** ⇒ 三者 nil；`title` 缺失时回落 `id`；
//  - 本地目录：**不含 slug**、`versionIDs` 为空；
//  - 分类页单元：下载量与版本列表**已丢失**。
//
//  把这些「丢字段」的差异钉住，是为了让调用方不会误以为某个字段一定有值
//  （源码原话：「调用方需自行判断可得性，不要假定某字段一定有值」）。
//

import XCTest
@testable import qwq

final class ModProjectTests: XCTestCase {

    // MARK: - ModProjectType

    func testProjectTypeRawValues() async {
        XCTAssertEqual(ModProjectType.allCases.map(\.rawValue),
                       ["mod", "resourcepack", "shader", "modpack"])
    }

    /// 展示名是中文，且注释要求与 `LocalModCatalog.preTranslateAll` 保持一致
    func testProjectTypeDisplayNames() async {
        XCTAssertEqual(ModProjectType.mod.displayName, "模组")
        XCTAssertEqual(ModProjectType.resourcepack.displayName, "资源包")
        XCTAssertEqual(ModProjectType.shader.displayName, "光影")
        XCTAssertEqual(ModProjectType.modpack.displayName, "整合包")
    }

    func testProjectTypeRawValueRoundTrip() async {
        for t in ModProjectType.allCases {
            XCTAssertEqual(ModProjectType(rawValue: t.rawValue), t)
        }
        XCTAssertNil(ModProjectType(rawValue: "shaders"), "上游拼写是 shader 单数")
    }

    // MARK: - ModProjectFile

    func testFileSHA1ComesFromHashes() async {
        let file = ModProjectFile(url: "https://x/a.jar", filename: "a.jar",
                                  isPrimary: true, size: 10,
                                  hashes: ["sha1": "abc", "sha512": "def"])
        XCTAssertEqual(file.sha1, "abc")
    }

    /// 接口未返回 hashes ⇒ 空字典 ⇒ `sha1` 为 nil（调用方需自行处理）
    func testFileSHA1IsNilWhenHashesEmpty() async {
        let file = ModProjectFile(url: "u", filename: "f", isPrimary: false, size: 0, hashes: [:])
        XCTAssertNil(file.sha1)
    }

    /// 只有 sha512 时 `sha1` 仍为 nil（不做算法间推导）
    func testFileSHA1IsNilWhenOnlySHA512Present() async {
        let file = ModProjectFile(url: "u", filename: "f", isPrimary: false, size: 0,
                                  hashes: ["sha512": "def"])
        XCTAssertNil(file.sha1)
    }

    /// 由 `ModrinthVersion.ModrinthFile` 转换：`hashes` 为 nil 时归一成空字典
    func testFileConversionNormalizesNilHashesToEmpty() async {
        let source = ModrinthVersion.ModrinthFile(url: "https://x/a.jar", filename: "a.jar",
                                                  primary: true, size: 42, hashes: nil)
        let converted = ModProjectFile(source)
        XCTAssertEqual(converted.url, "https://x/a.jar")
        XCTAssertEqual(converted.filename, "a.jar")
        XCTAssertTrue(converted.isPrimary)
        XCTAssertEqual(converted.size, 42)
        XCTAssertEqual(converted.hashes, [:], "nil hashes 必须归一成空字典，而非保留 nil")
        XCTAssertNil(converted.sha1)
    }

    // MARK: - ModProjectVersion.primaryFile

    private func file(_ name: String, primary: Bool) -> ModProjectFile {
        ModProjectFile(url: "https://x/\(name)", filename: name, isPrimary: primary, size: 1, hashes: [:])
    }

    private func version(files: [ModProjectFile]) -> ModProjectVersion {
        ModProjectVersion(id: "v1", name: "V1", versionNumber: "1.0",
                          gameVersions: ["1.20.1"], loaders: ["fabric"], files: files)
    }

    /// 优先取 `primary` 标记的文件（即使它不在第一位）
    func testPrimaryFilePrefersPrimaryFlag() async {
        let v = version(files: [file("a.jar", primary: false), file("b.jar", primary: true)])
        XCTAssertEqual(v.primaryFile?.filename, "b.jar")
    }

    /// 没有任何 `primary` ⇒ 取**首个**文件
    func testPrimaryFileFallsBackToFirst() async {
        let v = version(files: [file("a.jar", primary: false), file("b.jar", primary: false)])
        XCTAssertEqual(v.primaryFile?.filename, "a.jar")
    }

    /// 文件列表为空 ⇒ nil（不崩）
    func testPrimaryFileIsNilWhenNoFiles() async {
        XCTAssertNil(version(files: []).primaryFile)
    }

    /// 多个 primary ⇒ 取**第一个** primary（`first(where:)` 语义）
    func testPrimaryFileTakesFirstPrimaryWhenMultiple() async {
        let v = version(files: [file("a.jar", primary: true), file("b.jar", primary: true)])
        XCTAssertEqual(v.primaryFile?.filename, "a.jar")
    }

    // MARK: - 四个转换 init：各自丢哪些字段

    /// 搜索命中（`ModrinthMod`）：**不带分类** ⇒ `categories` 为空；带 `versionIDs`
    func testInitFromSearchHit() async {
        let mod = ModrinthMod(id: "p1", slug: "s1", title: "T", description: "D",
                              icon_url: "https://x/i.png", downloads: 123, versions: ["v1", "v2"])
        let project = ModProject(mod, projectType: .mod)

        XCTAssertEqual(project.id, "p1")
        XCTAssertEqual(project.slug, "s1")
        XCTAssertEqual(project.title, "T")
        XCTAssertEqual(project.description, "D")
        XCTAssertEqual(project.iconURL, "https://x/i.png")
        XCTAssertEqual(project.downloads, 123)
        XCTAssertEqual(project.versionIDs, ["v1", "v2"], "搜索命中带版本 ID")
        XCTAssertEqual(project.categories, [], "搜索接口不携带分类 ⇒ 空数组")
        XCTAssertEqual(project.gameVersions, [])
        XCTAssertEqual(project.loaders, [])
        XCTAssertEqual(project.projectType, .mod)
    }

    /// 搜索命中的 `projectType` 是**外部传入**的（接口不返回），缺省为 nil
    func testSearchHitProjectTypeDefaultsToNil() async {
        let mod = ModrinthMod(id: "p", slug: "s", title: "T", description: nil,
                              icon_url: nil, downloads: 0, versions: [])
        XCTAssertNil(ModProject(mod).projectType)
    }

    /// 详情响应（`ModrinthProject`）：**不返回简介/图标/下载量** ⇒ 三者 nil；`slug` nil
    func testInitFromProjectDetail() async {
        let detail = ModrinthProject(id: "p2", title: "Title",
                                     game_versions: ["1.20.1"], loaders: ["fabric"])
        let project = ModProject(detail)

        XCTAssertEqual(project.id, "p2")
        XCTAssertEqual(project.title, "Title")
        XCTAssertNil(project.slug, "详情接口不返回 slug")
        XCTAssertNil(project.description, "详情接口不返回简介")
        XCTAssertNil(project.iconURL, "详情接口不返回图标")
        XCTAssertNil(project.downloads, "详情接口不返回下载量")
        XCTAssertEqual(project.gameVersions, ["1.20.1"], "详情接口提供游戏版本")
        XCTAssertEqual(project.loaders, ["fabric"], "详情接口提供加载器")
        XCTAssertEqual(project.versionIDs, [])
        XCTAssertNil(project.projectType)
    }

    /// **`title` 缺失时回落 `id`**（注释：「`title: project.title ?? project.id`」）
    func testProjectDetailTitleFallsBackToID() async {
        let detail = ModrinthProject(id: "fallback-id", title: nil,
                                     game_versions: nil, loaders: nil)
        let project = ModProject(detail)
        XCTAssertEqual(project.title, "fallback-id", "title 缺失应回落 id，而不是空串")
    }

    /// 详情响应的可缺省数组归一成空数组（而非保留 nil）
    func testProjectDetailOptionalArraysBecomeEmpty() async {
        let detail = ModrinthProject(id: "p", title: "T", game_versions: nil, loaders: nil)
        let project = ModProject(detail)
        XCTAssertEqual(project.gameVersions, [])
        XCTAssertEqual(project.loaders, [])
    }

    /// 本地目录条目（`LocalModCatalog.Item`）：**不含 slug**、`versionIDs` 为空
    func testInitFromLocalCatalogItem() async {
        let item = LocalModCatalog.Item(projectID: "p3", projectType: "shader", title: "S",
                                        description: "desc", categories: ["光影"],
                                        iconURL: "https://x/s.png", downloads: 9)
        let project = ModProject(item)

        XCTAssertEqual(project.id, "p3")
        XCTAssertEqual(project.title, "S")
        XCTAssertEqual(project.description, "desc")
        XCTAssertEqual(project.categories, ["光影"], "本地目录携带分类")
        XCTAssertEqual(project.downloads, 9)
        XCTAssertNil(project.slug, "本地目录不含 slug")
        XCTAssertEqual(project.versionIDs, [], "本地目录不含版本 ID")
        XCTAssertEqual(project.gameVersions, [])
        XCTAssertEqual(project.loaders, [])
        XCTAssertEqual(project.projectType, .shader, "projectType 由字符串 rawValue 转换")
    }

    /// 本地目录的 `projectType` 字符串无法识别 ⇒ nil（可失败构造，不崩）
    func testLocalCatalogUnknownProjectTypeBecomesNil() async {
        let item = LocalModCatalog.Item(projectID: "p", projectType: "something-new", title: "T",
                                        description: "", categories: [], iconURL: nil, downloads: 0)
        XCTAssertNil(ModProject(item).projectType)
    }

    /// 分类页单元（`DownloadedItem`）：`name`→`title`、`subtitle`→`description`、
    /// `tags`→`categories`，而**下载量与版本列表已丢失**
    func testInitFromDownloadedItem() async {
        let item = DownloadedItem(id: "p4", name: "Name", subtitle: "Sub",
                                  iconURL: "https://x/i.png", tags: ["科技", "魔法"])
        let project = ModProject(item, projectType: .mod)

        XCTAssertEqual(project.id, "p4")
        XCTAssertEqual(project.title, "Name", "DownloadedItem.name → ModProject.title")
        XCTAssertEqual(project.description, "Sub", "DownloadedItem.subtitle → ModProject.description")
        XCTAssertEqual(project.categories, ["科技", "魔法"], "tags → categories")
        XCTAssertEqual(project.iconURL, "https://x/i.png")
        XCTAssertNil(project.downloads, "分类页单元已丢失下载量")
        XCTAssertEqual(project.versionIDs, [], "分类页单元已丢失版本列表")
        XCTAssertNil(project.slug)
        XCTAssertEqual(project.projectType, .mod)
    }

    // MARK: - 值语义

    /// `ModProject` 是可哈希值类型
    func testModProjectIsHashableValueType() async {
        let a = ModProject(id: "p", slug: nil, title: "T", description: nil, iconURL: nil,
                           downloads: nil, categories: [], gameVersions: [], loaders: [],
                           versionIDs: [], projectType: .mod)
        let b = ModProject(id: "p", slug: nil, title: "T", description: nil, iconURL: nil,
                           downloads: nil, categories: [], gameVersions: [], loaders: [],
                           versionIDs: [], projectType: .mod)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    /// `ModProjectVersion` 的 `id` 直接来自版本 ID（`Identifiable`）
    func testVersionIdentity() async {
        let v = version(files: [])
        XCTAssertEqual(v.id, "v1")
        XCTAssertEqual(v.gameVersions, ["1.20.1"])
        XCTAssertEqual(v.loaders, ["fabric"])
    }
}
