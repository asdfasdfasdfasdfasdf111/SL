//
//  OfflineUsernameValidatorTests.swift
//  qwqTests
//
//  覆盖 `Features/Skin/OfflineUsernameValidator.swift`。
//
//  **为什么值得测**：它是输入框下方的**内联提示**（不弹窗、不打断），
//  与启动前的硬校验 `SLCore.validateOfflineUsername` 互补。文案与实际判定必须一致，
//  否则用户看到「没问题」却在启动时被拦，或反之。
//
//  两条容易写错的边界，本文件专门钉住：
//  1. **长度用 `utf16.count`** 而非 `count` —— 一个 emoji 记 2（甚至更多），
//     所以「16 个字符」对非 BMP 字符的判定与直觉不同；
//  2. **先 trim 再判长度**，且空串直接放行（合法性检查有 `!name.isEmpty` 前置守卫）。
//

import XCTest
@testable import qwq

final class OfflineUsernameValidatorTests: XCTestCase {

    // MARK: - 合法输入

    func testValidNameReturnsNoHint() async {
        XCTAssertNil(OfflineUsernameValidator.hint(for: "Steve"))
        XCTAssertNil(OfflineUsernameValidator.hint(for: "player_123"))
        XCTAssertNil(OfflineUsernameValidator.hint(for: "___"))
        XCTAssertNil(OfflineUsernameValidator.hint(for: "0123456789"))
    }

    /// 空串与纯空白：trim 后为空 ⇒ **放行**（`!name.isEmpty` 守卫使合法性检查短路）
    func testEmptyAndWhitespaceOnlyReturnNoHint() async {
        XCTAssertNil(OfflineUsernameValidator.hint(for: ""))
        XCTAssertNil(OfflineUsernameValidator.hint(for: "   "))
        XCTAssertNil(OfflineUsernameValidator.hint(for: "\n\t "))
    }

    /// 首尾空白先被 trim 掉，所以「空白 + 合法名」不触发任何提示
    func testLeadingAndTrailingWhitespaceIsTrimmedBeforeChecks() async {
        XCTAssertNil(OfflineUsernameValidator.hint(for: "  Steve  "))
        XCTAssertNil(OfflineUsernameValidator.hint(for: "\nSteve\r\n"))
    }

    // MARK: - 长度上限

    /// 恰好 16 ⇒ 放行；17 ⇒ 提示。边界两侧都要测，否则 off-by-one 抓不到
    func testLengthBoundaryAt16() async {
        XCTAssertNil(OfflineUsernameValidator.hint(for: String(repeating: "a", count: 16)))
        XCTAssertEqual(OfflineUsernameValidator.hint(for: String(repeating: "a", count: 17)),
                       "用户名不能超过 16 个字符")
    }

    /// trim 发生在长度判定**之前**：17 个字符 + 首尾空白，trim 后仍是 17 ⇒ 仍提示
    func testTrimDoesNotRescueOverlongName() async {
        XCTAssertEqual(OfflineUsernameValidator.hint(for: " \(String(repeating: "a", count: 17)) "),
                       "用户名不能超过 16 个字符")
    }

    /// **长度按 UTF-16 计**：一个 emoji（U+1F600）占 2 个 utf16 单元，
    /// 所以 8 个 emoji = 16 ⇒ 放行，9 个 = 18 ⇒ 提示。
    /// 但 emoji 本身不是 `[0-9A-Za-z_]`，所以 8 个 emoji 会因**字符合法性**而提示 ——
    /// 本用例用「16 个合法字符 + 非 BMP 字符」的组合把两条判定分开。
    func testLengthUsesUTF16CodeUnitsNotCharacters() async {
        // 15 个合法字符 + 1 个 emoji = 15 + 2 = 17 utf16 ⇒ 长度提示优先返回
        let fifteenPlusEmoji = String(repeating: "a", count: 15) + "😀"
        XCTAssertEqual(fifteenPlusEmoji.count, 16, "前提：按 Character 数是 16")
        XCTAssertEqual(fifteenPlusEmoji.utf16.count, 17, "前提：按 UTF-16 是 17")
        XCTAssertEqual(OfflineUsernameValidator.hint(for: fifteenPlusEmoji),
                       "用户名不能超过 16 个字符",
                       "长度判定用的是 utf16.count，所以这里按 17 判超限")
    }

    // MARK: - 字符合法性

    func testIllegalCharactersReturnHint() async {
        let expected = "仅限英文、数字、下划线，否则 1.18+ 无法进入"
        XCTAssertEqual(OfflineUsernameValidator.hint(for: "steve-"), expected)
        XCTAssertEqual(OfflineUsernameValidator.hint(for: "steve."), expected)
        XCTAssertEqual(OfflineUsernameValidator.hint(for: "ste ve"), expected, "内部空格也非法")
        XCTAssertEqual(OfflineUsernameValidator.hint(for: "玩家"), expected)
        XCTAssertEqual(OfflineUsernameValidator.hint(for: "steve!"), expected)
    }

    /// 长度检查**先于**字符合法性：同时超长且含非法字符时，返回的是长度文案
    func testLengthHintTakesPrecedenceOverCharacterHint() async {
        let longAndIllegal = String(repeating: "a", count: 17) + "-"
        XCTAssertEqual(OfflineUsernameValidator.hint(for: longAndIllegal),
                       "用户名不能超过 16 个字符",
                       "两条都不满足时，长度提示先返回")
    }

    /// 单个 emoji：长度不超（2 ≤ 16），但字符非法 ⇒ 字符合法性提示
    func testSingleEmojiFailsOnCharactersNotLength() async {
        XCTAssertEqual(OfflineUsernameValidator.hint(for: "😀"),
                       "仅限英文、数字、下划线，否则 1.18+ 无法进入")
    }

    /// 下划线开头的名字合法（正则允许）
    func testUnderscoreIsAllowed() async {
        XCTAssertNil(OfflineUsernameValidator.hint(for: "_"))
        XCTAssertNil(OfflineUsernameValidator.hint(for: "_a_1_"))
    }
}
