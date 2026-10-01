//
//  SpeedMeterTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Download/SpeedMeter.swift` 的 `CounterActor`
//  （字节累加器；`SpeedMeter` 本体的 1 秒 ticker 依赖真实时间，不在本文件覆盖）。
//
//  **为什么值得测**：`CounterActor` 的 `takeInterval()` 是**单次消费语义** ——
//  源码注释点名：「连续调用两次，第二次必然得到 0……多调会把速度读低（分母仍是 1 秒）」。
//  这类「读一次就清零」的约定一旦被改成幂等读，速度显示会静默偏低，且没有任何编译期保护。
//
//  另一处是 `&+=` 溢出回绕：注释称「即便计数异常（例如调用方传了巨型值），
//  也只会得到一个奇怪的速度读数，而不会因整数溢出直接崩溃」。本文件把它钉住 ——
//  若有人「顺手」改成 `+=`，这里会以溢出陷阱（而非断言失败）暴露。
//

import XCTest
@testable import qwq

final class SpeedMeterTests: XCTestCase {

    // MARK: - 累加与取用

    /// 初始为 0
    func testStartsAtZero() async {
        let counter = CounterActor()
        let first = await counter.takeInterval()
        XCTAssertEqual(first, 0)
    }

    /// `add` 累加；`takeInterval` 返回累计值
    func testAddAccumulates() async {
        let counter = CounterActor()
        await counter.add(100)
        await counter.add(250)
        let taken = await counter.takeInterval()
        XCTAssertEqual(taken, 350)
    }

    /// ⚠️ **单次消费语义**：取出后清零，第二次调用必然得到 0
    func testTakeIntervalResetsAfterRead() async {
        let counter = CounterActor()
        await counter.add(500)

        let first = await counter.takeInterval()
        let second = await counter.takeInterval()

        XCTAssertEqual(first, 500)
        XCTAssertEqual(second, 0, "读取即清零：第二次必须得到 0（多调会让速度偏低）")
    }

    /// 清零之后继续累加，从 0 重新计
    func testAccumulatesAgainAfterTake() async {
        let counter = CounterActor()
        await counter.add(10)
        _ = await counter.takeInterval()
        await counter.add(7)

        let taken = await counter.takeInterval()
        XCTAssertEqual(taken, 7)
    }

    /// `add(0)` 不改变结果
    func testAddingZeroKeepsValue() async {
        let counter = CounterActor()
        await counter.add(42)
        await counter.add(0)
        let taken = await counter.takeInterval()
        XCTAssertEqual(taken, 42)
    }

    /// 负值会减少累计（`add` 不做正数校验 —— 校验在 `SpeedMeter.addBytes` 那层）
    func testNegativeAddReducesAccumulatedValue() async {
        let counter = CounterActor()
        await counter.add(100)
        await counter.add(-30)
        let taken = await counter.takeInterval()
        XCTAssertEqual(taken, 70)
    }

    /// 累计为负也能原样取出（不夹到 0）
    func testAccumulatedNegativeValueIsReturnedAsIs() async {
        let counter = CounterActor()
        await counter.add(-5)
        let taken = await counter.takeInterval()
        XCTAssertEqual(taken, -5)
    }

    // MARK: - 溢出回绕（注释点名的设计）

    /// ⚠️ `add` 用 `&+=` ⇒ 超过 `Int64.max` 时**回绕**而非陷阱崩溃。
    /// 本用例若在 `+=` 实现下运行，会以运行时溢出陷阱失败（而不是断言失败）——
    /// 这正是「把它改成 +=」会被立刻发现的哨兵。
    func testOverflowWrapsInsteadOfTrapping() async {
        let counter = CounterActor()
        await counter.add(Int64.max)
        await counter.add(1)

        let taken = await counter.takeInterval()
        XCTAssertEqual(taken, Int64.min, "溢出应回绕到 Int64.min，而不是崩溃")
    }

    /// 回绕是双向的：`Int64.min` 再减 1 回到 `Int64.max`
    func testUnderflowWrapsBackToMax() async {
        let counter = CounterActor()
        await counter.add(Int64.min)
        await counter.add(-1)
        let taken = await counter.takeInterval()
        XCTAssertEqual(taken, Int64.max)
    }

    // MARK: - 并发：actor 串行化保证不丢计数

    /// 多个并发任务各自累加 N 次 ⇒ 总数精确等于 总次数（actor 串行执行，无丢失）
    func testConcurrentAddsAreSerializedWithoutLoss() async {
        let counter = CounterActor()
        let tasks = 20
        let perTask = 50

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<tasks {
                group.addTask {
                    for _ in 0..<perTask { await counter.add(1) }
                }
            }
        }

        let taken = await counter.takeInterval()
        XCTAssertEqual(taken, Int64(tasks * perTask),
                       "20 个并发任务各加 50 次，总数必须是 1000（actor 串行化不丢计数）")
    }

    /// 「读取并清零」在 actor 内是**不可分割的一步**：并发 `takeInterval` 只有一个拿到值
    func testConcurrentTakesYieldTheValueExactlyOnce() async {
        let counter = CounterActor()
        await counter.add(999)

        let results = await withTaskGroup(of: Int64.self) { group -> [Int64] in
            for _ in 0..<8 {
                group.addTask { await counter.takeInterval() }
            }
            var collected: [Int64] = []
            for await value in group { collected.append(value) }
            return collected
        }

        XCTAssertEqual(results.filter { $0 == 999 }.count, 1,
                       "8 次并发取用中，恰好一次拿到 999，其余必须都是 0")
        XCTAssertEqual(results.filter { $0 == 0 }.count, 7)
        XCTAssertEqual(results.reduce(0, +), 999, "总和不丢不多")
    }

    /// 并发「加」与「取」之间不丢字节：把两阶段串起来看总和守恒
    func testAddsAndTakesConserveTotal() async {
        let counter = CounterActor()
        var taken: Int64 = 0

        for _ in 0..<10 {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<5 {
                    group.addTask { await counter.add(3) }
                }
            }
            taken += await counter.takeInterval()
        }

        XCTAssertEqual(taken, 10 * 5 * 3, "逐轮取用之和必须等于总投入（150）")
    }
}
