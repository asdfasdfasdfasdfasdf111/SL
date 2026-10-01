//
//  GameLanguageSetterTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/Launch/GameLanguageSetter.swift`。
//
//  **为什么值得测**：它的行为是「永远不抛错、也不返回成功与否」（文件头自述），
//  因此调用方**无法得知是否写成功** —— 三个分支（就地替换 / 追加 / 建档）靠肉眼
//  无法确认，只能靠测。且文件头点明了一条真实出过的错：
//
//  > 1.13+ 的语言标识**必须是小写 `zh_cn`** —— 写成大写 `zh_CN` 会被游戏判为无效值
//  > 并自动切回英文，症状是「明明设了中文却进游戏变英文」。
//
//  所以「写进去的必须是小写 `zh_cn`」这条要单独钉住。
//
//  ⚠️ 夹具各自用独立的临时目录，避免互相污染（文件不存在/空文件/已有 lang 行等分支
//  之间互不影响）。
//

import XCTest
@testable import qwq

final class GameLanguageSetterTests: XCTestCase {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-langset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func optionsText(in dir: URL) throws -> String? {
        try? String(contentsOf: dir.appendingPathComponent("options.txt"), encoding: .utf8)
    }

    // MARK: - 已有 lang: 行

    func testReplacesExistingLangLineInPlace() async throws {
        let dir = try makeDir()
        try Data("lang:en_US\nrenderDistance:12\n".utf8).write(to: dir.appendingPathComponent("options.txt"))

        GameLanguageSetter.applyChinese(gameDir: dir)

        XCTAssertEqual(try optionsText(in: dir), "lang:zh_cn\nrenderDistance:12\n")
    }

    /// ⚠️ 必须是小写 `zh_cn`（大写会在 1.13+ 被游戏判为无效切回英文）
    func testWritesLowercaseZhCn() async throws {
        let dir = try makeDir()
        try Data("lang:ja_JP\n".utf8).write(to: dir.appendingPathComponent("options.txt"))

        GameLanguageSetter.applyChinese(gameDir: dir)

        XCTAssertTrue(try XCTUnwrap(try optionsText(in: dir)).contains("lang:zh_cn"),
                      "写进去的必须是小写 zh_cn（大写会被游戏切回英文）")
        XCTAssertFalse(try XCTUnwrap(try optionsText(in: dir)).contains("zh_CN"))
    }

    /// `lang:` 行后跟其它键（同一文件多行）⇒ 只改 lang 行，其它原样保留
    func testPreservesOtherKeys() async throws {
        let dir = try makeDir()
        try Data("lang:de_DE\nfullscreen:true\nsoundVolume:0.8\n".utf8)
            .write(to: dir.appendingPathComponent("options.txt"))

        GameLanguageSetter.applyChinese(gameDir: dir)

        XCTAssertEqual(try optionsText(in: dir), "lang:zh_cn\nfullscreen:true\nsoundVolume:0.8\n")
    }

    /// 多行里只有一条 lang: ⇒ 该条被替换，不误伤其它行
    func testOnlyLangLineIsChanged() async throws {
        let dir = try makeDir()
        try Data("key1:hello\nlang:fr_FR\nkey2:world\n".utf8)
            .write(to: dir.appendingPathComponent("options.txt"))

        GameLanguageSetter.applyChinese(gameDir: dir)

        XCTAssertEqual(try optionsText(in: dir), "key1:hello\nlang:zh_cn\nkey2:world\n")
    }

    // MARK: - 没有 lang: 行

    /// 文件存在但没有 lang: 行 ⇒ 追加，且前面补换行避免粘连
    func testAppendsWhenNoLangLine() async throws {
        let dir = try makeDir()
        try Data("renderDistance:12".utf8).write(to: dir.appendingPathComponent("options.txt"))  // 无末尾换行

        GameLanguageSetter.applyChinese(gameDir: dir)

        XCTAssertEqual(try optionsText(in: dir), "renderDistance:12\nlang:zh_cn\n",
                       "追加前要补换行，否则会和原末行粘连成 renderDistance:12lang:...")
    }

    // MARK: - 文件不存在 / 为空

    /// 文件不存在 ⇒ 建档写出（首行为 lang:zh_cn）
    func testCreatesFileWhenMissing() async throws {
        let dir = try makeDir()
        GameLanguageSetter.applyChinese(gameDir: dir)
        XCTAssertEqual(try optionsText(in: dir), "lang:zh_cn\n")
    }

    /// 文件为空 ⇒ 同样写出首行
    func testWritesWhenFileEmpty() async throws {
        let dir = try makeDir()
        try Data().write(to: dir.appendingPathComponent("options.txt"))
        GameLanguageSetter.applyChinese(gameDir: dir)
        XCTAssertEqual(try optionsText(in: dir), "lang:zh_cn\n")
    }

    // MARK: - 正则边界

    /// `lang:` 出现在行中而非行首 ⇒ 正则 `lang:[^\n]*` 仍会命中并替换
    /// （这是实现事实：正则不要求行首。options.txt 实际是 key:value 结构，此处钉住行为）
    func testLangCanAppearMidLine() async throws {
        let dir = try makeDir()
        try Data("some=lang:en_US\n".utf8).write(to: dir.appendingPathComponent("options.txt"))

        GameLanguageSetter.applyChinese(gameDir: dir)

        XCTAssertEqual(try optionsText(in: dir), "some=lang:zh_cn\n")
    }

    /// ⚠️ 正则只吃到**行尾**（`[^\n]*`），不会跨行把后续内容吃掉
    func testRegexDoesNotCrossLines() async throws {
        let dir = try makeDir()
        try Data("lang:en_US\n\nKEY:VALUE\n".utf8).write(to: dir.appendingPathComponent("options.txt"))

        GameLanguageSetter.applyChinese(gameDir: dir)

        XCTAssertEqual(try optionsText(in: dir), "lang:zh_cn\n\nKEY:VALUE\n")
    }

    // MARK: - 幂等与失败语义

    /// 已写好 zh_cn 后再调用 ⇒ 幂等（仍只这一行被改，无重复追加）
    func testIsIdempotent() async throws {
        let dir = try makeDir()
        try Data("lang:zh_cn\nrenderDistance:12\n".utf8).write(to: dir.appendingPathComponent("options.txt"))

        GameLanguageSetter.applyChinese(gameDir: dir)
        GameLanguageSetter.applyChinese(gameDir: dir)

        XCTAssertEqual(try optionsText(in: dir), "lang:zh_cn\nrenderDistance:12\n")
    }

    /// 永远不抛错（文件头自述：「读失败按空文件处理；写失败静默忽略」）——
    /// 给了不可写目录也只当无事发生
    func testNeverThrowsOnUnwritableDir() async {
        // 一个不存在且无法创建的父目录（路径非法），applyChinese 不应抛错
        let bad = URL(fileURLWithPath: "/nonexistent-parent-\(UUID().uuidString)/sub")
        GameLanguageSetter.applyChinese(gameDir: bad)   // 不应崩溃
    }
}
