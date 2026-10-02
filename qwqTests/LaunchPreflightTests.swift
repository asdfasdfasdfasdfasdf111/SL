//
//  LaunchPreflightTests.swift
//  qwqTests
//
//  覆盖 `Features/Launch/LaunchPreflight.swift` 的编排器 `DefaultLaunchPreflight`。
//
//  **为什么值得测**：`LaunchStateTests` 末尾的「未覆盖项说明」曾点名为缺口——
//  「DefaultLaunchPreflight：已有可注入的四个校验器，具备可测性，但本轮任务未要求覆盖；
//  建议补一份 LaunchPreflightTests，断言 skipResourceCheck 短路、四段调用顺序与
//  进度区间映射（0~0.5 / 0.5~1）」。本文件正是这份建议的执行。
//
//  钉住的四条性质：
//  1. `skipResourceCheck == true` ⇒ `prepare` 直接返回，四个校验器一个都不调；
//  2. 正常路径四段**按序**调用：client → libraries → assets → natives；
//  3. 进度区间映射：libraries 映射到 0~0.5、assets 映射到 0.5~1、末尾收 1.0；
//  4. 任一校验器抛错 ⇒ 抛给调用方、后续段不再执行（不吞错）。
//
//  全部用可注入的替身（记录调用顺序与收到的进度），不触碰真实文件系统。
//

import XCTest
@testable import qwq

final class LaunchPreflightTests: XCTestCase {

    // MARK: - 替身

    /// 记录「被调用的段名 + 收到的进度」的替身校验器。
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(String, Double?)] = []   // (段名, 局部进度，无进度回调时为 nil)

        func record(_ stage: String, _ progress: Double?) {
            lock.lock()
            defer { lock.unlock() }
            calls.append((stage, progress))
        }
    }

    /// 按注入的段名构造一个校验器替身。
    private func makeVerifier(_ name: String, _ recorder: Recorder,
                              error: Error? = nil) -> any ClientFileVerifier & LibraryFileVerifier & AssetFileVerifier {
        return StubVerifier(name: name, recorder: recorder, error: error)
    }

    private struct StubError: Error {}

    private final class StubVerifier: ClientFileVerifier, LibraryFileVerifier, AssetFileVerifier, @unchecked Sendable {
        let name: String
        let recorder: Recorder
        let error: Error?
        init(name: String, recorder: Recorder, error: Error?) {
            self.name = name
            self.recorder = recorder
            self.error = error
        }
        func verify(_ context: LaunchPreflightContext) async throws {
            if let error { throw error }
            recorder.record(name, nil)
        }
        func verify(_ context: LaunchPreflightContext, progress: LaunchProgressHandler?) async throws {
            if let error { throw error }
            recorder.record(name, nil)
            progress?(0.5)
        }
    }

    private final class StubNativeInstaller: NativeInstaller, @unchecked Sendable {
        let recorder: Recorder
        init(recorder: Recorder) { self.recorder = recorder }
        func install(_ context: LaunchPreflightContext) async throws {
            recorder.record("natives", nil)
        }
    }

    private func makeContext() -> LaunchPreflightContext {
        LaunchPreflightContext(
            version: "1.20.1",
            runningDirectory: URL(fileURLWithPath: "/tmp/preflight-run"),
            clientJAR: URL(fileURLWithPath: "/tmp/preflight-run/1.20.1.jar"),
            clientSHA1: nil,
            librariesRoot: URL(fileURLWithPath: "/tmp/preflight-libs"),
            libraries: [],
            assetsRoot: URL(fileURLWithPath: "/tmp/preflight-assets"),
            assetIndex: nil,
            assetObjects: [],
            nativesDirectory: URL(fileURLWithPath: "/tmp/preflight-run/natives"),
            nativeLibraryPaths: []
        )
    }

    /// 空请求：仅带 skipResourceCheck 标记的裸请求。
    private func makeRequest(skip: Bool) -> LaunchRequest {
        LaunchRequest(
            version: "1.20.1",
            gameRoot: URL(fileURLWithPath: "/tmp/preflight-game"),
            offlineUsername: "preflight-test",
            skipResourceCheck: skip
        )
    }

    // MARK: - 用例

    /// skipResourceCheck 短路：不解析 context、四个校验器全不调。
    func testSkipResourceCheckShortCircuits() async throws {
        let recorder = Recorder()
        let preflight = DefaultLaunchPreflight(
            contextResolver: { _ in throw StubError() },   // 若被调必抛错，用于证明短路
            clientVerifier: makeVerifier("client", recorder),
            libraryVerifier: makeVerifier("libraries", recorder),
            assetVerifier: makeVerifier("assets", recorder),
            nativeInstaller: StubNativeInstaller(recorder: recorder)
        )
        try await preflight.prepare(makeRequest(skip: true))
        XCTAssertTrue(recorder.calls.isEmpty, "skipResourceCheck=true 时任何校验器都不该被调")
    }

    /// 正常路径四段按序调用：client → libraries → assets → natives。
    func testVerifiersRunInOrder() async throws {
        let recorder = Recorder()
        let preflight = DefaultLaunchPreflight(
            contextResolver: { _ in self.makeContext() },
            clientVerifier: makeVerifier("client", recorder),
            libraryVerifier: makeVerifier("libraries", recorder),
            assetVerifier: makeVerifier("assets", recorder),
            nativeInstaller: StubNativeInstaller(recorder: recorder)
        )
        try await preflight.prepare(makeRequest(skip: false))
        XCTAssertEqual(recorder.calls.map(\.0), ["client", "libraries", "assets", "natives"],
                       "四段必须按 client → libraries → assets → natives 顺序调用")
    }

    /// 进度区间映射：libraries 局部进度 ×0.5、assets 0.5+p×0.5、末尾收 1.0。
    /// 进度回调是 `@Sendable` 闭包，不能直接捕获并 mutate 局部 `var`（Swift 6 错误），
    /// 故借 Recorder（自持锁）记录，断言前按时间序取回。
    func testProgressIntervalMapping() async throws {
        let recorder = Recorder()
        let preflight = DefaultLaunchPreflight(
            contextResolver: { _ in self.makeContext() },
            clientVerifier: makeVerifier("client", recorder),
            libraryVerifier: makeVerifier("libraries", recorder),
            assetVerifier: makeVerifier("assets", recorder),
            nativeInstaller: StubNativeInstaller(recorder: recorder),
            progress: { recorder.record("progress", $0) }
        )
        try await preflight.prepare(makeRequest(skip: false))
        let observed = recorder.calls.compactMap { $0.1 }
        // 期望：libraries 报 0.25（0.5×0.5）、assets 报 0.75（0.5+0.5×0.5）、结尾 1.0
        XCTAssertEqual(observed, [0.25, 0.75, 1.0],
                       "进度映射应为 libraries→0~0.5、assets→0.5~1、末尾→1.0")
    }

    /// 任一校验器抛错 ⇒ 抛给调用方，且后续段不再执行。
    func testErrorPropagatesAndStopsChain() async throws {
        let recorder = Recorder()
        let preflight = DefaultLaunchPreflight(
            contextResolver: { _ in self.makeContext() },
            clientVerifier: makeVerifier("client", recorder),
            libraryVerifier: makeVerifier("libraries", recorder, error: StubError()),
            assetVerifier: makeVerifier("assets", recorder),
            nativeInstaller: StubNativeInstaller(recorder: recorder)
        )
        do {
            try await preflight.prepare(makeRequest(skip: false))
            XCTFail("libraryVerifier 抛错时 prepare 必须抛")
        } catch is StubError {
            // 预期路径
        } catch {
            XCTFail("应原样抛 StubError，实际抛了 \(error)")
        }
        XCTAssertEqual(recorder.calls.map(\.0), ["client"],
                       "libraries 抛错时它自己的 record 不执行，且 assets/natives 不得执行")
    }
}
