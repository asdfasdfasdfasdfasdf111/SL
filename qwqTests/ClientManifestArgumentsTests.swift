//
//  ClientManifestArgumentsTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/ClientManifestArguments.swift`（`ClientManifest.Arguments` 一族）。
//
//  **为什么值得测**：它决定**最终拼给 java 的命令行**。错了的后果不是崩溃，而是
//  参数缺失/多出 —— 例如把不该带的规则组带上、或把该带的老版参数丢了，
//  表现为游戏启动失败或行为异常，且很难从现象反推。
//
//  两条格式并存，本文件两条都覆盖：
//  - **新版**（1.13+）：`arguments.game` / `arguments.jvm`，元素是裸字符串或 `{rules,value}`；
//  - **旧版**（≤1.12）：只有一行 `minecraftArguments`，由 `getArguments()` 兜底：
//    按空格切分包装成裸字符串，**jvm 参数是硬编码的 10 项**（G1GC + 四个 natives 相关 `-D` + `-cp`）。
//
//  夹具同样走**公开入口** `ClientManifest.parse(url:)`（临时文件），
//  从而**不 import SwiftyJSON** —— 测试 target 里没有别处引用它，不假设它被链接。
//
//  钉住源码注释里自认的三条性质（都不是新需求，是防将来无声改变）：
//  1. **畸形输入**（非字符串非对象，如数字）会被当成「规则组」解析，得到空 rules + 空 value
//     ⇒ 筛选层放行、但贡献 0 个参数（注释：「等价于不生效」）；
//  2. `values()` 里**又判了一次** `rules.match()`（防御性重复，两层都走同一个 `Rule.check`）；
//  3. `RuleTag.value` 把「字符串 / 数组」**归一成数组**，数组里混进非字符串则**静默丢弃**。
//

import XCTest
@testable import qwq

final class ClientManifestArgumentsTests: XCTestCase {

    private func makeManifest(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> ClientManifest {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-args-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manifest.json")
        try Data(json.utf8).write(to: url)
        return try XCTUnwrap(try ClientManifest.parse(url: url), "夹具清单解析失败", file: file, line: line)
    }

    /// 只带 `arguments` 的清单
    private func manifestWithArguments(game: String, jvm: String = "[]") throws -> ClientManifest {
        try makeManifest("""
        { "id": "args-test", "mainClass": "M",
          "arguments": { "game": \(game), "jvm": \(jvm) } }
        """)
    }

    // MARK: - 新版格式：裸字符串

    func testPlainStringArgumentsPassThroughUnchanged() async throws {
        let manifest = try manifestWithArguments(game: #"["--username", "Player", "--version", "1.20.1"]"#)
        XCTAssertEqual(manifest.getArguments().getAllowedGameArguments(),
                       ["--username", "Player", "--version", "1.20.1"],
                       "裸字符串应原样、按序透传")
    }

    // MARK: - 新版格式：规则组

    /// `os` 规则命中本机（macOS ⇒ osx）⇒ 采用其 value
    func testRuleGroupWithMatchingOSIsIncluded() async throws {
        let manifest = try manifestWithArguments(
            game: #"[ { "rules": [ { "action": "allow", "os": { "name": "osx" } } ], "value": "--demo-osx" } ]"#)
        XCTAssertEqual(manifest.getArguments().getAllowedGameArguments(), ["--demo-osx"])
    }

    /// `os` 规则不命中本机（windows）⇒ 排除。
    /// 这条尤其重要：若误把 windows 参数带上，游戏会收到无效参数。
    func testRuleGroupWithNonMatchingOSIsExcluded() async throws {
        let manifest = try manifestWithArguments(
            game: #"[ { "rules": [ { "action": "allow", "os": { "name": "windows" } } ], "value": "--demo-windows" } ]"#)
        XCTAssertEqual(manifest.getArguments().getAllowedGameArguments(), [],
                       "只允许 windows 的参数不得出现在 macOS 上")
    }

    /// `disallow` 命中本机 ⇒ 否决（PCL2 顺序叠加语义）
    func testDisallowRuleVetoesArgument() async throws {
        let manifest = try manifestWithArguments(
            game: #"[ { "rules": [ { "action": "disallow", "os": { "name": "osx" } } ], "value": "--not-on-osx" } ]"#)
        XCTAssertEqual(manifest.getArguments().getAllowedGameArguments(), [],
                       "disallow osx 的参数在 macOS 上必须被排除")
    }

    /// 无 `os` 条件的 allow ⇒ 条件恒匹配 ⇒ 采用
    func testAllowWithoutConditionsIsIncluded() async throws {
        let manifest = try manifestWithArguments(
            game: #"[ { "rules": [ { "action": "allow" } ], "value": "--always" } ]"#)
        XCTAssertEqual(manifest.getArguments().getAllowedGameArguments(), ["--always"])
    }

    /// `features` 声明了本项目不支持的开关（`is_demo_user`）⇒ 不匹配 ⇒ 排除。
    /// （`Features.match()` 对这些开关一律返回 false，即「不支持」）
    func testUnsupportedFeatureRuleIsExcluded() async throws {
        let manifest = try manifestWithArguments(
            game: #"[ { "rules": [ { "action": "allow", "features": { "is_demo_user": true } } ], "value": "--demo" } ]"#)
        XCTAssertEqual(manifest.getArguments().getAllowedGameArguments(), [],
                       "demo 用户参数本项目不支持，必须排除")
    }

    /// 规则组的 `value` 是**数组** ⇒ 摊平成多条，且保持顺序
    func testRuleGroupWithMultipleValuesIsFlattened() async throws {
        let manifest = try manifestWithArguments(
            game: #"[ { "rules": [ { "action": "allow", "os": { "name": "osx" } } ], "value": ["--a", "--b", "--c"] } ]"#)
        XCTAssertEqual(manifest.getArguments().getAllowedGameArguments(), ["--a", "--b", "--c"],
                       "数组形态的 value 必须摊平成多条参数")
    }

    // MARK: - 源码注释自认的三条性质

    /// **畸形输入**（这里是数字）：既不是字符串也不是对象 ⇒ 被当成空规则组。
    /// 注释称「等价于不生效」：筛选层放行（`Rule.check([]) == true`），但贡献 0 个参数。
    /// 本用例钉住「不崩 + 不产生参数」。
    func testMalformedNumericEntryContributesNothingAndDoesNotCrash() async throws {
        let manifest = try manifestWithArguments(game: #"[ 123, { "rules": [ { "action": "allow" } ], "value": "--keep" } ]"#)
        XCTAssertEqual(manifest.getArguments().getAllowedGameArguments(), ["--keep"],
                       "数字条目应静默不生效，且不影响相邻的正常参数")
    }

    /// `RuleTag.value` 归一化：数组里混进非字符串（数字 / null）应**静默丢弃**，而非整体失败
    func testNonStringEntriesInsideValueArrayAreDropped() async throws {
        let manifest = try manifestWithArguments(
            game: #"[ { "rules": [ { "action": "allow" } ], "value": ["--ok", 42, null, "--also-ok"] } ]"#)
        XCTAssertEqual(manifest.getArguments().getAllowedGameArguments(), ["--ok", "--also-ok"],
                       "value 数组里的非字符串元素应被丢弃，字符串必须保留")
    }

    /// `value` 既不是字符串也不是数组（这里是数字）⇒ 归一成空数组
    func testNonStringNonArrayValueNormalizesToEmpty() async throws {
        let manifest = try manifestWithArguments(
            game: #"[ { "rules": [ { "action": "allow" } ], "value": 42 } ]"#)
        XCTAssertEqual(manifest.getArguments().getAllowedGameArguments(), [])
    }

    // MARK: - 旧版格式兜底

    /// 只给 `minecraftArguments`（≤1.12）：游戏参数按**空格切分**，jvm 参数是**硬编码 10 项**。
    /// 后者是「老版本也能启动」的关键 —— 光有游戏参数拼不出命令行。
    func testLegacyMinecraftArgumentsFallback() async throws {
        let manifest = try makeManifest("""
        { "id": "legacy", "mainClass": "M",
          "minecraftArguments": "--username Player --version 1.12.2" }
        """)

        XCTAssertNil(manifest.arguments, "夹具前提：老版清单没有 arguments 字段")

        let args = manifest.getArguments()
        XCTAssertEqual(args.getAllowedGameArguments(), ["--username", "Player", "--version", "1.12.2"],
                       "老版游戏参数应按空格切分并原样保留")

        let jvm = args.getAllowedJVMArguments()
        XCTAssertEqual(jvm.count, 10, "老版 jvm 参数是硬编码 10 项；实际=\(jvm)")
        XCTAssertTrue(jvm.contains("-XX:+UseG1GC"))
        XCTAssertTrue(jvm.contains("-cp"), "缺少 -cp 会导致 classpath 拼不进命令行")
        XCTAssertTrue(jvm.contains("${classpath}"), "classpath 占位符由后续替换")
        XCTAssertTrue(jvm.contains("-Djava.library.path=${natives_directory}"))
    }

    /// 两种格式同时存在时，**`arguments` 优先**（`getArguments()` 的第一条分支）
    func testArgumentsFieldWinsOverLegacyField() async throws {
        let manifest = try makeManifest("""
        { "id": "both", "mainClass": "M",
          "minecraftArguments": "--legacy-should-lose",
          "arguments": { "game": ["--new-wins"], "jvm": [] } }
        """)
        XCTAssertEqual(manifest.getArguments().getAllowedGameArguments(), ["--new-wins"],
                       "有 arguments 时不得回落到 minecraftArguments")
    }

    /// 两者都没有 ⇒ 空参数集（不崩，但启动必然失败 —— 注释明说）
    func testNeitherFormatYieldsEmptyArguments() async throws {
        let manifest = try makeManifest(#"{ "id": "none", "mainClass": "M" }"#)
        let args = manifest.getArguments()
        XCTAssertEqual(args.getAllowedGameArguments(), [])
        XCTAssertEqual(args.getAllowedJVMArguments(), [])
    }

    /// jvm 与 game 走**同一条**「先按 rules 筛、再摊平」的逻辑
    func testJVMArgumentsUseSameFilterAndFlattenLogic() async throws {
        let manifest = try manifestWithArguments(
            game: "[]",
            jvm: #"[ "-Xmx1G", { "rules": [ { "action": "allow", "os": { "name": "windows" } } ], "value": "-XX:+WindowsOnly" } ]"#)
        XCTAssertEqual(manifest.getArguments().getAllowedJVMArguments(), ["-Xmx1G"],
                       "jvm 参数必须与 game 参数走同一套规则筛选")
    }
}
