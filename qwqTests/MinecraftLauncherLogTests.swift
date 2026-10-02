//
//  MinecraftLauncherLogTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/Launch/MinecraftLauncherLog.swift`
//  （`LaunchCompletionGate` / `GameLogWriter` / `drainPipe`）。
//
//  **为什么值得测**：这三者共同保证「游戏进程的输出能完整落盘」。
//  文件里记着**两个已修的真实 bug**，本文件把它们钉成回归守卫：
//
//  1. `close()` 必须**补刷行尾残字节** —— 注释原话：「游戏最后一行输出常常没有换行符
//     （如崩溃前的半行堆栈），原实现只落『以 \n 结尾的完整行』，这些残字节会随 close()
//     一起丢掉 —— 表现为日志尾部缺行，而这恰恰是排查崩溃最需要的一段」；
//  2. `drainPipe` 必须有**超时** —— 注释原话：写端若被**孙进程继承**（Java 拉起 crash handler、
//     游戏内 `Runtime.exec` 派生进程等），直接子进程退出后读端永远等不到 EOF，
//     「本函数在启动线程上永久阻塞 → `completion` 不触发、UI 永停『启动中』」。
//
//  另有一条**降级路径**要守住：日志文件打不开时（磁盘满 / 目录无权限），
//  `handle` 传 nil 走**丢弃模式** —— 仍继续读管道（否则管道写满会让游戏进程阻塞），
//  但不落盘、也**不留缓冲**（注释：缓冲会随游戏时长无限增长）。
//

import XCTest
@testable import qwq

final class MinecraftLauncherLogTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-launcherlog-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// 造一个写往临时文件的 writer，返回 (writer, 日志文件 URL)
    private func makeWriter() throws -> (GameLogWriter, URL) {
        let url = workDir.appendingPathComponent("game-\(UUID().uuidString).log")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        return (GameLogWriter(handle: handle), url)
    }

    private func contents(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - LaunchCompletionGate：一次性门控

    /// 第一次 claim 成功，之后全部失败（「恰好 resume 一次」的基础）
    func testCompletionGateClaimsExactlyOnce() async {
        let gate = LaunchCompletionGate()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        XCTAssertFalse(gate.claim(), "无论调用几次，只有第一次拿到")
    }

    /// 并发 claim 也**恰好一个**成功
    func testCompletionGateIsSafeUnderConcurrency() async {
        let gate = LaunchCompletionGate()
        let winners = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<32 {
                group.addTask { gate.claim() }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        XCTAssertEqual(winners, 1, "32 个并发 claim 必须恰好一个成功")
    }

    // MARK: - GameLogWriter：完整行立即落盘

    func testCompleteLineIsWrittenImmediately() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data("hello\n".utf8))
        XCTAssertEqual(contents(of: url), "hello\n", "以 \\n 结尾的完整行应立即落盘")
        writer.close()
    }

    func testMultipleCompleteLinesInOneAppend() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data("a\nb\nc\n".utf8))
        XCTAssertEqual(contents(of: url), "a\nb\nc\n")
        writer.close()
    }

    /// ⚠️ **文件写入保留 tab 原样**：`flushCompleteLines` 里的
    /// `replacingOccurrences(of: "\t", with: "    ")` 只作用于 `raw()` 通道（App 内存日志旁路），
    /// 落盘用的是**未展开**的 `line`（源码 103 行）。我最初按注释理解成「文件里也展开成 4 空格」，
    /// 用独立探针逐字复刻源码逻辑后发现是错的 —— 文件里是 `a\tb\n`。
    /// 若未来想「修正」为展开，必须同时改 `flushCompleteLines` 与 `close()` 两处。
    func testTabsArePreservedInFileWrite() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data("a\tb\n".utf8))
        XCTAssertEqual(contents(of: url), "a\tb\n", "文件写入保留 tab（raw() 通道才展开）")
        writer.close()
    }

    /// 未满一行的残字节**留缓冲**，不立即落盘
    func testPartialLineIsBufferedNotWritten() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data("partial".utf8))
        XCTAssertEqual(contents(of: url), "", "没有换行的残字节应留在缓冲区")
        writer.close()
    }

    // MARK: - GameLogWriter.close()：补刷残字节（已修 bug 的回归守卫）

    /// ⚠️ **本文件的靶心**：`close()` 必须把没有换行符的最后一行也落盘并补换行。
    /// 原实现会丢掉它 —— 而「崩溃前的半行堆栈」正是最需要的一段。
    func testCloseFlushesResidualWithoutNewline() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data("crash stack trace without newline".utf8))

        writer.close()

        XCTAssertEqual(contents(of: url), "crash stack trace without newline\n",
                       "close() 必须补刷残字节并补换行（原实现会丢掉这最后一段）")
    }

    /// ⚠️ `close()` 补刷残字节时**同样保留 tab 原样**（与 `flushCompleteLines` 一致：
    /// 展开只作用于 `raw()` 通道，源码 85 行写的是未展开的 `line + "\n"`）。
    func testClosePreservesTabsInResidual() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data("a\tb".utf8))
        writer.close()
        XCTAssertEqual(contents(of: url), "a\tb\n", "close 补刷的残行同样保留 tab")
    }

    /// 缓冲区为空时 `close()` 不额外写空行
    func testCloseWritesNothingWhenBufferEmpty() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data("done\n".utf8))
        writer.close()
        XCTAssertEqual(contents(of: url), "done\n", "不应因 close 多写一个空行")
    }

    /// **非法 UTF-8 残字节**：原样落盘，不臆造内容（注释：「解码失败行本就按约定丢弃」）
    func testCloseWritesInvalidUTF8ResidualVerbatim() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data([0xFF, 0xFE, 0xFD]))   // 非法 UTF-8 起始字节

        writer.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data), [0xFF, 0xFE, 0xFD],
                       "非法 UTF-8 残字节应原样落盘，不补换行、不做替换")
    }

    /// `close()` 幂等：第二次调用不抛错、不再写内容
    func testCloseIsIdempotent() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data("x".utf8))
        writer.close()
        let afterFirst = contents(of: url)

        writer.close()   // 不应崩溃（handle 已关闭）

        XCTAssertEqual(contents(of: url), afterFirst, "第二次 close 不应重复落盘")
    }

    /// 关闭后到达的字节直接丢弃（避免对已关闭句柄写入 / seek）
    func testAppendsAfterCloseAreDropped() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data("before\n".utf8))
        writer.close()

        writer.append(Data("after\n".utf8))   // 在途的 readabilityHandler 可能晚到

        XCTAssertEqual(contents(of: url), "before\n", "关闭后的字节必须被丢弃")
    }

    // MARK: - GameLogWriter：跨回调的多字节字符

    /// 一个多字节 UTF-8 字符被**读取边界切开**时，缓冲保证不产生乱码 / 不丢字符
    func testMultibyteCharacterSplitAcrossAppendsIsPreserved() async throws {
        let (writer, url) = try makeWriter()
        let bytes = Array("你".utf8)          // 3 字节
        XCTAssertEqual(bytes.count, 3, "前提：'你' 是 3 字节")

        writer.append(Data(bytes[0..<2]))     // 前半
        XCTAssertEqual(contents(of: url), "", "半个字符不足以成行，必须留在缓冲")

        writer.append(Data(bytes[2...] + [0x0A]))   // 后半 + 换行
        XCTAssertEqual(contents(of: url), "你\n", "跨回调拼接后必须还原成完整字符")

        writer.close()
    }

    /// 整行非法 UTF-8 ⇒ 该行被**丢弃**（`flushCompleteLines` 里的 `continue`），
    /// 但不影响后续合法行
    func testInvalidUTF8LineIsDroppedWithoutAffectingLaterLines() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data([0xFF, 0x0A]))          // 非法行
        writer.append(Data("valid\n".utf8))

        XCTAssertEqual(contents(of: url), "valid\n",
                       "解码失败的整行按约定丢弃，后续行照常落盘")

        writer.close()
    }

    // MARK: - GameLogWriter：丢弃模式（handle == nil）

    /// `handle` 为 nil ⇒ 不落盘、不崩（日志文件打不开时的降级路径）
    func testDiscardModeWritesNothingAndDoesNotCrash() async {
        let writer = GameLogWriter(handle: nil)
        writer.append(Data("anything\n".utf8))
        writer.append(Data("no newline".utf8))
        writer.close()   // 不应崩溃
    }

    /// 丢弃模式下 `close()` 也不崩（无句柄可刷）
    func testDiscardModeCloseIsSafe() async {
        let writer = GameLogWriter(handle: nil)
        writer.close()
        writer.close()
    }

    /// 空 `Data` 直接被忽略（不进入缓冲，也不触发落盘）
    func testEmptyAppendIsIgnored() async throws {
        let (writer, url) = try makeWriter()
        writer.append(Data())
        XCTAssertEqual(contents(of: url), "")
        writer.close()
        XCTAssertEqual(contents(of: url), "", "空 Data 不应产生任何内容")
    }

    // MARK: - drainPipe

    /// 正常路径：写端已关闭 ⇒ 读完残留字节即返回
    func testDrainPipeReadsRemainingBytes() async throws {
        let (writer, url) = try makeWriter()
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("line1\nline2\n".utf8))
        try pipe.fileHandleForWriting.close()

        drainPipe(pipe, into: writer)
        writer.close()

        XCTAssertEqual(contents(of: url), "line1\nline2\n")
    }

    /// ⚠️ **靶心（已修 bug 的回归守卫）**：写端**未关闭**（模拟被孙进程继承）时，
    /// `drainPipe` 必须在收尾时限内返回，而不是永久阻塞。
    /// 注释记的后果：「在启动线程上永久阻塞 → completion 不触发、UI 永停『启动中』」。
    ///
    /// ⚠️ 本用例会真实等待约 3 秒（`drainPipe` 的收尾时限），是套件里最慢的一条。
    func testDrainPipeReturnsWithinDeadlineWhenWriterEndStaysOpen() async throws {
        let (writer, url) = try makeWriter()
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("tail data\n".utf8))
        // **故意不关写端** —— 模拟写端被孙进程持有

        let start = Date()
        drainPipe(pipe, into: writer)
        let elapsed = Date().timeIntervalSince(start)
        writer.close()

        XCTAssertLessThan(elapsed, 5, "必须在收尾时限内返回，不得永久阻塞（原实现会挂死启动线程）")
        XCTAssertEqual(contents(of: url), "tail data\n", "已到达的数据仍须被排空落盘")
    }

    /// 管道里没有数据且写端仍开着 ⇒ 同样在时限内返回（不挂起）
    func testDrainPipeWithNoDataReturnsWithinDeadline() async throws {
        let (writer, _) = try makeWriter()
        let pipe = Pipe()   // 不写、不关

        let start = Date()
        drainPipe(pipe, into: writer)
        writer.close()

        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// 排空后剩余字节仍能被 `close()` 补刷（残行路径与排空路径配合）
    func testDrainThenCloseFlushesTrailingPartialLine() async throws {
        let (writer, url) = try makeWriter()
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("last line without newline".utf8))
        try pipe.fileHandleForWriting.close()

        drainPipe(pipe, into: writer)
        writer.close()

        XCTAssertEqual(contents(of: url), "last line without newline\n",
                       "排空得到的残行同样要由 close() 补刷")
    }
}
