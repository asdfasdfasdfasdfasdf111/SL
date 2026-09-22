//
//  JavaResolverBridgeTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//  1. 超时即放弃：`resolveSynchronously` 在超时后必须返回 nil 并立刻交还控制权，
//     绝不阻塞启动链路（它被同步上下文调用，内部用信号量等待）；
//  2. 失败/超时都不抛错、不崩溃：解析未命中走日志 + nil，由调用方回退旧链路；
//  3. 返回值的形状契约：非 nil 时必须是本机存在的文件 URL，而不是任意 URL；
//  4. 每次调用的信号量相互独立：连续/并发调用不得死锁或串扰。
//
//  已知无法断言的部分（缺注入点，见文末注释）：
//  `DefaultJavaResolver()` 在实现内硬编码，无法注入 fake 仓储，因此
//  「扫描失败」「已发现 Java 但无兼容版本」这两条失败路径无法与「超时」区分，
//  不能构造确定性断言。
//
//  被测：Features/Java/JavaResolverBridge.swift
//

import XCTest
@testable import qwq

final class JavaResolverBridgeTests: XCTestCase {

    // MARK: - 超时路径

    /// timeout 为 0 时必然超时返回 nil（detached 任务尚未被调度，信号量不可能提前放行）
    func testZeroTimeoutReturnsNil() async {
        XCTAssertNil(JavaResolverBridge.resolveSynchronously(minimumMajor: 17,
                                                            mcVersion: "1.20.1",
                                                            timeout: 0))
    }

    /// 极小超时同样返回 nil：等待上限必须真正生效
    func testTinyTimeoutReturnsNil() async {
        XCTAssertNil(JavaResolverBridge.resolveSynchronously(minimumMajor: 21,
                                                            mcVersion: "1.21.4",
                                                            timeout: 0.001))
    }

    /// 负数超时（调用方误传）落在过去，按超时处理返回 nil，不得崩溃或永久等待
    func testNegativeTimeoutReturnsNil() async {
        XCTAssertNil(JavaResolverBridge.resolveSynchronously(minimumMajor: 8,
                                                            mcVersion: nil,
                                                            timeout: -1))
    }

    /// 超时路径的耗时必须有上界：连续 5 次零超时调用应在秒级返回。
    /// 若超时失效，每次调用会等到真实扫描结束（秒~十秒级），启动会被拖死。
    func testRepeatedTimeoutCallsReturnPromptly() async {
        let start = Date()
        for _ in 0..<5 {
            XCTAssertNil(JavaResolverBridge.resolveSynchronously(minimumMajor: 0,
                                                                mcVersion: nil,
                                                                timeout: 0))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0,
                          "5 次 timeout=0 的调用超过 3 秒，说明超时保护未生效，调用方会被扫描阻塞")
    }

    // MARK: - 边界输入

    /// 负数与极值 `minimumMajor` 会被实现钳到 0，不得因取最小值崩溃
    func testOutOfRangeMinimumMajorIsTolerated() async {
        XCTAssertNil(JavaResolverBridge.resolveSynchronously(minimumMajor: -5, mcVersion: nil, timeout: 0))
        XCTAssertNil(JavaResolverBridge.resolveSynchronously(minimumMajor: Int.min, mcVersion: "", timeout: 0))
        XCTAssertNil(JavaResolverBridge.resolveSynchronously(minimumMajor: Int.max, mcVersion: nil, timeout: 0))
    }

    /// mcVersion 为 nil / 空串（仅用于日志追溯）不得影响调用结果
    func testMissingMinecraftVersionIsTolerated() async {
        XCTAssertNil(JavaResolverBridge.resolveSynchronously(minimumMajor: 17, mcVersion: nil, timeout: 0))
        XCTAssertNil(JavaResolverBridge.resolveSynchronously(minimumMajor: 17, mcVersion: "", timeout: 0))
        XCTAssertNil(JavaResolverBridge.resolveSynchronously(minimumMajor: 17,
                                                            mcVersion: "24w14a",
                                                            timeout: 0))
    }

    // MARK: - 并发与独立性

    /// 并发调用各持自己的信号量：不得死锁、不得互相污染返回值
    func testConcurrentCallsReturnNilWithoutDeadlock() async {
        DispatchQueue.concurrentPerform(iterations: 4) { index in
            XCTAssertNil(JavaResolverBridge.resolveSynchronously(minimumMajor: index * 4,
                                                                 mcVersion: nil,
                                                                 timeout: 0),
                         "第 \(index) 次并发调用应超时返回 nil")
        }
    }

    // MARK: - 非空结果形状

    /// 非 nil 结果必须是本机已存在的文件路径。
    /// 说明：本机无可用 Java（CI/沙箱）时走失败分支返回 nil，属预期；
    /// 该分支无法与「超时」区分（实现内部只打日志），故此处不额外断言。
    func testNonNilResultIsAnExistingLocalFile() async {
        let result = JavaResolverBridge.resolveSynchronously(minimumMajor: 0,
                                                            mcVersion: "1.20.1",
                                                            timeout: 2)
        if let url = result {
            XCTAssertTrue(url.isFileURL, "桥接只应回传本机文件路径，实际：\(url)")
            XCTAssertFalse(url.path.isEmpty, "回传路径不得为空")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "回传的 Java 可执行文件必须真实存在：\(url.path)")
        }
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. 「解析失败 → nil」的正向断言：`JavaResolverBridge` 内部直接构造
//     `DefaultJavaResolver()`，没有 resolver 注入点，无法构造
//     `JavaResolutionError.scanFailed` / `.noCompatibleVersion` 的确定性场景。
//     只能覆盖「超时 → nil」。若要补，需要把 resolver 提为可注入参数。
//  2. 超时后桥内 `Task.detached` 会继续跑完（实现未取消），可能仍有后续日志与
//     仓储写入。该副作用无句柄可观测，本文件不做断言。
