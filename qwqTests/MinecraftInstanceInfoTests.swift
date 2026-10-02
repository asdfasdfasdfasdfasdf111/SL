//
//  MinecraftInstanceInfoTests.swift
//  qwqTests
//
//  覆盖 `Core/Minecraft/Module/MinecraftInstanceInfo.swift`
//  （`MinecraftLoaderKind` / `MinecraftVersionKind` / `MinecraftInstanceInfo`）。
//
//  **为什么值得测**：它是 `MinecraftInstance` 的**只读镜像** —— 后者构造即产生副作用
//  （解析清单、自动选 Java、写回 `.SL.json`），所以本模型特意把非 Sendable 的 SLCore 类型
//  镜像成自身枚举，供跨任务传递。镜像的映射规则错了，界面上就会把 Forge 实例显示成 NeoForge。
//
//  三条**注释点名**的性质，本文件逐条钉住：
//  1. `MinecraftLoaderKind(manifestText:)` 的判定顺序是
//     **neoforged → quilt → fabric → forge → vanilla** —— `neoforged` 必须排在 `forge` 之前，
//     否则含 "neoforged" 的清单会被先命中 `contains("forge")` 而误判；
//     `quilt` 检测排在 `fabric` 之前（quilt 清单含 quilted-fabric-api 字样）；
//  2. 旧实现**无法识别 quilt**（注释原话），2026-10-02 起按 `org.quiltmc:quilt-loader`
//     依赖名补全识别（见 testQuiltIsDetectableFromManifestText）；
//  3. `MinecraftVersionKind(rawVersionType:)` 对未识别取值**回落 `.release`**
//     —— 与 `MinecraftVersionInfo.kind` 刻意用可失败构造的做法相反（见另一测试文件）。
//

import XCTest
@testable import qwq

final class MinecraftInstanceInfoTests: XCTestCase {

    // MARK: - MinecraftLoaderKind(manifestText:)

    func testManifestTextDetection() async {
        XCTAssertEqual(MinecraftLoaderKind(manifestText: "net.fabricmc.loader.impl.Knot"), .fabric)
        XCTAssertEqual(MinecraftLoaderKind(manifestText: "net.minecraftforge.fml.Main"), .forge)
        XCTAssertEqual(MinecraftLoaderKind(manifestText: "net.neoforged.fml.Main"), .neoforge)
        XCTAssertEqual(MinecraftLoaderKind(manifestText: "net.minecraft.client.main.Main"), .vanilla)
    }

    /// ⚠️ **判定顺序**：`neoforged` 必须排在 `forge` 之前
    /// —— 含 "neoforged" 的串同时也含 "forge"，顺序反了就会误判成 Forge。
    func testNeoForgedIsCheckedBeforeForge() async {
        XCTAssertEqual(MinecraftLoaderKind(manifestText: "net.neoforged.fml.Main"), .neoforge,
                       "含 neoforged 必须先命中 neoforge，不能被 forge 抢先")
        XCTAssertEqual(MinecraftLoaderKind(manifestText: "neoforged"), .neoforge)
    }

    /// quilt 识别（2026-10-02 补全）：quilt 安装的清单文本里没有 "quilt" 字样，
    /// 但必含 `org.quiltmc:quilt-loader` 依赖（在 libraries 段）⇒ 现在可识别。
    /// 判定顺序：quilt 检测必须在 fabric 之前（quilt 清单含 quilted-fabric-api 字样）。
    func testQuiltIsDetectableFromManifestText() async {
        XCTAssertEqual(MinecraftLoaderKind(manifestText: "org.quiltmc:quilt-loader:0.26.1"), .quilt,
                       "quilt 依赖名出现在清单里必须识别为 quilt")
        // 顺序：含 fabric 相关字样的 quilt 清单必须先命中 quilt，不能被 fabric 抢先
        XCTAssertEqual(MinecraftLoaderKind(manifestText: "org.quiltmc:quilt-loader:0.26.1\norg.quiltmc:quilted-fabric-api:9.0"), .quilt,
                       "quilt 检测必须排在 fabric 之前")
    }

    /// 判定是**大小写敏感**的 `contains` ⇒ 只写 "Fabric"（首字母大写）认不出来
    func testDetectionIsCaseSensitive() async {
        XCTAssertEqual(MinecraftLoaderKind(manifestText: "Fabric"), .vanilla,
                       "contains 大小写敏感；真实清单里是小写的 net.fabricmc…")
        XCTAssertEqual(MinecraftLoaderKind(manifestText: "FORGE"), .vanilla)
    }

    /// 空串 ⇒ vanilla
    func testEmptyManifestTextYieldsVanilla() async {
        XCTAssertEqual(MinecraftLoaderKind(manifestText: ""), .vanilla)
    }

    // MARK: - MinecraftLoaderKind.displayName

    /// `neoforge` 单独处理为 "NeoForge"；其余取 `rawValue.capitalized`
    func testLoaderDisplayNames() async {
        XCTAssertEqual(MinecraftLoaderKind.vanilla.displayName, "Vanilla")
        XCTAssertEqual(MinecraftLoaderKind.fabric.displayName, "Fabric")
        XCTAssertEqual(MinecraftLoaderKind.quilt.displayName, "Quilt")
        XCTAssertEqual(MinecraftLoaderKind.forge.displayName, "Forge")
        XCTAssertEqual(MinecraftLoaderKind.neoforge.displayName, "NeoForge",
                       "neoforge 是特例：capitalized 会得到 Neoforge")
    }

    /// 除 neoforge 外，`displayName` 都等于 `rawValue.capitalized`
    func testDisplayNameEqualsCapitalizedRawValueExceptNeoForge() async {
        for kind in MinecraftLoaderKind.allCases where kind != .neoforge {
            XCTAssertEqual(kind.displayName, kind.rawValue.capitalized, "\(kind) 应等于 capitalized")
        }
        XCTAssertNotEqual(MinecraftLoaderKind.neoforge.displayName,
                          MinecraftLoaderKind.neoforge.rawValue.capitalized,
                          "前提：neoforge 确实是特例")
    }

    func testLoaderRawValues() async {
        XCTAssertEqual(MinecraftLoaderKind.allCases.map(\.rawValue),
                       ["vanilla", "fabric", "quilt", "forge", "neoforge"])
    }

    // MARK: - MinecraftVersionKind

    /// 取值字符串与 `VersionType` 的 rawValue 一致（含下划线拼写）
    func testVersionKindRawValues() async {
        XCTAssertEqual(MinecraftVersionKind.release.rawValue, "release")
        XCTAssertEqual(MinecraftVersionKind.snapshot.rawValue, "snapshot")
        XCTAssertEqual(MinecraftVersionKind.prerelease.rawValue, "pre-release")
        XCTAssertEqual(MinecraftVersionKind.rc.rawValue, "rc")
        XCTAssertEqual(MinecraftVersionKind.alpha.rawValue, "old_alpha")
        XCTAssertEqual(MinecraftVersionKind.beta.rawValue, "old_beta")
        XCTAssertEqual(MinecraftVersionKind.aprilFool.rawValue, "april_fool")
        XCTAssertEqual(MinecraftVersionKind.pending.rawValue, "pending")
    }

    /// ⚠️ **注释点名的回落**：未识别取值 ⇒ `.release`
    /// （与 `MinecraftVersionInfo.kind` 刻意不复用这条回落形成对照）
    func testUnrecognizedRawVersionTypeFallsBackToRelease() async {
        XCTAssertEqual(MinecraftVersionKind(rawVersionType: "totally-new"), .release)
        XCTAssertEqual(MinecraftVersionKind(rawVersionType: ""), .release)
        XCTAssertEqual(MinecraftVersionKind(rawVersionType: "Release"), .release,
                       "大小写不匹配同样回落（rawValue 是小写）")
    }

    /// 已识别取值不回落
    func testRecognizedRawVersionTypes() async {
        for kind in MinecraftVersionKind.allCases {
            XCTAssertEqual(MinecraftVersionKind(rawVersionType: kind.rawValue), kind,
                           "\(kind) 的 rawValue 必须可往返")
        }
    }

    // MARK: - MinecraftInstanceInfo 的派生路径

    private func makeInfo(name: String = "1.20.1",
                          dir: String = "/games/instances/1.20.1",
                          root: String = "/games",
                          versionName: String? = nil,
                          kind: MinecraftVersionKind = .release,
                          loader: MinecraftLoaderKind = .vanilla,
                          java: Int? = 17) -> MinecraftInstanceInfo {
        MinecraftInstanceInfo(
            name: name,
            runningDirectory: URL(fileURLWithPath: dir),
            minecraftRootDirectory: URL(fileURLWithPath: root),
            versionName: versionName ?? name,
            versionKind: kind,
            loader: loader,
            manifestJavaVersion: java
        )
    }

    /// `id` 取**标准化后**的版本目录绝对路径 ⇒ 同一目录的不同写法合并为同一条记录
    func testIDIsStandardizedRunningDirectoryPath() async {
        let withDot = makeInfo(dir: "/games/instances/../instances/1.20.1")
        XCTAssertEqual(withDot.id, "/games/instances/1.20.1",
                       "id 必须标准化，否则同一目录会因写法不同被当成两条")
    }

    /// 不同目录 ⇒ 不同 id
    func testDifferentDirectoriesYieldDifferentIDs() async {
        XCTAssertNotEqual(makeInfo(dir: "/a/v").id, makeInfo(dir: "/b/v").id)
    }

    /// 版本目录末段即实例名（默认夹具里两者一致）
    func testNameIsDirectoryLastComponentByConvention() async {
        XCTAssertEqual(makeInfo(name: "1.20.1", dir: "/games/versions/1.20.1").name, "1.20.1")
    }

    /// `manifestPath` = `<runningDirectory>/<name>.json`
    func testManifestPath() async {
        XCTAssertEqual(makeInfo(name: "1.20.1", dir: "/games/versions/1.20.1").manifestPath.path,
                       "/games/versions/1.20.1/1.20.1.json")
    }

    /// `configPath` = `<runningDirectory>/.SL.json`
    func testConfigPath() async {
        XCTAssertEqual(makeInfo(dir: "/games/versions/1.20.1").configPath.path,
                       "/games/versions/1.20.1/.SL.json")
    }

    /// `manifestJavaVersion` 可缺省为 nil（清单未声明）
    func testManifestJavaVersionCanBeNil() async {
        XCTAssertNil(makeInfo(java: nil).manifestJavaVersion)
    }

    // MARK: - 值语义

    /// `Hashable` 由全部存储属性合成 ⇒ 仅 `id` 相同不算相等（目录不同即不同）
    func testEqualityConsidersAllStoredFields() async {
        let a = makeInfo(dir: "/games/a")
        let b = makeInfo(dir: "/games/a")
        XCTAssertEqual(a, b)

        let differentLoader = makeInfo(dir: "/games/a", loader: .forge)
        XCTAssertNotEqual(a, differentLoader, "loader 不同即不等")
    }

    /// 可进集合（`Identifiable` + `Hashable`）
    func testUsableInSet() async {
        let infos = [makeInfo(dir: "/games/a"), makeInfo(dir: "/games/a"), makeInfo(dir: "/games/b")]
        XCTAssertEqual(Set(infos).count, 2)
    }

    /// `Sendable` 值类型：可安全跨并发域传递（这是本模型存在的**唯一理由**）
    func testIsSendableAcrossConcurrencyDomains() async {
        let info = makeInfo()
        let name = await Task.detached { info.name }.value
        XCTAssertEqual(name, "1.20.1")
    }

    /// 夹具前提：`MinecraftInstanceInfo` 的成员逐一 init 由编译器合成
    /// （结构体只在**扩展**里定义 init 不抑制合成；`init(_ instance:)` 正位于扩展中）
    func testMemberwiseInitIsAvailable() async {
        let info = makeInfo()
        XCTAssertEqual(info.versionKind, .release)
        XCTAssertEqual(info.loader, .vanilla)
    }
}
