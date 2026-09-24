//
//  LaunchCancellationTests.swift
//  qwqTests
//
//  「准备阶段取消」的反向用例（缺陷：准备期点取消、游戏几十秒后仍会自己弹出来）。
//
//  MARK: - 为什么单独成一套用例
//
//  被修的那条路径只在真机点按钮时才经过：从点「启动」到进程 `run()` 之间**还没有 launcher**，
//  所以 `GameSession.launcher.terminate()` 这条现成的取消手段在那里根本取不到对象。
//  它既没法用 UI 自动化点（AI 会话里点不到按钮），也没法靠桩测出「对」。
//
//  但这条链路里最关键的那条断言 —— 「令牌已置位 ⇒ 必然以 `.cancelled` 收口，
//  且**绝不**走到「launcher 就绪」/ 上报成功 / 产生下载进度」—— 只依赖令牌本身。
//  因此可以在**没有游戏目录、没有 Java、没有网络**的环境里确定性验证：
//  这正是本文件存在的理由，也是把取消判定点 ① 放在 `slLaunchInternal` 函数入口的收益
//  （放在入口之后就需要真实实例才能到达，用例就得造一整套目录夹具）。
//
//  MARK: - 与正向用例的分工
//
//  正向链路（真拉起游戏、验 natives/classpath/窗口）见 `RealLaunchIntegrationTests`，
//  默认跳过。本文件是它的**反向对照**：正向证「该启动的能启动」，反向证「该拦住的真被拦住」。
//  按项目既有纪律，只有正向结果不足以说明问题，两边都要有。
//
//  MARK: - 全部用例都是 async（不是风格选择）
//
//  工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，Xcode 26.2 上**同步用例**
//  一旦创建并释放任何主 actor 隔离的类实例，测试宿主就 100% abort
//  （`malloc: pointer being freed was not allocated`，XCTest 无限重启宿主、套件再也前进不了）。
//  因此本文件所有用例一律 `async`，等待用 `await fulfillment(of:)` 而不是 `wait(for:)`。
//  详见 `.workbuddy/memory/MEMORY.md`「测试用例必须写成 async」。
//

import XCTest
import os
@testable import qwq

final class LaunchCancellationTests: XCTestCase {

    /// 反向用例：已置位的令牌必须让启动在**函数入口**就收手。
    ///
    /// 传入的版本名与 gameDir 都是必然不存在的：
    ///  - 没有入口判定时，本用例会以「无法创建实例」失败（而不是「已取消」）——
    ///    这正是此处要钉住的行为差异；
    ///  - `onLauncherReady` / `progressHandler` / `phaseHandler` / `launchSuccess` 都挂上
    ///    `XCTFail`：它们的任何一次触发都意味着「取消后仍继续准备」，正是原缺陷的表现。
    func testPreCancelledTokenAbortsBeforeAnyPreparation() async {
        let token = LaunchCancellationToken()
        token.cancel()

        let done = expectation(description: "completion 回调")
        let launcherReadyFired = AtomicFlag()
        let captured = OSAllocatedUnfairLock<Result<Int32, Error>?>(initialState: nil)

        slLaunch(
            version: "取消用例-必然不存在的版本",
            username: "Player",
            gameDir: NSTemporaryDirectory() + "/sl-cancel-test-必然不存在",
            progressHandler: { _ in
                XCTFail("已取消的启动不应产生下载进度")
            },
            phaseHandler: { phase in
                XCTFail("已取消的启动不应进入相位 \(phase)")
            },
            logHandler: { _ in },
            launchSuccess: {
                XCTFail("已取消的启动不应上报成功")
            },
            onLauncherReady: { _ in
                launcherReadyFired.set()
            },
            cancellation: token,
            completion: { _, result in
                captured.withLock { $0 = result }
                done.fulfill()
            }
        )

        await fulfillment(of: [done], timeout: 30)

        XCTAssertFalse(
            launcherReadyFired.isSet,
            "已取消的启动绝不能走到「launcher 就绪」——走到这里说明进程即将被拉起"
        )

        let result = captured.withLock { $0 }
        guard let result else {
            return XCTFail("未收到 completion 回调")
        }
        switch result {
        case .failure(let error):
            XCTAssertEqual(
                error as? LaunchError,
                .cancelled,
                "已取消的启动失败原因必须是 .cancelled（UI 据此判定「不弹错误框」），实际是 \(error)"
            )
        case .success(let exitCode):
            XCTFail("已取消的启动不应返回成功，却拿到了退出码 \(exitCode)")
        }
    }

    /// 对照用例：**未置位**的令牌必须放行，入口判定不得误伤正常启动。
    ///
    /// 只断言「失败原因不是 `.cancelled`」：本用例没有游戏目录，放行之后必然在
    /// 「实例无法创建」处失败，这是预期内的。它证明的是入口判定**没有把正常路径一起拦掉**。
    func testUncancelledTokenPassesEntryGate() async {
        let token = LaunchCancellationToken()
        XCTAssertFalse(token.isCancelled, "新建令牌的初值必须是未取消")

        let done = expectation(description: "completion 回调")
        let captured = OSAllocatedUnfairLock<Result<Int32, Error>?>(initialState: nil)

        slLaunch(
            version: "取消用例-必然不存在的版本",
            username: "Player",
            gameDir: NSTemporaryDirectory() + "/sl-cancel-test-必然不存在",
            progressHandler: { _ in },
            phaseHandler: { _ in },
            logHandler: { _ in },
            launchSuccess: {},
            onLauncherReady: { _ in
                XCTFail("不存在的版本不应走到 launcher 就绪")
            },
            cancellation: token,
            completion: { _, result in
                captured.withLock { $0 = result }
                done.fulfill()
            }
        )

        await fulfillment(of: [done], timeout: 30)

        guard let result = captured.withLock({ $0 }), case .failure(let error) = result else {
            return XCTFail("未收到失败回调（不存在的版本必然失败）")
        }
        XCTAssertNotEqual(
            error as? LaunchError,
            .cancelled,
            "未取消的启动被入口判定误拦了"
        )
    }

    /// 适配器通道：`launch(_:cancellation:)` 必须把取消原样透传（不得退化成 `.unknown`）。
    ///
    /// 这一条钉的是 `mapFailure` 的口径：取消若落进「按文案前缀匹配」的兜底分支，
    /// 会变成 `.unknown("启动已取消")`，而 UI 侧判「不弹错误框」用的仍是令牌本身，
    /// 两条口径不一致迟早出问题，所以在这里固定住。
    func testServicePropagatesCancellationUnchanged() async {
        let token = LaunchCancellationToken()
        token.cancel()

        let service = MinecraftInstanceLaunchService()
        let request = LaunchRequest(
            version: "取消用例-必然不存在的版本",
            gameRoot: URL(fileURLWithPath: NSTemporaryDirectory() + "/sl-cancel-test-必然不存在"),
            offlineUsername: "Player"
        )

        do {
            _ = try await service.launch(request, cancellation: token)
            XCTFail("已取消的启动不应返回 LaunchResult")
        } catch let error as LaunchError {
            XCTAssertEqual(error, .cancelled, "取消必须原样透传，实际是 \(error)")
        } catch {
            XCTFail("抛出了非 LaunchError：\(error)")
        }
    }

    /// 令牌自身的语义：可重复取消、状态单向。
    /// 重复取消必须无副作用 —— 电源按钮在「无启动进行中」时也会调一次 `cancel()`。
    func testTokenCancelIsIdempotentAndMonotonic() async {
        let token = LaunchCancellationToken()
        XCTAssertFalse(token.isCancelled)

        token.cancel()
        XCTAssertTrue(token.isCancelled)
        token.cancel()
        XCTAssertTrue(token.isCancelled, "重复取消不应把状态翻回去")
    }
}

/// 跨线程置位/读取一次布尔标志（取消回调发生在启动准备线程，断言发生在测试线程）。
private nonisolated final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
