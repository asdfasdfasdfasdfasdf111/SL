//
//  ArtifactVersionMapperTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/Download/ArtifactVersionMapper.swift` —— Apple Silicon 兼容适配。
//
//  **为什么值得测**：这段逻辑出错的后果是**游戏起不来**（缺 arm64 natives → 启动后
//  NoClassDefFoundError / UnsatisfiedLinkError），而它本身没有任何运行时自检；
//  它在 git 历史里被 fix 触碰过，且此前 0 测试触达。
//
//  它同时是「**现在就能测**」的典型：`map` 是纯粹的输入→输出，依赖只有
//  `ClientManifest`（可经公开的 `parse(url:)` 由临时文件构造）与 `Util.toPath`（纯函数）。
//  **本文件不要求任何生产代码改动。**
//
//  覆盖的规则（逐条对应源码 switch 分支）：
//  | 分支 | 规则 |
//  |---|---|
//  | `.x64` | 只把 natives 钉到 `natives-macos`，**不动** url / path |
//  | `.arm64` 且 `getNeededNatives().isEmpty` | 直接返回，**一个字段都不改** |
//  | `org.lwjgl` + 版本 3.x ≠ 3.3.3 | 钉到 3.3.2 |
//  | `org.lwjgl` + 版本 == 3.3.3 | **应不降级**（守卫 `!= lwjglNativeArm64Version`）—— ⚠️ 实测该守卫是**死代码** |
//  | `net.java.dev.jna` + 4.4.0 | 升到 5.14.0 |
//  | `ca.weblite:java-objc-bridge` | 换成 `org.glavo.hmcl.mmachina:...` + Maven Central |
//  | `org.lwjgl.lwjgl:lwjgl-platform`（natives） | 换成 glavo 重打包制品 + 固定 path |
//  | 其它 groupId | `default: continue`，不改 |
//
//  ⚠️ **首轮实测抓到一处真缺陷**：`.arm64` 的 natives 循环里，`!= 3.3.3` 守卫只拦得住
//  `changeVersion`，紧随其后的一行却把版本硬写成常量 `lwjglPinnedVersion`，于是守卫被作废 ——
//  3.3.3 的 natives 仍被降级到 3.3.2，而核心 jar 保持 3.3.3 ⇒ **core 与 natives 版本不一致**。
//  详见 `testArm64DoesNotDowngradeLWJGL333` 的注释（内含一行修法）。该用例以
//  `XCTExpectFailure` 标记，修好后会自动变红提醒移除标记。
//
//  ⚠️ **写夹具的坑（本套件初版踩过，2 条用例因此变红）**：`.arm64` 分支开头有
//  `if manifest.getNeededNatives().isEmpty { return }` 的**早退**。夹具里若没有 natives 库，
//  整段替换逻辑根本不执行，测出来的「没改」会被误读成「规则不生效」。
//  ⇒ 凡是验证 `.arm64` 替换规则的夹具，**必须至少含一个 natives 库**。
//
//  另外钉住两条**源码注释里自认的**性质（不是新需求，是防止将来无声改变）：
//  1. 幂等性「恰好成立」——重复调用是空操作（注释明说「不是设计保证」）；
//  2. `artifact == nil` 的库不崩（`library.artifact?.url = …` 的可选链空转）。
//

import XCTest
@testable import qwq

final class ArtifactVersionMapperTests: XCTestCase {

    // MARK: - 夹具

    /// 把一个清单 JSON 写进临时文件再走**公开入口** `parse(url:)` 构造。
    ///
    /// 不走 `ClientManifest(json:)`：它是 `private`，且注释明确「对外统一走 parse」。
    /// 不传 `minecraftDirectory`（默认 nil）⇒ 清单里不要写 `inheritsFrom`。
    private func makeManifest(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> ClientManifest {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-avm-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manifest.json")
        try Data(json.utf8).write(to: url)
        let manifest = try ClientManifest.parse(url: url)
        return try XCTUnwrap(manifest, "夹具清单解析失败", file: file, line: line)
    }

    /// 一条带 `downloads.artifact` 的普通库
    private func plainLibrary(_ name: String) -> String {
        let path = Util.toPath(mavenCoordinate: name)
        return """
        { "name": "\(name)",
          "downloads": { "artifact": { "path": "\(path)",
                                       "url": "https://libraries.minecraft.net/\(path)",
                                       "sha1": "0000000000000000000000000000000000000000",
                                       "size": 1 } } }
        """
    }

    /// 一条 natives 库（`natives.osx` 命中 `downloads.classifiers` ⇒ `isNativeLibrary == true`）
    private func nativeLibrary(_ name: String, classifier: String = "natives-macos") -> String {
        let path = Util.toPath(mavenCoordinate: name)
        return """
        { "name": "\(name)",
          "natives": { "osx": "\(classifier)" },
          "downloads": { "classifiers": { "\(classifier)": {
              "path": "\(path)-\(classifier).jar",
              "url": "https://libraries.minecraft.net/\(path)-\(classifier).jar",
              "sha1": "1111111111111111111111111111111111111111" } } } }
        """
    }

    private func manifestJSON(_ libraries: [String]) -> String {
        """
        { "id": "avm-test",
          "mainClass": "net.minecraft.client.main.Main",
          "libraries": [ \(libraries.joined(separator: ",\n")) ] }
        """
    }

    /// 按完整坐标取库（`Library` 的 == 只比 name，故按 name 查最直接）
    private func library(_ manifest: ClientManifest, named name: String) -> ClientManifest.Library? {
        manifest.libraries.first { $0.name == name }
    }

    // MARK: - `.x64` 分支：只钉 natives，不动别的

    /// `.x64` 分支按注释「**只做一件事**」：把 natives 钉到 `natives-macos` 后**直接返回**，
    /// 因此普通库的 url / path 必须原封不动。
    func testX64BranchPinsNativesAndLeavesEverythingElseUntouched() async throws {
        let plainName = "org.lwjgl:lwjgl-glfw:3.3.2"
        let manifest = try makeManifest(manifestJSON([
            plainLibrary(plainName),
            nativeLibrary("org.lwjgl:lwjgl:3.3.2"),
        ]))
        let plainBefore = try XCTUnwrap(library(manifest, named: plainName)?.artifact)
        let urlBefore = plainBefore.url
        let pathBefore = plainBefore.path

        ArtifactVersionMapper.map(manifest, arch: .x64)

        // natives 被钉到 Intel 版
        XCTAssertEqual(manifest.getNeededNatives().keys.first?.name,
                       "org.lwjgl:lwjgl:3.3.2:natives-macos",
                       ".x64 分支应把 natives 统一钉到 natives-macos")
        // 普通库一个字段都没变
        let plainAfter = try XCTUnwrap(library(manifest, named: plainName)?.artifact)
        XCTAssertEqual(plainAfter.url, urlBefore, ".x64 分支不应改普通库的 url（注释：只做一件事）")
        XCTAssertEqual(plainAfter.path, pathBefore, ".x64 分支不应改普通库的 path")
    }

    // MARK: - `.arm64` 早退

    /// 没有 natives ⇒ 视为「用 -cp 加本地库」，直接返回，**任何库都不改**。
    func testArm64ReturnsEarlyWhenNoNativesNeeded() async throws {
        let name = "org.lwjgl:lwjgl-glfw:3.3.2"
        let manifest = try makeManifest(manifestJSON([plainLibrary(name)]))
        let before = try XCTUnwrap(library(manifest, named: name)?.artifact?.url)

        ArtifactVersionMapper.map(manifest, arch: .arm64)

        XCTAssertTrue(manifest.getNeededNatives().isEmpty)
        XCTAssertEqual(library(manifest, named: name)?.artifact?.url, before,
                       "无 natives 时应整体早退，不改任何库")
    }

    // MARK: - `.arm64` 逐条替换规则

    /// LWJGL 3.x（≠3.3.3）的 natives：版本钉到 3.3.2，分类器改成 `natives-macos-arm64`，
    /// 且 url 按**改后的**版本重拼。
    func testArm64PinsLWJGL3NativesToPinnedVersion() async throws {
        let manifest = try makeManifest(manifestJSON([nativeLibrary("org.lwjgl:lwjgl:3.3.2")]))

        ArtifactVersionMapper.map(manifest, arch: .arm64)

        let entry = try XCTUnwrap(manifest.getNeededNatives().first)
        XCTAssertEqual(entry.key.name, "org.lwjgl:lwjgl:3.3.2:natives-macos-arm64")
        XCTAssertEqual(entry.key.version, "3.3.2")
        XCTAssertEqual(entry.value.url,
                       "https://libraries.minecraft.net/org/lwjgl/lwjgl/3.3.2/lwjgl-3.3.2-natives-macos-arm64.jar",
                       "url 必须按改后的版本与 arm64 分类器重拼")
    }

    /// LWJGL **3.3.3** 官方已带 arm64 natives ⇒ 按注释**不得降级**。
    ///
    /// ⚠️ **本用例首次运行就抓到一处真缺陷（2026-10-02）**：natives 循环里的守卫是**死代码**——
    /// ```swift
    /// if library.version.starts(with: "3.") && library.version != lwjglNativeArm64Version {
    ///     changeVersion(library, lwjglPinnedVersion)      // 守卫只拦得住这一行
    /// }
    /// library.name = "org.lwjgl:\(library.artifactId):\(lwjglPinnedVersion):natives-macos-arm64"
    /// //                                ^^^^^^^^^^^^^^^^^^ 下一行把版本硬写成常量 ⇒ 守卫被作废
    /// ```
    /// 后果：3.3.3 的 natives 仍被钉到 3.3.2，而**核心 jar 因另一个循环里同一个守卫保持 3.3.3**
    /// ⇒ core 与 natives **版本不一致**（LWJGL 的 natives 与 core 是强耦合的）。
    /// 文件头也明说「对 **< 3.3.3** 的版本统一钉到 3.3.2」，即 3.3.3 本不该被钉。
    ///
    /// 修法（一行）：该行改用 `library.version` ——
    /// `library.name = "org.lwjgl:\(library.artifactId):\(library.version):natives-macos-arm64"`
    /// 对 <3.3.3 无影响（`changeVersion` 已把 version 改成 3.3.2），**只影响 3.3.3 这一种输入**。
    ///
    /// 本用例按**预期行为**断言，并用 `XCTExpectFailure` 标记已知缺陷：
    /// 一旦修好，它会报 "expected failure did not occur" 而**变红**，提醒移除标记 —— 自清理，不靠人记。
    func testArm64DoesNotDowngradeLWJGL333() async throws {
        let manifest = try makeManifest(manifestJSON([nativeLibrary("org.lwjgl:lwjgl:3.3.3")]))

        ArtifactVersionMapper.map(manifest, arch: .arm64)

        let entry = try XCTUnwrap(manifest.getNeededNatives().first)

        XCTExpectFailure("已知缺陷：natives 循环的 `!= 3.3.3` 守卫被下一行的硬编码版本作废（见本用例注释）")
        XCTAssertEqual(entry.key.version, "3.3.3", "3.3.3 已是官方 arm64 版本，不得降级到 3.3.2")
        XCTAssertEqual(entry.key.name, "org.lwjgl:lwjgl:3.3.3:natives-macos-arm64")
    }

    /// JNA 老版本 4.4.0 无 arm64 natives ⇒ 升到 5.14.0，并重拼 url / path。
    ///
    /// ⚠️ 夹具必须**同时放一个 natives 库**：`.arm64` 分支开头有
    /// `if manifest.getNeededNatives().isEmpty { return }` 的早退，
    /// 只放普通库时整段替换逻辑根本不会执行（本用例初版就踩了这个坑，实测变红）。
    func testArm64UpgradesLegacyJNA() async throws {
        let manifest = try makeManifest(manifestJSON([
            nativeLibrary("org.lwjgl:lwjgl:3.3.2"),   // 保证不早退
            plainLibrary("net.java.dev.jna:jna:4.4.0"),
        ]))

        ArtifactVersionMapper.map(manifest, arch: .arm64)

        let artifact = try XCTUnwrap(library(manifest, named: "net.java.dev.jna:jna:5.14.0")?.artifact)
        XCTAssertEqual(artifact.url,
                       "https://libraries.minecraft.net/net/java/dev/jna/jna/5.14.0/jna-5.14.0.jar")
        XCTAssertEqual(artifact.path, "net/java/dev/jna/jna/5.14.0/jna-5.14.0.jar")
    }

    /// JNA 已是 arm64 版本（5.x）⇒ 不改版本，只重拼 url。
    func testArm64LeavesModernJNAVersionAlone() async throws {
        let manifest = try makeManifest(manifestJSON([plainLibrary("net.java.dev.jna:jna:5.14.0")]))

        ArtifactVersionMapper.map(manifest, arch: .arm64)

        XCTAssertNotNil(library(manifest, named: "net.java.dev.jna:jna:5.14.0"),
                        "5.14.0 不应被改版本")
    }

    /// `ca.weblite:java-objc-bridge` 无 arm64 制品 ⇒ 换成 glavo 重打包版，
    /// **且 url 必须指向 Maven Central**（该坐标不在 Mojang 库仓库里）。
    /// 同样需要夹具里有一个 natives 库以避免早退（见 `testArm64UpgradesLegacyJNA`）。
    func testArm64ReplacesObjcBridgeToMavenCentral() async throws {
        let manifest = try makeManifest(manifestJSON([
            nativeLibrary("org.lwjgl:lwjgl:3.3.2"),   // 保证不早退
            plainLibrary("ca.weblite:java-objc-bridge:1.0.0"),
        ]))

        ArtifactVersionMapper.map(manifest, arch: .arm64)

        let replaced = "org.glavo.hmcl.mmachina:java-objc-bridge:1.1.0-mmachina.1"
        let artifact = try XCTUnwrap(library(manifest, named: replaced)?.artifact)
        XCTAssertTrue(artifact.url.hasPrefix("https://repo1.maven.org/maven2/"),
                      "替换制品在 Maven Central，url 必须换源；实际=\(artifact.url)")
        XCTAssertEqual(artifact.path,
                       "org/glavo/hmcl/mmachina/java-objc-bridge/1.1.0-mmachina.1/java-objc-bridge-1.1.0-mmachina.1.jar")
    }

    /// LWJGL **2** 的 natives（`org.lwjgl.lwjgl:lwjgl-platform`）⇒ 换 glavo 制品，path **固定**成常量。
    func testArm64ReplacesLWJGL2NativesWithPinnedPath() async throws {
        let manifest = try makeManifest(manifestJSON([nativeLibrary("org.lwjgl.lwjgl:lwjgl-platform:2.9.3")]))

        ArtifactVersionMapper.map(manifest, arch: .arm64)

        let entry = try XCTUnwrap(manifest.getNeededNatives().first)
        XCTAssertEqual(entry.key.name, "org.glavo.hmcl:lwjgl2-natives:2.9.3-rc1-osx-arm64")
        XCTAssertEqual(entry.value.path, "org/glavo/hmcl/lwjgl2-natives/2.9.3-rc1-osx-arm64/lwjgl2-natives-2.9.3-rc1-osx-arm64.jar")
        XCTAssertTrue(entry.value.url.hasPrefix("https://repo1.maven.org/maven2/"))
    }

    /// 无关 groupId 落 `default: continue`：既不改版本，也不重拼 url。
    func testArm64LeavesUnrelatedLibrariesUntouched() async throws {
        let name = "com.example:untouched:1.2.3"
        let manifest = try makeManifest(manifestJSON([
            nativeLibrary("org.lwjgl:lwjgl:3.3.2"),   // 保证不早退
            plainLibrary(name),
        ]))
        let before = try XCTUnwrap(library(manifest, named: name)?.artifact?.url)

        ArtifactVersionMapper.map(manifest, arch: .arm64)

        XCTAssertEqual(library(manifest, named: name)?.artifact?.url, before,
                       "非 lwjgl/jna/weblite 的库不应被改动")
    }

    // MARK: - 源码注释里自认的两条性质

    /// 幂等性「**恰好成立**」：源码注释明说不改版本号时第二次调用是空操作，
    /// 「这不是设计保证，只是恰好成立」。本用例把这个「恰好」钉住，
    /// 若将来 `changeVersion` 的字符串替换语义变了，这里会先红。
    func testMappingIsIdempotentForNatives() async throws {
        let manifest = try makeManifest(manifestJSON([nativeLibrary("org.lwjgl:lwjgl:3.3.2")]))

        ArtifactVersionMapper.map(manifest, arch: .arm64)
        let first = try XCTUnwrap(manifest.getNeededNatives().first)
        let nameAfterFirst = first.key.name
        let urlAfterFirst = first.value.url

        ArtifactVersionMapper.map(manifest, arch: .arm64)

        let second = try XCTUnwrap(manifest.getNeededNatives().first)
        XCTAssertEqual(second.key.name, nameAfterFirst, "重复调用应是空操作（注释：恰好成立）")
        XCTAssertEqual(second.value.url, urlAfterFirst)
    }

    /// `artifact == nil` 的库（清单只给占位、无下载信息）不得崩 —— 走的是
    /// `library.artifact?.url = …` 的可选链空转。
    func testArm64HandlesLibraryWithoutArtifact() async throws {
        let manifest = try makeManifest(manifestJSON([
            nativeLibrary("org.lwjgl:lwjgl:3.3.2"),      // 保证不早退
            """
            { "name": "org.lwjgl:lwjgl-opengl:3.3.2", "downloads": { } }
            """,
        ]))

        XCTAssertNil(library(manifest, named: "org.lwjgl:lwjgl-opengl:3.3.2")?.artifact,
                     "夹具前提：该库应无 artifact")

        ArtifactVersionMapper.map(manifest, arch: .arm64)   // 不应崩溃

        XCTAssertNil(library(manifest, named: "org.lwjgl:lwjgl-opengl:3.3.2")?.artifact)
    }
}
