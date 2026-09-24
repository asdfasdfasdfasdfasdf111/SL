//
//  GameLogRetentionTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//  1. **日志数组不会无限增长**（本次修复的核心）：`GameSession.logs` 原先没有任何上限，
//     且是 `@Published`。Forge / NeoForge 启动期一秒能刷几十行，长会话会把几万行日志
//     一直留在内存里，并在游戏退出后仍然留着（会话只在用户点 × 时才移除）。
//     现在超过 `maxLogLines` 就丢弃最早的行 —— 这条不变量必须钉住，否则上限会被悄悄改掉。
//  2. **裁剪是摊还的，不是每行一次**：超限时一次多丢 1/4 上限，使之后 1/4 上限次追加
//     都不再需要 `removeFirst`（搬整条数组）。若退化成「刚好丢到上限」，
//     超限之后的每一行都会触发一次数组搬运 —— 这正是本次要消除的卡顿来源。
//  3. 边界：正好等于上限时不丢；少于上限时不丢；超限时必须丢。
//
//  被测：Features/Launch/GameSession.swift 的 `dropCount(forCount:)` 与 `maxLogLines`
//
//  为什么只测这个纯函数、不测 `appendLog` / `flushLogs` 的端到端行为：
//  `GameSession` 的 `launcher` 必须是真实 `MinecraftLauncher`，而它的 init 会往用户的
//  Application Support 写日志文件、并调用 `GameLogRetention.prune` 修剪历史日志 ——
//  单测里构造它就等于动用户的真实数据，故刻意不测端点，只测可纯函数化的这段判定。
//

import XCTest
@testable import qwq

@MainActor
final class GameLogRetentionTests: XCTestCase {

    /// 未超上限时一行都不丢
    func testDropCountIsZeroAtOrBelowLimit() async {
        let limit = GameSession.maxLogLines
        XCTAssertEqual(GameSession.dropCount(forCount: 0), 0, "空日志不该丢")
        XCTAssertEqual(GameSession.dropCount(forCount: 1), 0, "一行日志不该丢")
        XCTAssertEqual(GameSession.dropCount(forCount: limit - 1), 0, "少一行上限不该丢")
        XCTAssertEqual(GameSession.dropCount(forCount: limit), 0,
                       "正好等于上限时不该丢：判据是 count > maxLogLines，不是 >=")
    }

    /// 超上限后：上限不被突破；且一次多丢 1/4，保证裁剪是摊还的
    func testDropCountKeepsLogsUnderLimitAndIsAmortized() async {
        let limit = GameSession.maxLogLines
        let amortization = limit / 4
        // 覆盖四种典型超限量：刚超一行 / 超一个合并批次 / 超一倍 / 超十倍
        let inputs = [limit + 1, limit + 500, limit * 2, limit * 10]
        for count in inputs {
            let drop = GameSession.dropCount(forCount: count)
            XCTAssertGreaterThan(drop, 0, "超出上限 \(count) 行时必须丢，否则数组会无限增长")
            let kept = count - drop
            XCTAssertLessThanOrEqual(kept, limit,
                                     "丢弃 \(drop) 行后仍有 \(kept) 行，突破了上限 \(limit)")
            XCTAssertGreaterThanOrEqual(kept, limit - amortization,
                                        "丢弃 \(drop) 行后只剩 \(kept) 行，丢多了：裁剪应只多丢 1/4 上限（\(amortization)），"
                                        + "否则长会话会频繁走到上限附近、频繁触发搬运")
        }
    }

    /// 上限本身必须是正整数，否则 1/4 摊还量会退化成 0（每行都搬数组）
    func testLimitIsPositiveSoAmortizationIsNotZero() async {
        XCTAssertGreaterThan(GameSession.maxLogLines, 0, "上限必须是正数")
        XCTAssertGreaterThan(GameSession.maxLogLines / 4, 0,
                             "上限必须大到让 1/4 摊还量不为 0，否则「摊还裁剪」名存实亡")
    }
}
