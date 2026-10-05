//
//  NetDownloadStateTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Download/NetDownloadState.swift`（`NetManager.Slice` / `FileRecord` 一族）。
//
//  **为什么值得测**：这是下载引擎的**状态模型** —— 分片的剩余量、文件的完成度、
//  源是否全部判死，全靠这几个派生属性。它们错了不会崩，只会让**调度器做出错误决策**：
//  重复建片 → 同一字节区间被并发下载 → 合并出「尾部重复」的坏文件（源码注释里记的正是这条）。
//  该文件此前 0 测试触达，且有 fix 历史。
//
//  本文件特别钉住源码注释里**自认的三处问题**（都是代码事实，不是新需求）：
//  1. `Slice.end(of:)` 在**分片表里找不到自己**时返回 `fileSize - 1`（文件末尾）——
//     注释原话：「分片表不同步这个错误会被伪装成这片要下到文件尾，不会报错但结论错」；
//  2. `Slice.undone(of:)` 对 `fileSize == -2`（尚未获取大小）**没有特判**，
//     经 `max(0, ·)` 得到 0 —— 注释原话：「表现为这片已经没有剩余……不会崩但结论是错的」；
//  3. `isAllSourcesFailed` 的分界是 `<`：失败次数**恰好等于** `maxFail` 时已算判死。
//

import XCTest
@testable import qwq

final class NetDownloadStateTests: XCTestCase {

    // MARK: - 夹具

    private func makeRecord(urlCount: Int = 2, fileSize: Int64 = 100) -> NetManager.FileRecord {
        let urls = (0..<urlCount).map { URL(string: "https://example.invalid/\($0)")! }
        let record = NetManager.FileRecord(
            SLNetFile(urls: urls, destination: URL(fileURLWithPath: "/tmp/dl/out.bin"))
        )
        record.fileSize = fileSize
        return record
    }

    @discardableResult
    private func addSlice(_ record: NetManager.FileRecord, start: Int64, sourceIndex: Int = 0) -> NetManager.Slice {
        let slice = NetManager.Slice(start: start, sourceIndex: sourceIndex)
        record.slices.append(slice)
        return slice
    }

    // MARK: - Slice.end(of:)

    /// 中间分片的结束位置 = 下一片起点 − 1（与分片在数组里的顺序无关）
    func testEndOfMiddleSliceIsNextStartMinusOne() async {
        let record = makeRecord(fileSize: 100)
        let first = addSlice(record, start: 0)
        addSlice(record, start: 40)      // 后一片
        addSlice(record, start: 70)

        XCTAssertEqual(first.end(of: record), 39)
    }

    /// 最后一片（按 start 排序后的末尾）结束位置 = fileSize − 1
    func testEndOfLastSliceIsFileSizeMinusOne() async {
        let record = makeRecord(fileSize: 100)
        addSlice(record, start: 0)
        let last = addSlice(record, start: 40)

        XCTAssertEqual(last.end(of: record), 99)
    }

    /// 分片以**乱序**加入时结论不变（`end` 内部先排序）
    func testEndIsIndependentOfInsertionOrder() async {
        let record = makeRecord(fileSize: 100)
        let third = addSlice(record, start: 70)
        let first = addSlice(record, start: 0)
        let second = addSlice(record, start: 40)

        XCTAssertEqual(first.end(of: record), 39)
        XCTAssertEqual(second.end(of: record), 69)
        XCTAssertEqual(third.end(of: record), 99)
    }

    /// ⚠️ **自认问题 1**：分片表里找不到自己 ⇒ 返回 `fileSize - 1`（文件末尾），
    /// 而不是报错或返回 0。这条「静默伪装」被钉住，避免将来有人误以为它安全。
    func testEndFallsBackToFileEndWhenSliceNotInRecord() async {
        let record = makeRecord(fileSize: 100)
        addSlice(record, start: 0)
        let orphan = NetManager.Slice(start: 40, sourceIndex: 0)   // 未加入 record.slices

        XCTAssertEqual(orphan.end(of: record), 99,
                       "找不到自己时兜底返回文件末尾（已知的静默伪装，非期望语义）")
    }

    // MARK: - Slice.undone(of:)

    /// 正常情形：剩余 = end + 1 − (start + done)。
    /// 分片 [0, 39]，已下 10 ⇒ 剩余 30
    func testUndoneIsRemainingBytes() async {
        let record = makeRecord(fileSize: 100)
        let first = addSlice(record, start: 0)
        addSlice(record, start: 40)
        first.done = 10

        XCTAssertEqual(first.undone(of: record), 30)
    }

    /// 最后一片：`fileSize − 1 + 1 − done` = `fileSize − done`
    func testUndoneOfLastSlice() async {
        let record = makeRecord(fileSize: 100)
        addSlice(record, start: 0)
        let last = addSlice(record, start: 40)
        last.done = 100 - 40

        XCTAssertEqual(last.undone(of: record), 0, "下满后剩余为 0")
    }

    /// `fileSize == -1`（大小未知）⇒ 返回 **-1 表示「不限」**（调用方必须特判）
    func testUndoneReturnsMinusOneWhenSizeUnknown() async {
        let record = makeRecord(fileSize: -1)
        let slice = addSlice(record, start: 0)

        XCTAssertEqual(slice.undone(of: record), -1)
    }

    /// `done` 超过区间长度时被 `max(0, ·)` 夹到 0，不返回负数
    func testUndoneIsClampedToZero() async {
        let record = makeRecord(fileSize: 100)
        let first = addSlice(record, start: 0)
        addSlice(record, start: 40)
        first.done = 999   // 远超区间长度

        XCTAssertEqual(first.undone(of: record), 0)
    }

    /// ⚠️ **自认问题 2**：`fileSize == -2`（尚未获取大小）**没有特判** ⇒
    /// `end` 兜底成 `-3`，`max(0, -2)` = 0 ⇒ 「这片已经没有剩余」。
    /// 注释称正常流程先取大小故暂不可达，但结论是错的 —— 钉住它。
    func testUndoneOfNotYetSizedFileIsZeroNotMinusOne() async {
        let record = makeRecord(fileSize: -2)
        let slice = addSlice(record, start: 0)

        XCTAssertEqual(slice.undone(of: record), 0,
                       "`-2` 未特判，经 max(0,·) 得 0（已知问题；`-1` 才是「不限」）")
    }

    // MARK: - SliceState 与 activeSliceCount

    /// `downloading` 与 `resumed` 语义上**都是「正在跑」**，判定活跃分片时必须一起算
    func testActiveSliceCountTreatsDownloadingAndResumedAlike() async {
        let record = makeRecord()
        let a = addSlice(record, start: 0)
        let b = addSlice(record, start: 10)
        let c = addSlice(record, start: 20)
        let d = addSlice(record, start: 30)

        a.state = .downloading
        b.state = .resumed
        c.state = .done
        d.state = .failed

        XCTAssertEqual(record.activeSliceCount, 2, "只有 downloading + resumed 算活跃")
    }

    /// 默认状态是 `downloading`
    func testSliceDefaultStateIsDownloading() async {
        let record = makeRecord()
        XCTAssertEqual(addSlice(record, start: 0).state, .downloading)
    }

    /// `superseded` 默认为 false（未知大小时防止重复建片的关键标记）
    func testSupersededDefaultsToFalse() async {
        let record = makeRecord()
        XCTAssertFalse(addSlice(record, start: 0).superseded)
    }

    /// `slice(_:)` 按 id 查；查不到返回 nil
    func testSliceLookupByID() async {
        let record = makeRecord()
        let slice = addSlice(record, start: 0)
        XCTAssertTrue(record.slice(slice.id) === slice)
        XCTAssertNil(record.slice(UUID()))
    }

    // MARK: - FileRecord.isTerminal

    /// `merging` **不是**终止态（合并还在跑，取消时不能跳过它）
    func testMergingIsNotTerminal() async {
        let record = makeRecord()
        for state in [NetManager.FileState.waiting, .loading, .merging] {
            record.state = state
            XCTAssertFalse(record.isTerminal, "\(state) 不应算终止态")
        }
    }

    func testDoneAndFailedAreTerminal() async {
        let record = makeRecord()
        record.state = .done
        XCTAssertTrue(record.isTerminal)
        record.state = .failed
        XCTAssertTrue(record.isTerminal)
    }

    // MARK: - FileRecord.progressValue

    /// `.done` 直接返回 1，**不依赖分片累计** —— 否则最后一片 done 未回填时界面到不了 100%
    func testProgressIsOneWhenDoneEvenWithoutSlices() async {
        let record = makeRecord(fileSize: 100)
        record.state = .done
        XCTAssertEqual(record.progressValue, 1, "没有分片也要返回 1（避免界面卡在 99%）")
    }

    /// 大小未知（`fileSize <= 0`）⇒ 返回 0，不拿负数做除法
    func testProgressIsZeroWhenSizeNotPositive() async {
        for size in [Int64(-2), -1, 0] {
            let record = makeRecord(fileSize: size)
            addSlice(record, start: 0).done = 10
            XCTAssertEqual(record.progressValue, 0, "fileSize=\(size) 时应返回 0")
        }
    }

    /// 正常情形：各分片 `done` 求和 / fileSize
    func testProgressIsSumOfDoneOverFileSize() async {
        let record = makeRecord(fileSize: 100)
        addSlice(record, start: 0).done = 25
        addSlice(record, start: 25).done = 25

        XCTAssertEqual(record.progressValue, 0.5, accuracy: 1e-9)
    }

    /// 求和超过 fileSize 时被 `min(1, ·)` 夹住，不返回 >1
    func testProgressIsClampedToOne() async {
        let record = makeRecord(fileSize: 100)
        addSlice(record, start: 0).done = 80
        addSlice(record, start: 80).done = 80

        XCTAssertEqual(record.progressValue, 1)
    }

    // MARK: - FileRecord.isAllSourcesFailed

    /// 分界是 `<`：**恰好等于** `maxFail` 时已算判死
    func testAllSourcesFailedBoundaryIsStrictlyLessThan() async {
        let record = makeRecord(urlCount: 2)
        record.sourceFails = [0: 3, 1: 3]
        XCTAssertTrue(record.isAllSourcesFailed(3), "等于 maxFail 即判死（分界是 <）")

        record.sourceFails = [0: 3, 1: 2]
        XCTAssertFalse(record.isAllSourcesFailed(3), "还有一个源没到上限 ⇒ 未全判死")
    }

    /// 没有源记账（默认 0）⇒ 只要 `maxFail > 0` 就还有可用源
    func testNoFailuresMeansSourcesStillAvailable() async {
        let record = makeRecord(urlCount: 2)
        XCTAssertFalse(record.isAllSourcesFailed(3))
    }

    /// 被记进 `sourcesOnce`（不支持断点续传）的源**仍然可用**，只要它自己没失败到上限。
    ///
    /// 2026-10-05 语义修正：`sourcesOnce` 表示「该源忽略 Range，只能整份下」，**不是**「源已死」——
    /// 从 0 整份下载不需要 Range，把它当死源会让整个文件被判失败，用户侧现象就是
    /// 「下载源不支持断点续传就不能下了」（真实故障，源其实是好的）。
    func testSourcesOnceAreStillAvailableIfNotFailedOut() async {
        let record = makeRecord(urlCount: 2)
        record.sourcesOnce = [0]
        record.sourceFails = [1: 3]

        XCTAssertFalse(record.isAllSourcesFailed(3),
                       "源 0 只是不能续传（失败次数 0）⇒ 还能整份下，不算全判死")
    }

    /// 所有源都在 `sourcesOnce` 里、且都没失败过 ⇒ **不判死**（它们都能整份下完这个文件）
    func testAllSourcesOnceIsNotAFailure() async {
        let record = makeRecord(urlCount: 2)
        record.sourcesOnce = [0, 1]
        XCTAssertFalse(record.isAllSourcesFailed(3),
                       "不能续传 ≠ 不能用：整份下载不依赖 Range")
    }

    /// 但真失败到上限时照样判死 —— `sourcesOnce` 不参与判死不等于给这类源免死金牌
    func testSourcesOnceStillDiesWhenActuallyFailing() async {
        let record = makeRecord(urlCount: 1)
        record.sourcesOnce = [0]
        record.sourceFails = [0: 3]
        XCTAssertTrue(record.isAllSourcesFailed(3), "真连不上/反复失败时仍要判死，避免无限重试")
    }

    /// 没有任何候选源 ⇒ 循环体为空 ⇒ 返回 true（空真）
    func testNoURLsYieldsTrue() async {
        let record = makeRecord(urlCount: 0)
        XCTAssertTrue(record.isAllSourcesFailed(3))
    }

    /// `maxFail` 为 1 时，一次失败即判死
    func testMaxFailOneMeansSingleFailureKillsSource() async {
        let record = makeRecord(urlCount: 1)
        record.sourceFails = [0: 1]
        XCTAssertTrue(record.isAllSourcesFailed(1))
        record.sourceFails = [0: 0]
        XCTAssertFalse(record.isAllSourcesFailed(1))
    }
}
