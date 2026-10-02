//
//  VersionFolderMigrationTests.swift
//  版本目录规范化隔离（2026-10-02 收尾轮）的专项测试，验收 4 条：
//   1) 默认不干跑：读取路径（getVersions / localOwnedVersions）在开关默认关闭时不写磁盘；
//   2) 计划（plan）是纯只读的：只扫描不改名；
//   3) 执行（apply）按计划改名并同步 json id；
//   4) **中途失败的部分完成态**：写入新 json、删旧 json 之后目录移动失败，
//      必须回滚成「目录名仍旧 + json 恢复旧名」的一致状态（绝不留下无法识别的实例）。
//
// ⚠️ 测试用临时根目录搭建最小 versions/<version>/<version>.json 骨架，
// 不碰用户真实游戏目录；每例结束清理临时目录。
//

import XCTest
@testable import qwq

final class VersionFolderMigrationTests: XCTestCase {

    /// 临时游戏根目录（含 versions/）。
    private var tempGameRoot: String!

    // MARK: - 基建

    override func setUpWithError() throws {
        // 收尾时禁止环境里残留的开关影响本测试：每个用例前都显式复位为默认关。
        MinecraftVersionManager.autoNormalizeOnRead = false
        let root = NSTemporaryDirectory() + "VersionFolderMigrationTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/versions", withIntermediateDirectories: true)
        tempGameRoot = root
    }

    override func tearDownWithError() throws {
        if let root = tempGameRoot {
            try? FileManager.default.removeItem(atPath: root)
        }
        tempGameRoot = nil
        MinecraftVersionManager.autoNormalizeOnRead = false
    }

    private func versionsPath() -> String { tempGameRoot! + "/versions" }

    /// 造一个版本目录：versions/<name>/<name>.json（可带 loader 痕迹）。
    private func makeVersionDirectory(
        _ name: String,
        json: [String: Any]
    ) throws {
        let dir = versionsPath() + "/\(name)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: dir + "/\(name).json"))
    }

    private func forgeJSON() -> [String: Any] {
        // libraries 里含 net.minecraftforge:forge → 会被 detectLoaderName 识别为 Forge
        [
            "id": "1.6.1",
            "libraries": [
                ["name": "net.minecraftforge:forge:8.9.0.753"],
                ["name": "net.minecraft:launchwrapper:1.12"]
            ]
        ]
    }

    private func vanillaJSON() -> [String: Any] {
        ["id": "1.21.1", "libraries": [["name": "net.minecraft:launchwrapper:1.12"]]]
    }

    private func directoryNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: versionsPath())) ?? []
    }

    private func jsonIDs(in dirName: String) -> [String] {
        let dir = versionsPath() + "/\(dirName)"
        return (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    }

    // MARK: - 默认不干跑（验收 1）

    func testGetVersionsDefaultDoesNotRename() throws {
        try makeVersionDirectory("1.6.1", json: forgeJSON())
        try makeVersionDirectory("1.21.1", json: vanillaJSON())

        // 开关默认关 —— 读取路径不带写副作用
        XCTAssertFalse(MinecraftVersionManager.autoNormalizeOnRead, "迁移期开关必须默认关闭")
        let versions = MinecraftVersionManager.getVersions(from: tempGameRoot!)

        // 目录没被改名：纯版本号原样保留
        XCTAssertEqual(Set(versions), Set(["1.6.1", "1.21.1"]))
        XCTAssertEqual(Set(directoryNames()), Set(["1.6.1", "1.21.1"]),
                       "getVersions 默认不得重命名目录")
    }

    func testLocalOwnedVersionsDefaultDoesNotRename() throws {
        try makeVersionDirectory("1.6.1", json: forgeJSON())

        let owned = GameDirectoryScanner.localOwnedVersions(gameRoot: tempGameRoot!)

        XCTAssertEqual(owned, ["1.6.1"])
        XCTAssertEqual(Set(directoryNames()), Set(["1.6.1"]),
                       "localOwnedVersions 默认不得重命名目录")
    }

    // MARK: - 计划只读（验收 2）

    func testPlanIsReadOnly() throws {
        try makeVersionDirectory("1.6.1", json: forgeJSON())
        try makeVersionDirectory("1.21.1", json: vanillaJSON())

        let plan = MinecraftVersionManager.planVersionFolderRenames(gameRoot: tempGameRoot!)

        // 只给出计划：纯版本号 + 有 forge 痕迹 → 计划为 Forge
        XCTAssertEqual(plan, ["1.6.1": "1.6.1-Forge"])
        // 磁盘未动：目录名与 json 内容原样
        XCTAssertEqual(Set(directoryNames()), Set(["1.6.1", "1.21.1"]))
        XCTAssertEqual(jsonIDs(in: "1.6.1").sorted(), ["1.6.1.json"])
    }

    func testPlanSkipsAlreadyNamedAndVanilla() throws {
        try makeVersionDirectory("1.20.1-Forge", json: forgeJSON())
        try makeVersionDirectory("1.21.1", json: vanillaJSON())

        let plan = MinecraftVersionManager.planVersionFolderRenames(gameRoot: tempGameRoot!)
        // 已带后缀的目录跳过；纯原版（无 loader 痕迹）也跳过
        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: - 执行成功（验收 3）

    func testApplyRenamesAndSyncsJSON() throws {
        try makeVersionDirectory("1.6.1", json: forgeJSON())

        let plan = MinecraftVersionManager.planVersionFolderRenames(gameRoot: tempGameRoot!)
        let applied = MinecraftVersionManager.applyVersionFolderRenames(gameRoot: tempGameRoot!, plan: plan)

        XCTAssertEqual(applied, ["1.6.1": "1.6.1-Forge"])
        // 目录已改名
        XCTAssertEqual(Set(directoryNames()), Set(["1.6.1-Forge"]))
        // 新目录里只有新名 json，且其 id 字段同步为新名
        XCTAssertEqual(jsonIDs(in: "1.6.1-Forge").sorted(), ["1.6.1-Forge.json"])
        let data = try Data(contentsOf: URL(fileURLWithPath: versionsPath() + "/1.6.1-Forge/1.6.1-Forge.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["id"] as? String, "1.6.1-Forge")
    }

    // MARK: - 中途失败的部分完成态回滚（验收 4）

    func testApplyRollsBackWhenMoveFails() throws {
        try makeVersionDirectory("1.6.1", json: forgeJSON())
        let plan = MinecraftVersionManager.planVersionFolderRenames(gameRoot: tempGameRoot!)
        XCTAssertEqual(plan, ["1.6.1": "1.6.1-Forge"])

        // 注入「目录移动必失败」：模拟写新 json、删旧 json 之后移动目录这一步抛错。
        let applied = MinecraftVersionManager.applyVersionFolderRenames(
            gameRoot: tempGameRoot!,
            plan: plan,
            moveItem: { _, _ in throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟移动失败"]) }
        )

        // 该目录未记为已重命名
        XCTAssertTrue(applied.isEmpty)

        // **部分完成态断言**：目录名必须仍旧（1.6.1），
        // 且目录内 json 被回滚为旧名（1.6.1.json），id 仍是旧值 —— 实例保持可识别。
        XCTAssertEqual(Set(directoryNames()), Set(["1.6.1"]), "移动失败后目录名必须仍旧")
        XCTAssertEqual(jsonIDs(in: "1.6.1").sorted(), ["1.6.1.json"],
                       "移动失败后必须回滚 json 名：不得残留新名 json")
        let data = try Data(contentsOf: URL(fileURLWithPath: versionsPath() + "/1.6.1/1.6.1.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["id"] as? String, "1.6.1", "回滚后 json id 必须恢复旧值")
    }

    func testApplySkipsWhenTargetAlreadyExists() throws {
        // 目标目录已被别的写入者占用（plan 之后、apply 之前出现）→ apply 不得覆盖
        try makeVersionDirectory("1.6.1", json: forgeJSON())
        try FileManager.default.createDirectory(atPath: versionsPath() + "/1.6.1-Forge", withIntermediateDirectories: true)

        // 计划在「目标已存在」之前生成（plan 时目标还不存在），apply 时目标已存在
        let plan = ["1.6.1": "1.6.1-Forge"]
        let applied = MinecraftVersionManager.applyVersionFolderRenames(gameRoot: tempGameRoot!, plan: plan)

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(Set(directoryNames()), Set(["1.6.1", "1.6.1-Forge"]))
        // 原目录未被覆盖、json 未被动
        XCTAssertEqual(jsonIDs(in: "1.6.1").sorted(), ["1.6.1.json"])
    }

    // MARK: - 迁移期开关（默认关的持久化）

    func testAutoNormalizeSwitchPersistence() {
        let key = "autoNormalizeVersionFolders"

        // 默认关
        XCTAssertFalse(MinecraftVersionManager.autoNormalizeOnRead)

        // 开 → 落盘
        MinecraftVersionManager.autoNormalizeOnRead = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
        XCTAssertTrue(MinecraftVersionManager.autoNormalizeOnRead)

        // 关回
        MinecraftVersionManager.autoNormalizeOnRead = false
        XCTAssertFalse(MinecraftVersionManager.autoNormalizeOnRead)

        // 清掉测试残留 key，避免后续用例被污染（setUp 里也已复位开关）
        UserDefaults.standard.removeObject(forKey: key)
    }
}