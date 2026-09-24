//
//  DownloadSliceBudgetTests.swift
//  qwqTests
//
//  分片总超时预算的判定（`NetManager.sliceBudget(remainingBytes:bytesPerSecond:)`）。
//
//  MARK: - 背景：为什么这条公式值得单独钉住
//
//  原实现把分片总超时写死成 300s，与分片大小、网速都无关。对「连接健康、持续推进、只是慢」
//  的下载，这是一把无差别的一刀切，而后果**不是「晚点到」而是「失败」**：
//  每次超时给该源记一次 `sourceFails`（阈值 `maxFailPerSource = 3`），满 3 次该源被永久跳过；
//  全部源满 3 次就把文件置为 failed 并 `cleanupTemps` **删掉已下好的分片临时文件**（进度归零）。
//  触发面不窄：github / gitcode 这类「禁多线程」的源从不分片，整个文件就是一个分片。
//
//  现改为 `clamp(剩余 / 最慢实测速度 × 2, 300s, 1200s)`。公式里三件事都可能写错，
//  而调用点藏在真实网络栈的字节循环里测不到，所以抽成纯函数后在这里逐条钉死：
//   ① 下界不许放松（快连接 / 小分片的判定必须与改动前逐秒一致）；
//   ② 上界必须生效（病态涓流不能被无限拖住）；
//   ③ 无法估算时必须退回旧口径，而不是算出一个荒唐的值。
//
//  用例一律 `async`：工程默认隔离是 MainActor，同步用例会在 Xcode 26.2 上 abort 测试宿主
//  （见 `qwqTests/TESTING.md` §五）。
//

import XCTest
@testable import qwq

final class DownloadSliceBudgetTests: XCTestCase {

    private let floor: TimeInterval = 300
    private let ceiling: TimeInterval = 1200

    /// ① 快连接不许被放松：100MB @ 10MB/s 的预计耗时远小于下界，预算必须仍是 300s。
    /// 这条是「改动没有顺手放宽正常路径」的证据。
    func testFastConnectionKeepsLegacyFloor() async {
        let budget = NetManager.sliceBudget(remainingBytes: 100 * 1024 * 1024, bytesPerSecond: 10 * 1024 * 1024)
        XCTAssertEqual(budget, floor, "快连接 / 小分片的预算必须与改动前的 300s 一致，不得放松")
    }

    /// ② 本次要修的就是这一档：慢但**健康**的连接。
    /// 用例自带「这确实是旧口径下的受害者」的证明 —— 预计耗时本身就超过 300s，
    /// 所以旧口径必然误杀；而新预算必须**大于预计耗时**，否则等于没修。
    func testSlowButHealthyConnectionIsNoLongerKilled() async {
        let remaining: Int64 = 100 * 1024 * 1024        // 100MB
        let speed: Double = 300 * 1024                  // 300KB/s —— 中国大陆拉 GitHub 的常见速度
        let timeNeeded = Double(remaining) / speed      // ≈ 341s

        XCTAssertGreaterThan(
            timeNeeded, floor,
            "用例数据本身必须落在旧口径的受害者区间（预计耗时 > 300s），否则这条用例证明不了什么"
        )

        let budget = NetManager.sliceBudget(remainingBytes: remaining, bytesPerSecond: speed)
        XCTAssertGreaterThan(budget, timeNeeded, "预算必须覆盖按实测速度算出的预计耗时，否则健康下载仍会被误杀")
        XCTAssertLessThanOrEqual(budget, ceiling, "仍须受上界约束")
    }

    /// ③ 上界必须生效：病态涓流（2KB/s 下 500MB）算出的是数天量级，不能被真的等下去。
    func testPathologicalTrickleIsCappedAtCeiling() async {
        let budget = NetManager.sliceBudget(remainingBytes: 500 * 1024 * 1024, bytesPerSecond: 2 * 1024)
        XCTAssertEqual(budget, ceiling, "病态涓流必须被上界截断")
    }

    /// ④ 剩余量不可知（服务端没有 Content-Length，`sliceUndone` 返回 -1）→ 退回旧口径 300s。
    /// 这是**有意保留**的旧行为，不是漏改：没有大小就没有耗时基准，任何估算都是编的。
    /// 若将来要覆盖这一档，必须先拿到可信的总长度。
    func testUnknownRemainingFallsBackToLegacyFloor() async {
        for unknown in [Int64(-1), 0] {
            let budget = NetManager.sliceBudget(remainingBytes: unknown, bytesPerSecond: 1024 * 1024)
            XCTAssertEqual(budget, floor, "剩余量不可知（\(unknown)）时必须退回 300s 旧口径")
        }
    }

    /// ⑤ 速度不可用（未采样到 / 除零 / NaN / 无穷）不许算出荒唐值。
    /// `slowestSpeed` 的初值就是 `.infinity`，这条守的是「它在第一次采样前被用到」的路径。
    func testInvalidSpeedFallsBackToFloor() async {
        for speed in [0.0, -1.0, Double.nan, Double.infinity] {
            let budget = NetManager.sliceBudget(remainingBytes: 100 * 1024 * 1024, bytesPerSecond: speed)
            XCTAssertEqual(budget, floor, "速度不可用（\(speed)）时必须退回 300s，而不是算出 NaN 或 0")
        }
    }

    /// ⑥ 不变量：剩余越多，预算不许变小（含上界截断后仍单调不减）。
    func testBudgetIsMonotonicInRemainingBytes() async {
        let speed: Double = 512 * 1024
        var previous: TimeInterval = 0
        for megabytes in [1, 4, 16, 64, 256, 1024, 4096] {
            let budget = NetManager.sliceBudget(remainingBytes: Int64(megabytes) * 1024 * 1024, bytesPerSecond: speed)
            XCTAssertGreaterThanOrEqual(budget, previous, "剩余量增大时预算不得变小（\(megabytes)MB）")
            XCTAssertGreaterThanOrEqual(budget, floor)
            XCTAssertLessThanOrEqual(budget, ceiling)
            previous = budget
        }
    }
}
