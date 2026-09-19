//
//  LaunchStateTests.swift
//  qwqTests
//
//  覆盖 `Features/Launch/LaunchState.swift`、`LaunchError.swift` 与 `LaunchResult.swift`。
//  三者均为纯值类型，是 UI 由 `LaunchState` 派生观感状态的依据，
//  核心风险在 Equatable 语义（同状态不同载荷需判不等）与面向用户的中文错误描述。
//
//  未覆盖：`LaunchService` / `LaunchArgumentBuilder` / `GameProcessController` 均为纯协议，
//  工程内尚无实现，缺少注入点，见本文件末尾说明与 TESTING.md。
//

import XCTest
@testable import qwq

/// 文本是否包含中日韩统一表意文字，用于断言错误描述已做本地化
private func containsChinese(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x4E00...0x9FFF).contains(scalar.value)
    }
}

final class LaunchStateTests: XCTestCase {

    private let sessionID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
    private let logURL = URL(fileURLWithPath: "/tmp/launch/latest.log")

    // MARK: - 无载荷状态

    /// 不带载荷的各状态按 case 判等，不同 case 互不等
    func testPlainStatesEquality() {
        XCTAssertEqual(LaunchState.idle, .idle)
        XCTAssertEqual(LaunchState.preparing, .preparing)
        XCTAssertEqual(LaunchState.resolvingJava, .resolvingJava)
        XCTAssertEqual(LaunchState.buildingArguments, .buildingArguments)
        XCTAssertEqual(LaunchState.launching, .launching)
        XCTAssertEqual(LaunchState.running, .running)
        XCTAssertEqual(LaunchState.stopping, .stopping)

        let plainStates: [LaunchState] = [
            .idle, .preparing, .resolvingJava, .buildingArguments, .launching, .running, .stopping
        ]
        for (index, lhs) in plainStates.enumerated() {
            for rhs in plainStates where rhs != lhs {
                XCTAssertNotEqual(lhs, rhs, "\(index) 号状态不应与另一个无载荷状态判等")
            }
        }
    }

    // MARK: - 进度状态

    /// 进度状态携带的 Double 参与判等：值相同才相等
    func testProgressStatesEquality() {
        XCTAssertEqual(LaunchState.verifyingFiles(0.3), .verifyingFiles(0.3))
        XCTAssertEqual(LaunchState.downloading(0.75), .downloading(0.75))
        XCTAssertNotEqual(LaunchState.verifyingFiles(0.3), .verifyingFiles(0.4))
        XCTAssertNotEqual(LaunchState.downloading(0.75), .downloading(0.25))
        // 同为进度但阶段不同，值相同也不相等
        XCTAssertNotEqual(LaunchState.verifyingFiles(0.5), .downloading(0.5))
        XCTAssertNotEqual(LaunchState.verifyingFiles(0.5), .preparing)
    }

    /// 进度边界值 0 与 1 被原样保留，实现不做钳制
    func testProgressBoundaryValuesArePreserved() {
        guard case .verifyingFiles(let lower) = LaunchState.verifyingFiles(0) else {
            return XCTFail("无法取出 verifyingFiles 的进度值")
        }
        XCTAssertEqual(lower, 0, accuracy: 1e-12)

        guard case .downloading(let upper) = LaunchState.downloading(1) else {
            return XCTFail("无法取出 downloading 的进度值")
        }
        XCTAssertEqual(upper, 1, accuracy: 1e-12)

        // 现状记录：传入越界值时实现原样保留，未做 [0, 1] 钳制
        guard case .verifyingFiles(let outOfRange) = LaunchState.verifyingFiles(1.5) else {
            return XCTFail("无法取出 verifyingFiles 的进度值")
        }
        XCTAssertEqual(outOfRange, 1.5, accuracy: 1e-12)
    }

    // MARK: - 终态

    /// finished 携带的 LaunchResult 参与判等
    func testFinishedStateEquality() {
        let success = LaunchResult(exitCode: 0, sessionID: sessionID, logURL: logURL, duration: 12.5)
        let sameSuccess = LaunchResult(exitCode: 0, sessionID: sessionID, logURL: logURL, duration: 12.5)
        XCTAssertEqual(LaunchState.finished(success), .finished(sameSuccess))

        let crashed = LaunchResult(exitCode: 1, sessionID: sessionID, logURL: logURL, duration: 12.5)
        XCTAssertNotEqual(LaunchState.finished(success), .finished(crashed))
        XCTAssertNotEqual(LaunchState.finished(success), .idle)
        XCTAssertNotEqual(LaunchState.finished(success), .failed(.cancelled))
    }

    /// failed 携带的 LaunchError 参与判等
    func testFailedStateEquality() {
        XCTAssertEqual(LaunchState.failed(.cancelled), .failed(.cancelled))
        XCTAssertEqual(LaunchState.failed(.javaNotFound(requiredMajorVersion: 21)), .failed(.javaNotFound(requiredMajorVersion: 21)))
        XCTAssertNotEqual(LaunchState.failed(.cancelled), .failed(.unknown("其他原因")))
        XCTAssertNotEqual(LaunchState.failed(.javaNotFound(requiredMajorVersion: 21)), .failed(.javaNotFound(requiredMajorVersion: 17)))
    }

    /// 仅 finished / failed 为终态
    func testTerminalStates() {
        let terminal: [LaunchState] = [
            .finished(LaunchResult(exitCode: 0, sessionID: sessionID)),
            .failed(.cancelled)
        ]
        let nonTerminal: [LaunchState] = [
            .idle, .preparing, .verifyingFiles(1), .downloading(1),
            .resolvingJava, .buildingArguments, .launching, .running, .stopping
        ]
        for state in terminal {
            XCTAssertTrue(state.isTerminal)
        }
        for state in nonTerminal {
            XCTAssertFalse(state.isTerminal, "\(state) 不应为终态")
        }
    }

    // MARK: - LaunchResult

    /// 退出码非 0 判为异常退出；默认参数下无日志、时长为 0
    func testLaunchResultDefaultsAndAbnormalExit() {
        let defaults = LaunchResult(exitCode: 0, sessionID: sessionID)
        XCTAssertNil(defaults.logURL)
        XCTAssertEqual(defaults.duration, 0)
        XCTAssertFalse(defaults.isAbnormalExit)

        let crashed = LaunchResult(exitCode: 1, sessionID: sessionID, logURL: logURL, duration: 42)
        XCTAssertTrue(crashed.isAbnormalExit)
        XCTAssertEqual(crashed.logURL, logURL)
        XCTAssertEqual(crashed.duration, 42, accuracy: 1e-12)
    }

    // MARK: - LaunchError 本地化

    /// 每个错误 case 都有非空且含中文的描述
    func testLaunchErrorDescriptionsAreChinese() {
        let errors: [LaunchError] = [
            .instanceNotFound(version: "1.20.1"),
            .javaNotFound(requiredMajorVersion: 21),
            .fileVerificationFailed(reason: "client.jar 缺失"),
            .processStartFailed(reason: "权限不足"),
            .cancelled,
            .unknown("底层异常")
        ]
        for error in errors {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error) 缺少错误描述")
            XCTAssertTrue(containsChinese(description), "错误描述应为中文：\(description)")
        }
    }

    /// 描述中包含关键参数，便于用户自查
    func testLaunchErrorDescriptionsCarryKeyParameters() {
        let javaError = LaunchError.javaNotFound(requiredMajorVersion: 21)
        XCTAssertTrue(javaError.errorDescription?.contains("Java 21") == true)
        XCTAssertTrue(javaError.errorDescription?.contains("Java 管理") == true)

        let instanceError = LaunchError.instanceNotFound(version: "1.20.1")
        XCTAssertTrue(instanceError.errorDescription?.contains("1.20.1") == true)

        let verificationError = LaunchError.fileVerificationFailed(reason: "client.jar 缺失")
        XCTAssertTrue(verificationError.errorDescription?.contains("client.jar 缺失") == true)
    }
}

// MARK: - 未覆盖项说明

/*
 以下类型本轮未写用例，原因是缺少可注入的实现或注入点（不改源码，仅记录建议）：

 1. LaunchService / GameProcessController / LaunchArgumentBuilder：均为纯协议，
    工程内没有默认实现，也没有可替换的构造入口，无法在不新增生产代码的前提下断言行为。
    建议：落地 `DefaultLaunchService` 时把上述三者作为构造参数注入，
    届时可用 fake 断言「参数顺序 / 进程拉起 / 状态迁移」。

 2. DefaultLaunchPreflight：已有可注入的四个校验器（ClientFileVerifier 等），
    具备可测性，但本轮任务未要求覆盖；建议后续补一份
    `LaunchPreflightTests`，断言 skipResourceCheck 短路、四段调用顺序与进度区间映射（0~0.5 / 0.5~1）。

 3. GameSessionStore / InMemoryGameSessionStore：有默认实现，但 `register` 需要
    `ManagedProcess`，而 `ManagedProcess` 强依赖真实 `Process` 实例（无协议抽象），
    缺少注入点。建议：把 `ManagedProcess` 抽象为协议（如 `GameProcess`），
    或在测试中以 `/bin/sleep` 作为受控进程验证 register → observe → terminate 链路。
 */
