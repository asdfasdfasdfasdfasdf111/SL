//
//  PropertiesParserTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Utils/PropertiesParser.swift`（极简 .properties 解析器）。
//
//  **为什么值得测**：解析器的错误是**静默的数据损坏** —— 不崩、不报错，
//  只是键值悄悄丢了或值被截短，症状要到别处才显形。
//  而本类型的注释**逐条自列了与 `java.util.Properties` 的 3 处差异**
//  （不认 `:` 分隔符、不处理转义与续行、值里的 `#`/`!` 会被当注释截断），
//  这 3 条正是「将来有人拿它去读第三方 properties」时最容易踩的坑。
//  本文件把它们逐条钉成可执行断言。
//
//  另有一条**静默降级**也已登记在源码注释里，本文件同样钉住：
//  读不到文件（不存在 / 非 UTF-8）时返回**空字典**且不抛错，
//  调用方无法区分「文件不存在」与「文件存在但没有任何键值对」。
//

import XCTest
@testable import qwq

final class PropertiesParserTests: XCTestCase {

    /// 把内容写进临时文件并解析（内容为 String）
    private func parse(_ content: String,
                       file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-props-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.properties")
        try Data(content.utf8).write(to: url)
        return PropertiesParser.parse(fileURL: url)
    }

    private func parseBytes(_ bytes: [UInt8]) throws -> [String: String] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-props-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.properties")
        try Data(bytes).write(to: url)
        return PropertiesParser.parse(fileURL: url)
    }

    // MARK: - 静默降级：读不到就是空字典

    /// 文件不存在 ⇒ 空字典、**不抛错**（`parse` 签名里没有 throws，这是有意的）
    func testMissingFileYieldsEmptyDictionaryWithoutThrowing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-props-tests-\(UUID().uuidString)-absent.properties")
        XCTAssertEqual(PropertiesParser.parse(fileURL: missing), [:])
    }

    /// 非 UTF-8 内容 ⇒ 同样空字典（`String(contentsOf:encoding:.utf8)` 失败被 `try?` 吞掉）
    func testInvalidUTF8YieldsEmptyDictionary() async throws {
        // 0xFF 0xFE 在 UTF-8 里是非法起始字节
        let result = try parseBytes([0x61, 0x3D, 0x62, 0xFF, 0xFE])
        XCTAssertEqual(result, [:], "非法 UTF-8 应静默降级成空字典")
    }

    // MARK: - 基本解析

    func testSimpleKeyValue() async throws {
        let result = try parse("key=value")
        XCTAssertEqual(result, ["key": "value"])
    }

    func testMultipleLinesAndCRLF() async throws {
        let result = try parse("a=1\r\nb=2\nc=3")
        XCTAssertEqual(result, ["a": "1", "b": "2", "c": "3"], "CRLF 与 LF 都应支持")
    }

    /// 同一 key 多次出现 ⇒ **后来者覆盖先来者**（逐行赋值，非合并）
    func testDuplicateKeyLaterWins() async throws {
        let result = try parse("k=first\nk=second")
        XCTAssertEqual(result, ["k": "second"])
    }

    /// `key=` 仍切成两段（`omittingEmptySubsequences: false`）⇒ 值是**空串**而非整行丢弃
    func testEmptyValueIsKeptAsEmptyString() async throws {
        let result = try parse("k=")
        XCTAssertEqual(result, ["k": ""], "`key=` 必须产出空串值，不能整行丢弃")
    }

    /// 完全没有 `=` 的行被丢弃
    func testLineWithoutSeparatorIsDropped() async throws {
        let result = try parse("no-separator-here\nk=v")
        XCTAssertEqual(result, ["k": "v"])
    }

    /// 值里允许再出现 `=`（`maxSplits: 1`）
    func testValueMayContainEqualsSign() async throws {
        let result = try parse("k=a=b=c")
        XCTAssertEqual(result, ["k": "a=b=c"])
    }

    // MARK: - 空行与整行注释

    func testBlankLinesAndFullLineCommentsAreSkipped() async throws {
        let content = """
        # 井号注释
        ! 感叹号注释

        \t
        real=1
        """
        let result = try parse(content)
        XCTAssertEqual(result, ["real": "1"])
    }

    // MARK: - 与 java.util.Properties 的三处差异（源码注释逐条点名）

    /// **差异 1**：只认 `=`，**不认 `:`**。标准实现两者都认 ——
    /// 拿本类型去读 `a:b` 形式的 properties 会**整行丢掉**。
    func testColonIsNotASeparator() async throws {
        let result = try parse("a:b")
        XCTAssertEqual(result, [:], "本实现不认 `:` 作分隔符（与 java.util.Properties 的差异之一）")
    }

    /// **差异 3**：值内部的 `#` 会被当作行内注释起始而**截断**。
    /// 标准实现只在行首认注释，因此 `abc#123` 在标准实现里是完整值。
    func testHashInsideValueTruncatesIt() async throws {
        let result = try parse("k=abc#123")
        XCTAssertEqual(result, ["k": "abc"], "值里的 # 会被当注释截断（已知差异，非缺陷）")
    }

    /// 同上，`!` 亦截断
    func testExclamationInsideValueTruncatesIt() async throws {
        let result = try parse("k=abc!123")
        XCTAssertEqual(result, ["k": "abc"])
    }

    /// 截断发生在**第一个** `#` 或 `!` 处，取的是它**左边**的部分
    func testTruncationUsesFirstCommentCharacter() async throws {
        let result = try parse("k=a!b#c")
        XCTAssertEqual(result, ["k": "a"])
    }

    /// **差异 2**：不处理转义 —— `\n` 保持字面两字符，`\uXXXX` 不解码
    func testEscapeSequencesAreKeptLiteral() async throws {
        let result = try parse(#"k=a\nb"#)
        XCTAssertEqual(result, ["k": #"a\nb"#], "不解析转义序列，按字面量处理")
    }

    /// **差异 2（续）**：不支持 `\` 续行 —— 以 `\` 结尾的行不会与下一行拼接，
    /// 下一行因为自身没有 `=` 而被丢弃。
    func testBackslashLineContinuationIsNotSupported() async throws {
        let result = try parse("k=a\\\nb")
        XCTAssertEqual(result, ["k": "a\\"], "`\\` 不构成续行，下一行应被独立丢弃")
        XCTAssertNil(result["b"])
    }

    // MARK: - 键值与引号的空白处理

    /// 键的**首尾**空白被去掉
    func testKeyIsTrimmed() async throws {
        let result = try parse("   spaced-key   =v")
        XCTAssertEqual(result, ["spaced-key": "v"])
    }

    /// 值的**首尾**空白被去掉
    func testValueIsTrimmed() async throws {
        let result = try parse("k=   v   ")
        XCTAssertEqual(result, ["k": "v"])
    }

    /// 值首尾的引号被剥掉**一层**（`"` 与 `'` 都算，且不要求配对）
    func testValueQuotesAreStrippedOneLayer() async throws {
        XCTAssertEqual(try parse(#"k="abc""#), ["k": "abc"])
        XCTAssertEqual(try parse("k='abc'"), ["k": "abc"])
        // 单边引号也会被剥（实现是「首尾各 trim 一次引号字符集」，不校验配对）
        XCTAssertEqual(try parse(#"k="abc"#), ["k": "abc"])
    }

    /// 内部引号原样保留（注释里的例子：`"ab"c"` → `ab"c`）
    func testInnerQuotesArePreserved() async throws {
        let result = try parse(#"k="ab"c""#)
        XCTAssertEqual(result, ["k": #"ab"c"#], "只剥首尾，内部引号原样保留")
    }

    /// 行首 `#`/`!` 才被当整行注释；`\#` 不被视为字面量 `#`（注释明说不做转义处理）
    func testLeadingEscapeDoesNotMakeHashLiteral() async throws {
        // 普通字符串：`\\` 是字面反斜杠，内容是 `\#not-a-comment=v`
        // （不能用 `#"..."#` raw string —— 那里 `\#` 是转义引导符，`\#n` 会变成换行）
        let result = try parse("\\#not-a-comment=v")
        // 行首是反斜杠而非 #，所以不是整行注释；键为 `\#not-a-comment`
        XCTAssertEqual(result["\\#not-a-comment"], "v",
                       "行首判定只看第一个字符，反斜杠不构成转义")
    }

    // MARK: - 组合

    func testRealisticLocalizationFile() async throws {
        let content = """
        # Minecraft 本地化词条
        ! 另一种注释风格
        item.sword=Sword
        item.pickaxe=   Pickaxe
        empty.value=
        dup=1
        dup=2
        quoted="Quoted Name"
        with.equals=a=b
        """
        let result = try parse(content)
        XCTAssertEqual(result, [
            "item.sword": "Sword",
            "item.pickaxe": "Pickaxe",
            "empty.value": "",
            "dup": "2",
            "quoted": "Quoted Name",
            "with.equals": "a=b",
        ])
    }
}
