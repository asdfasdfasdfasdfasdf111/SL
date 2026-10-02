//
//  ClientManifestRuleTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/ClientManifestRule.swift`（`Rule` / `OSRule` / `Features`）。
//
//  **为什么值得测**：这个文件里有一条**源码自己写下的警告**——
//
//  > 注意：不能写成 allSatisfy（那会把含 disallow 规则的库无条件排除，
//  > 例如 disallow: windows 的库在 macOS 上本应保留，allSatisfy 会误删导致缺库）
//
//  这正是「用项目自己写下的规则去打它自己」的靶心：`allSatisfy` 是个看起来等价、
//  实则错误的实现，一旦有人「简化」成它，缺库的后果要到启动游戏时才暴露。
//  本文件把顺序叠加语义逐条钉住，其中 `testAllowThenIrrelevantDisallowKeepsLibrary`
//  就是那条警告的可执行形式 —— **改成 allSatisfy 时它会红**。
//
//  测试路径：规则判定入口是 `Rule.check`，而 `ClientManifest.init(json:)` 在解析期
//  就用它筛过一遍 `libraries`。所以**看哪些库活下来**即可反推判定结果，
//  无需 `import SwiftyJSON`（与同目录的 `ClientManifestArgumentsTests` 同构）。
//

import XCTest
@testable import qwq

final class ClientManifestRuleTests: XCTestCase {

    /// 造一条带规则的库
    private func library(_ name: String, rules: String) -> String {
        let path = Util.toPath(mavenCoordinate: name)
        return """
        { "name": "\(name)",
          "rules": \(rules),
          "downloads": { "artifact": { "path": "\(path)",
                                       "url": "https://libraries.minecraft.net/\(path)",
                                       "sha1": "0000000000000000000000000000000000000000",
                                       "size": 1 } } }
        """
    }

    /// 解析一份清单，返回**通过规则筛选后**活下来的库名（保持声明顺序）
    private func survivingLibraries(_ libraries: [String],
                                   file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let json = """
        { "id": "rule-test", "mainClass": "M",
          "libraries": [ \(libraries.joined(separator: ",\n")) ] }
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-rule-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manifest.json")
        try Data(json.utf8).write(to: url)
        let manifest = try XCTUnwrap(try ClientManifest.parse(url: url), "夹具清单解析失败", file: file, line: line)
        return manifest.libraries.map(\.name)
    }

    private func allow(_ os: String?) -> String {
        os.map { #"[ { "action": "allow", "os": { "name": "\#($0)" } } ]"# } ?? #"[ { "action": "allow" } ]"#
    }
    private func disallow(_ os: String) -> String {
        #"[ { "action": "disallow", "os": { "name": "\#(os)" } } ]"#
    }
    /// 造一条带 os.name + os.arch 的 allow 规则（arch 匹配的测试入口）
    private func allowOS(named name: String, arch: String) -> String {
        #"[ { "action": "allow", "os": { "name": "\#(name)", "arch": "\#(arch)" } } ]"#
    }

    // MARK: - 空规则

    /// 无规则 ⇒ 恒放行（`guard !rules.isEmpty else { return true }`）。
    /// 绝大多数库都没有 `rules`，这条是所有其它判定的前提。
    func testEmptyRulesAlwaysAllowed() async throws {
        let kept = try survivingLibraries([library("a:no-rules:1", rules: "[]")])
        XCTAssertEqual(kept, ["a:no-rules:1"])
    }

    // MARK: - 单条 allow

    func testAllowWithoutConditionsIsKept() async throws {
        let kept = try survivingLibraries([library("a:allow-all:1", rules: allow(nil))])
        XCTAssertEqual(kept, ["a:allow-all:1"])
    }

    /// 本机是 macOS（`osx`），故 `allow: osx` 命中
    func testAllowMatchingOSIsKept() async throws {
        let kept = try survivingLibraries([library("a:allow-osx:1", rules: allow("osx"))])
        XCTAssertEqual(kept, ["a:allow-osx:1"])
    }

    /// `allow: windows` 在本机不命中 ⇒ 丢弃
    func testAllowNonMatchingOSIsDropped() async throws {
        let kept = try survivingLibraries([library("a:allow-win:1", rules: allow("windows"))])
        XCTAssertEqual(kept, [])
    }

    /// `unknown` 视为通用（无系统限制）⇒ 命中
    func testAllowUnknownOSIsKept() async throws {
        let kept = try survivingLibraries([library("a:allow-unknown:1", rules: allow("unknown"))])
        XCTAssertEqual(kept, ["a:allow-unknown:1"])
    }

    // MARK: - disallow 与顺序叠加（本文件的靶心）

    /// **源码警告的可执行形式**：`[allow, disallow: windows]` 在 macOS 上**必须保留**。
    /// 顺序叠加语义下：allow 置 `required = true`；disallow 的条件不匹配 ⇒ 不影响结论。
    /// 若有人把它「简化」成 `allSatisfy`，disallow 那条在不匹配时会返回 false 从而**误删该库**
    /// —— 这正是源码注释点名的缺陷。
    func testAllowThenIrrelevantDisallowKeepsLibrary() async throws {
        let rules = #"[ { "action": "allow" }, { "action": "disallow", "os": { "name": "windows" } } ]"#
        let kept = try survivingLibraries([library("a:not-windows:1", rules: rules)])
        XCTAssertEqual(kept, ["a:not-windows:1"],
                       "allow 后跟一条『不匹配本机』的 disallow，库必须保留（allSatisfy 会误删）")
    }

    /// `[allow, disallow: osx]`：disallow 的条件**匹配**本机 ⇒ 否决
    func testAllowThenMatchingDisallowVetoes() async throws {
        let rules = #"[ { "action": "allow" }, { "action": "disallow", "os": { "name": "osx" } } ]"#
        let kept = try survivingLibraries([library("a:not-osx:1", rules: rules)])
        XCTAssertEqual(kept, [], "匹配本机的 disallow 必须否决前面的 allow")
    }

    /// 只有 `disallow` 而无 `allow` ⇒ 结论停在初始值 `false` ⇒ 丢弃。
    /// （默认即不放行；这是标准语义，不是缺陷。）
    func testLoneDisallowWithoutAllowYieldsFalse() async throws {
        let kept = try survivingLibraries([library("a:lone-disallow:1", rules: disallow("osx"))])
        XCTAssertEqual(kept, [])
    }

    /// 顺序敏感：`[disallow: osx, allow: osx]` —— **后一条覆盖前一条** ⇒ 保留。
    /// 与上一条成对，用来证明判定是「顺序叠加」而不是「集合运算」。
    func testLaterAllowOverridesEarlierDisallow() async throws {
        let rules = #"[ { "action": "disallow", "os": { "name": "osx" } }, { "action": "allow", "os": { "name": "osx" } } ]"#
        let kept = try survivingLibraries([library("a:allow-wins:1", rules: rules)])
        XCTAssertEqual(kept, ["a:allow-wins:1"], "后出现的 allow 必须覆盖先前的 disallow")
    }

    // MARK: - features

    /// `features` 声明的开关本项目一律不支持（`Features.match()` 对任一 `true` 返回 false）
    /// ⇒ 该规则条件不匹配。
    func testFeatureGatedAllowIsDropped() async throws {
        let rules = #"[ { "action": "allow", "features": { "is_demo_user": true } } ]"#
        let kept = try survivingLibraries([library("a:demo:1", rules: rules)])
        XCTAssertEqual(kept, [], "本项目不支持 demo 用户，该 allow 不应命中")
    }

    /// 特性开关写 `false` ⇒ `Features.match()` 返回 **true**（它只在开关为 `true` 时返回 false）
    /// ⇒ 该 allow **命中**、库保留。
    /// 这与「声明了该开关就算不支持」的直觉相反，故显式钉住。
    func testFeatureFlagFalseIsTreatedAsMatching() async throws {
        let rules = #"[ { "action": "allow", "features": { "has_custom_resolution": false } } ]"#
        let kept = try survivingLibraries([library("a:custom-res:1", rules: rules)])
        XCTAssertEqual(kept, ["a:custom-res:1"],
                       "Features.match() 只对 `true` 返回 false，故 `false` 视为条件命中")
    }

    // MARK: - arch 匹配（2026-10-02 实现后补测）

    /// 清单 arch 与本机架构一致 ⇒ allow 命中、库保留。
    /// 本机架构用 `Architecture.system`（进程视角：Rosetta 下为 .x64，与 exec 语义一致）。
    func testAllowMatchingArchIsKept() async throws {
        let current = Architecture.system
        let archString: String
        switch current {
        case .arm64: archString = "arm64"
        case .x64: archString = "x86_64"
        default: archString = "x86_64" // 兜底：让用例在 fatFile/unknown 等异常态仍可跑
        }
        let kept = try survivingLibraries([library("a:match-arch:1", rules: allowOS(named: "osx", arch: archString))])
        XCTAssertEqual(kept, ["a:match-arch:1"], "arch 与本机一致的 allow 必须命中")
    }

    /// 清单 arch 与本机架构**不一致** ⇒ allow 不命中、库被丢弃。
    /// 取一个肯定与当前架构不同的书写形态（arm64 进程用 x86，x64 进程用 arm64）。
    func testAllowNonMatchingArchIsDropped() async throws {
        let foreign: String
        switch Architecture.system {
        case .arm64: foreign = "x86"
        case .x64: foreign = "arm64"
        default: foreign = "x86"
        }
        let kept = try survivingLibraries([library("a:foreign-arch:1", rules: allowOS(named: "osx", arch: foreign))])
        XCTAssertEqual(kept, [], "arch 与本机不一致的 allow 必须丢弃")
    }

    /// 从未见过的 arch 书写形态（如 `arm32-v7a`）⇒ `Architecture.fromString` 返回
    /// `.unknown` ⇒ 视为通用、不因此否决（与 os.name == "unknown" 的语义一致）。
    func testAllowUnknownArchIsKept() async throws {
        let kept = try survivingLibraries([library("a:unknown-arch:1", rules: allowOS(named: "osx", arch: "arm32-v7a"))])
        XCTAssertEqual(kept, ["a:unknown-arch:1"], "未识别的 arch 形态应视为通用（.unknown → true）")
    }

    // MARK: - 多条库混合（确认筛选逐条独立、且保持顺序）

    func testMixedLibrariesAreFilteredIndependentlyAndKeepOrder() async throws {
        let kept = try survivingLibraries([
            library("a:keep-1:1", rules: allow("osx")),
            library("a:drop-1:1", rules: allow("windows")),
            library("a:keep-2:1", rules: "[]"),
            library("a:drop-2:1", rules: disallow("osx")),
            library("a:keep-3:1", rules: #"[ { "action": "allow" }, { "action": "disallow", "os": { "name": "windows" } } ]"#),
        ])
        XCTAssertEqual(kept, ["a:keep-1:1", "a:keep-2:1", "a:keep-3:1"],
                       "逐条独立判定，且保持声明顺序")
    }
}
