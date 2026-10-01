//
//  ModrinthSectionTypeTests.swift
//  qwqTests
//
//  覆盖 `Features/ModBrowser/ModrinthSectionType.swift`
//  （侧边栏分类 → Modrinth `project_type` 查询参数）。
//
//  **为什么值得测**：映射错会让某个分类页**请求到错误类型的内容**
//  （例如资源包页显示模组），而接口不会报错。
//  实现只有一张 switch 表，但「`.game` 返回 nil」是关键分支 ——
//  游戏版本页**不是** Modrinth 检索，返回非 nil 会让它去请求 `project_type=game`（不存在）。
//
//  ⚠️ 映射值的拼写必须与 Modrinth 接口一致（`resourcepack` 无空格、`shader` 单数），
//  本文件把每个取值逐字钉住。
//

import XCTest
@testable import qwq

final class ModrinthSectionTypeTests: XCTestCase {

    /// 四个 Modrinth 分类各自映射到对应的 `project_type` 字符串
    func testModrinthSectionsMapToProjectTypes() async {
        XCTAssertEqual(ModrinthSectionType.type(for: .mod), "mod")
        XCTAssertEqual(ModrinthSectionType.type(for: .resourcePack), "resourcepack")
        XCTAssertEqual(ModrinthSectionType.type(for: .shader), "shader")
        XCTAssertEqual(ModrinthSectionType.type(for: .modpack), "modpack")
    }

    /// ⚠️ 游戏版本页**不是** Modrinth 检索 ⇒ nil
    func testGameSectionHasNoModrinthType() async {
        XCTAssertNil(ModrinthSectionType.type(for: .game),
                     "游戏版本页走的是 Mojang 清单，不是 Modrinth 检索")
    }

    /// 五个分类都有明确结论：四个非 nil、一个 nil（不多不少）
    func testAllSectionsAreCovered() async {
        let mapped = GameSidebarSection.allCases.compactMap(ModrinthSectionType.type(for:))
        XCTAssertEqual(mapped.count, 4, "五个侧边栏分类里恰好四个有 Modrinth 类型")
        XCTAssertEqual(Set(mapped), ["mod", "resourcepack", "shader", "modpack"])
    }

    /// 拼写与 Modrinth 接口对齐：`resourcepack` 无连字符/空格、`shader` 单数
    func testSpellingMatchesModrinthAPI() async {
        XCTAssertEqual(ModrinthSectionType.type(for: .resourcePack), "resourcepack")
        XCTAssertNotEqual(ModrinthSectionType.type(for: .resourcePack), "resource-pack")
        XCTAssertEqual(ModrinthSectionType.type(for: .shader), "shader")
        XCTAssertNotEqual(ModrinthSectionType.type(for: .shader), "shaders")
    }

    /// 与 `ModProjectType.rawValue` 同集合（两者描述的是同一件事，分开维护会漂移）
    func testMappingAgreesWithModProjectTypeRawValues() async {
        let fromSections = Set(GameSidebarSection.allCases.compactMap(ModrinthSectionType.type(for:)))
        let fromProjectTypes = Set(ModProjectType.allCases.map(\.rawValue))
        XCTAssertEqual(fromSections, fromProjectTypes,
                       "侧边栏映射与 ModProjectType 的 rawValue 必须同集合")
    }
}
