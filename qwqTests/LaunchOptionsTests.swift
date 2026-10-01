//
//  LaunchOptionsTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/Launch/LaunchOptions.swift`（启动入参的默认值与可变性）。
//
//  **为什么值得测**：它是一个**全 `var` 的可变数据袋**，且 `javaPath` 声明为
//  **隐式解包可选（`URL!`）** —— 这意味着「没赋值就读」在编译期不报错、
//  运行期崩溃。本文件把这个危险声明固定住：
//
//  - 初始状态下 `javaPath` 为 nil（读它是安全的，**当 `URL` 用才崩**）；
//  - 若将来有人把它改成非可选的 `URL`，本文件会因构造期崩溃而立刻红 ——
//    那正是想要的信号（说明有人在没提供默认值的情况下收紧了类型）。
//
//  其余字段都是带默认值的普通 `var`，本文件只钉住默认值，防止「默认值被改」导致
//  启动行为静默变化（例如 `skipResourceCheck` 默认 true 会跳过资源补全）。
//

import XCTest
@testable import qwq

final class LaunchOptionsTests: XCTestCase {

    func testDefaults() async {
        let options = LaunchOptions()
        XCTAssertFalse(options.isDemo, "默认非演示模式")
        XCTAssertFalse(options.skipResourceCheck, "默认**不**跳过资源检查（跳过会漏补资源）")
        XCTAssertEqual(options.playerName, "")
        XCTAssertEqual(options.accessToken, "")
        XCTAssertEqual(options.yggdrasilArguments, [])
        XCTAssertNil(options.account, "默认无账号")
    }

    /// `uuid` 每次构造都不同（不是常量默认值）
    func testUUIDIsFreshPerInstance() async {
        XCTAssertNotEqual(LaunchOptions().uuid, LaunchOptions().uuid)
    }

    /// ⚠️ `javaPath` 是 `URL!` ⇒ 未赋值时读出来是 nil（**当 `URL` 用才会崩**）
    func testJavaPathIsNilUntilAssigned() async {
        let options = LaunchOptions()
        XCTAssertNil(options.javaPath,
                     "javaPath 是隐式解包可选：未赋值时读为 nil；直接用会崩溃")
    }

    func testJavaPathIsAssignable() async {
        let options = LaunchOptions()
        let url = URL(fileURLWithPath: "/usr/bin/java")
        options.javaPath = url
        XCTAssertEqual(options.javaPath, url)
    }

    /// 各字段互相独立（赋值一个不影响其它）
    func testFieldsAreIndependent() async {
        let options = LaunchOptions()
        options.playerName = "Steve"
        options.skipResourceCheck = true
        options.isDemo = true

        XCTAssertEqual(options.playerName, "Steve")
        XCTAssertTrue(options.skipResourceCheck)
        XCTAssertTrue(options.isDemo)
        XCTAssertEqual(options.accessToken, "", "未触碰的字段保持默认")
        XCTAssertEqual(options.yggdrasilArguments, [])
    }

    /// 是**引用类型**（`class`）⇒ 传参共享同一实例
    func testIsReferenceTypeSoAliasesShareState() async {
        let a = LaunchOptions()
        let b = a
        b.playerName = "Alex"
        XCTAssertEqual(a.playerName, "Alex",
                       "LaunchOptions 是 class，b 与 a 共享同一实例")
    }

    /// `yggdrasilArguments` 可追加（外部登录参数注入点）
    func testYggdrasilArgumentsCanBeAppended() async {
        let options = LaunchOptions()
        options.yggdrasilArguments.append("--server")
        XCTAssertEqual(options.yggdrasilArguments, ["--server"])
    }
}
