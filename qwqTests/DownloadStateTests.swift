//
//  DownloadStateTests.swift
//  qwqTests
//
//  覆盖 `Core/Download/DownloadProgress.swift` 与 `DownloadState.swift`。
//  这两个类型是纯值类型，核心风险在派生属性的边界处理：
//  totalBytes = 0 / -1（旧实现的「大小未知」语义）不得崩溃或产生 NaN。
//

import XCTest
@testable import qwq

final class DownloadStateTests: XCTestCase {

    // MARK: - DownloadProgress.fraction

    /// 完成比例落在 [0, 1]，并对越界值做钳制
    func testFractionIsClampedToUnitRange() async {
        XCTAssertEqual(DownloadProgress(bytesWritten: 0, totalBytes: 100).fraction, 0, accuracy: 1e-12)
        XCTAssertEqual(DownloadProgress(bytesWritten: 25, totalBytes: 100).fraction, 0.25, accuracy: 1e-12)
        XCTAssertEqual(DownloadProgress(bytesWritten: 50, totalBytes: 100).fraction, 0.5, accuracy: 1e-12)
        XCTAssertEqual(DownloadProgress(bytesWritten: 100, totalBytes: 100).fraction, 1.0, accuracy: 1e-12)
        // 已写字节数超出总大小时钳到 1，不得溢出
        XCTAssertEqual(DownloadProgress(bytesWritten: 150, totalBytes: 100).fraction, 1.0, accuracy: 1e-12)
        // 字节数为负（异常上报）时钳到 0
        XCTAssertEqual(DownloadProgress(bytesWritten: -10, totalBytes: 100).fraction, 0, accuracy: 1e-12)
    }

    /// totalBytes 为 0 或 -1（大小未知）时 fraction 为 0，且不得触发除零
    func testFractionIsZeroWhenTotalBytesIsUnknown() async {
        XCTAssertEqual(DownloadProgress(bytesWritten: 10, totalBytes: 0).fraction, 0, accuracy: 1e-12)
        XCTAssertEqual(DownloadProgress(bytesWritten: 10, totalBytes: -1).fraction, 0, accuracy: 1e-12)
        XCTAssertFalse(DownloadProgress(bytesWritten: 10, totalBytes: 0).fraction.isNaN)
        XCTAssertFalse(DownloadProgress(bytesWritten: 10, totalBytes: -1).fraction.isNaN)
    }

    // MARK: - DownloadProgress.estimatedRemaining

    /// 剩余时间 = (总量 - 已写) / 速度
    func testEstimatedRemainingUsesRemainingBytesOverSpeed() async throws {
        let progress = DownloadProgress(bytesWritten: 0, totalBytes: 100, speedBytesPerSecond: 50)
        XCTAssertEqual(try XCTUnwrap(progress.estimatedRemaining), 2.0, accuracy: 1e-9)

        let halfDone = DownloadProgress(bytesWritten: 50, totalBytes: 100, speedBytesPerSecond: 25)
        XCTAssertEqual(try XCTUnwrap(halfDone.estimatedRemaining), 2.0, accuracy: 1e-9)
    }

    /// 速度为 0 / 为负、总大小未知时返回 nil；已写超出总量时钳到 0
    func testEstimatedRemainingIsNilForUnusableInputs() async throws {
        XCTAssertNil(DownloadProgress(bytesWritten: 0, totalBytes: 100, speedBytesPerSecond: 0).estimatedRemaining)
        XCTAssertNil(DownloadProgress(bytesWritten: 0, totalBytes: 100, speedBytesPerSecond: -1).estimatedRemaining)
        XCTAssertNil(DownloadProgress(bytesWritten: 0, totalBytes: 0, speedBytesPerSecond: 50).estimatedRemaining)
        XCTAssertNil(DownloadProgress(bytesWritten: 0, totalBytes: -1, speedBytesPerSecond: 50).estimatedRemaining)

        let overshoot = DownloadProgress(bytesWritten: 150, totalBytes: 100, speedBytesPerSecond: 50)
        XCTAssertEqual(try XCTUnwrap(overshoot.estimatedRemaining), 0, accuracy: 1e-9)
    }

    /// 起始快照：未写、大小未知、无速度
    func testZeroProgressSnapshot() async {
        let zero = DownloadProgress.zero
        XCTAssertEqual(zero.bytesWritten, 0)
        XCTAssertEqual(zero.totalBytes, -1)
        XCTAssertEqual(zero.speedBytesPerSecond, 0)
        XCTAssertEqual(zero.fraction, 0, accuracy: 1e-12)
        XCTAssertNil(zero.estimatedRemaining)
    }

    // MARK: - DownloadProgress 值语义

    func testProgressEquatable() async {
        let lhs = DownloadProgress(bytesWritten: 1024, totalBytes: 4096, speedBytesPerSecond: 512)
        let rhs = DownloadProgress(bytesWritten: 1024, totalBytes: 4096, speedBytesPerSecond: 512)
        XCTAssertEqual(lhs, rhs)
        XCTAssertNotEqual(lhs, DownloadProgress(bytesWritten: 2048, totalBytes: 4096, speedBytesPerSecond: 512))
        XCTAssertNotEqual(lhs, DownloadProgress(bytesWritten: 1024, totalBytes: 8192, speedBytesPerSecond: 512))
        XCTAssertNotEqual(lhs, DownloadProgress(bytesWritten: 1024, totalBytes: 4096, speedBytesPerSecond: 1024))
    }

    // MARK: - DownloadState 值语义

    func testStateEquatable() async {
        let progress = DownloadProgress(bytesWritten: 1, totalBytes: 2)
        XCTAssertEqual(DownloadState.idle, .idle)
        XCTAssertEqual(DownloadState.preparing, .preparing)
        XCTAssertEqual(DownloadState.verifying, .verifying)
        XCTAssertEqual(DownloadState.merging, .merging)
        XCTAssertEqual(DownloadState.completed, .completed)
        XCTAssertEqual(DownloadState.cancelled, .cancelled)

        XCTAssertEqual(DownloadState.downloading(progress), .downloading(progress))
        XCTAssertNotEqual(DownloadState.downloading(progress), .downloading(DownloadProgress(bytesWritten: 2, totalBytes: 2)))
        XCTAssertNotEqual(DownloadState.downloading(progress), .verifying)

        XCTAssertEqual(DownloadState.failed(.timeout), .failed(.timeout))
        XCTAssertNotEqual(DownloadState.failed(.timeout), .failed(.cancelled))
        XCTAssertNotEqual(DownloadState.failed(.httpStatus(404)), .failed(.httpStatus(500)))
        XCTAssertNotEqual(DownloadState.completed, .cancelled)
        XCTAssertNotEqual(DownloadState.failed(.timeout), .cancelled)
    }

    // MARK: - DownloadState 派生属性

    /// 仅 completed / cancelled / failed 为终态
    func testTerminalStates() async {
        let progress = DownloadProgress(bytesWritten: 1, totalBytes: 2)
        let terminal: [DownloadState] = [.completed, .cancelled, .failed(.timeout)]
        let nonTerminal: [DownloadState] = [.idle, .preparing, .downloading(progress), .verifying, .merging]

        for state in terminal {
            XCTAssertTrue(state.isTerminal, "\(state) 应为终态")
        }
        for state in nonTerminal {
            XCTAssertFalse(state.isTerminal, "\(state) 不应为终态")
        }
    }

    /// progress 仅在 downloading 下非空，error 仅在 failed 下非空
    func testProgressAndErrorAccessors() async {
        let progress = DownloadProgress(bytesWritten: 512, totalBytes: 1024)
        XCTAssertNil(DownloadState.idle.progress)
        XCTAssertNil(DownloadState.verifying.progress)
        XCTAssertNil(DownloadState.completed.progress)
        XCTAssertEqual(DownloadState.downloading(progress).progress, progress)

        XCTAssertNil(DownloadState.completed.error)
        XCTAssertNil(DownloadState.downloading(progress).error)
        XCTAssertEqual(DownloadState.failed(.diskFull).error, .diskFull)
    }

    /// 各错误 case 均有面向用户的中文描述
    func testDownloadErrorDescriptionsAreLocalized() async {
        let cases: [DownloadError] = [
            .sourceUnavailable,
            .httpStatus(404),
            .rangeNotSupported,
            .checksumMismatch,
            .diskFull,
            .cancelled,
            .timeout,
            .unknown("自定义原因")
        ]
        for error in cases {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error) 缺少错误描述")
        }
        XCTAssertTrue(DownloadError.httpStatus(404).errorDescription?.contains("404") == true)
        XCTAssertEqual(DownloadError.unknown("自定义原因").errorDescription, "自定义原因")
    }
}
