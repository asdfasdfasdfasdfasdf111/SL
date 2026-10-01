//
//  GameSessionStoreTests.swift
//  qwqTests
//
//  覆盖 `Features/Launch/GameSessionStore.swift` 的 `InMemoryGameSessionStore`。
//
//  **为什么值得测**：它是启动用例层里唯一「接口形状正确、可以脱离单例单测」的骨架
//  （不抓 `AppConfiguration` / `AppContext`，只依赖 `GameSessionRecord` 与会话 ID）。
//  文件头 T1/T2/T8/T9 说明 UI 将来要「退化为订阅 `GameSessionStore.observe(sessionID:)`」，
//  因此这三条语义现在就必须钉住，否则接线那天才发现：
//
//  1. **多订阅者**：同一会话可被多处 observe（UI 视图 + 日志窗口 + 自动化）。
//     基准取自同库既有实现 `Core/Download/Adapters/NetDownloaderDownloadEngine.swift`
//     ——它用数组承载多订阅者，并明确注释「同一任务可被多处 observe」。
//  2. **终态收口**：协议自身文档（`GameSessionStore.swift:34`）写明「流结束时自动清理订阅」，
//     所以终态必须 `finish()`，`for await` 必须退出，台账不得残留 continuation。
//  3. **回放**：晚订阅者要能拿到当前/终态，否则订阅前发生的状态全部丢失——
//     这正是 T8/T9 指出的缺口。`NetDownloaderDownloadEngine` 的 `lastState` 是同库基准。
//
//  ⚠️ 三条都用「限时收集」而非直接 `for await`：实现若坏在「不 finish」上，
//     用例应当**变红**而不是把整个测试宿主挂死（挂死会被误当成 §五 那条工具链 abort）。
//
//  反向验证：把 `update` 里的 `finish()` 摘掉 → `testTerminalFinishesStream` 红；
//            把 `continuations` 改回 `[UUID: Continuation]` → `testAllObserversReceiveUpdates` 红；
//            把 `lastStates` 回放摘掉 → `testLateObserverSeesCurrentState` 红。
//

import XCTest
@testable import qwq

/// 线程安全的事件记录器（用例侧）
private actor Recorder {
    private(set) var events: [LaunchState] = []
    private(set) var ended = false
    func append(_ state: LaunchState) { events.append(state) }
    func markEnded() { ended = true }
    func snapshot() -> (events: [LaunchState], ended: Bool) { (events, ended) }
}

final class GameSessionStoreTests: XCTestCase {

    private let sessionID = UUID(uuidString: "AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111")!

    /// `Process()` 只是建对象、**不启动**，用例内也不会 `terminate()`，
    /// 因此不拉起真实进程、不依赖外部可执行文件。
    private func makeRecord() -> GameSessionRecord {
        GameSessionRecord(sessionID: sessionID, process: ManagedProcess(process: Process()))
    }

    private let runningState = LaunchState.running
    private var finishedState: LaunchState {
        .finished(LaunchResult(exitCode: 0, sessionID: sessionID))
    }
    private var failedState: LaunchState {
        .failed(.unknown("用例构造的失败"))
    }

    /// 把流抽干到 Recorder；返回驱动任务，调用方限时后自行 cancel。
    private func drain(_ stream: AsyncStream<LaunchState>, into rec: Recorder) -> Task<Void, Never> {
        Task {
            for await state in stream { await rec.append(state) }
            await rec.markEnded()
        }
    }

    /// 给订阅建立留出时间（订阅本身是同步注册的，这里只是让驱动任务先跑起来）
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    // MARK: - 多订阅者

    /// 同一会话两个订阅者必须**都**收到全部事件。
    /// 原实现 `continuations[UUID: Continuation]` 会让第二次 observe 覆盖第一个，
    /// 先订阅者收不到任何事件且永不结束。
    func testAllObserversReceiveUpdates() async {
        let store = InMemoryGameSessionStore()
        await store.register(makeRecord())

        let first = Recorder()
        let second = Recorder()
        let t1 = drain(store.observe(sessionID: sessionID), into: first)
        let t2 = drain(store.observe(sessionID: sessionID), into: second)
        await settle()

        await store.update(runningState, for: sessionID)
        await store.update(finishedState, for: sessionID)
        try? await Task.sleep(for: .milliseconds(220))

        let (e1, end1) = await first.snapshot()
        let (e2, end2) = await second.snapshot()
        t1.cancel(); t2.cancel()

        XCTAssertEqual(e1, [runningState, finishedState], "先订阅者必须收到全部事件（原实现被后订阅者覆盖）")
        XCTAssertEqual(e2, [runningState, finishedState], "后订阅者也必须收到全部事件")
        XCTAssertTrue(end1, "先订阅者的流应在终态结束")
        XCTAssertTrue(end2, "后订阅者的流应在终态结束")
    }

    // MARK: - 终态收口

    /// 终态必须结束流（协议文档：「流结束时自动清理订阅」）。
    /// 原实现只 yield 不 finish → `for await` 永不退出。
    func testTerminalFinishesStream() async {
        let store = InMemoryGameSessionStore()
        await store.register(makeRecord())

        let rec = Recorder()
        let task = drain(store.observe(sessionID: sessionID), into: rec)
        await settle()

        await store.update(finishedState, for: sessionID)
        try? await Task.sleep(for: .milliseconds(220))

        let (events, ended) = await rec.snapshot()
        task.cancel()

        XCTAssertEqual(events, [finishedState])
        XCTAssertTrue(ended, "终态后流必须结束（原实现缺 finish，for await 永不退出）")
    }

    /// 失败终态与成功终态同等处理
    func testFailedStateAlsoFinishesStream() async {
        let store = InMemoryGameSessionStore()
        await store.register(makeRecord())

        let rec = Recorder()
        let task = drain(store.observe(sessionID: sessionID), into: rec)
        await settle()

        await store.update(failedState, for: sessionID)
        try? await Task.sleep(for: .milliseconds(220))

        let (events, ended) = await rec.snapshot()
        task.cancel()

        XCTAssertEqual(events, [failedState])
        XCTAssertTrue(ended, "失败终态同样必须结束流")
    }

    // MARK: - 回放

    /// 晚订阅者必须拿到当前状态，否则订阅前发生的状态全丢（T8/T9 同源缺口）。
    func testLateObserverSeesCurrentState() async {
        let store = InMemoryGameSessionStore()
        await store.register(makeRecord())

        await store.update(LaunchState.preparing, for: sessionID)
        await store.update(runningState, for: sessionID)

        let rec = Recorder()   // 状态发生之后才订阅
        let task = drain(store.observe(sessionID: sessionID), into: rec)
        await settle()

        let (events, _) = await rec.snapshot()
        task.cancel()

        XCTAssertEqual(events, [runningState], "晚订阅者应回放**最新**状态，而不是从空开始")
    }

    /// 终态之后再订阅：回放终态并立即结束，不得挂起
    func testLateObserverAfterTerminalGetsTerminalThenEnds() async {
        let store = InMemoryGameSessionStore()
        await store.register(makeRecord())
        await store.update(finishedState, for: sessionID)

        let rec = Recorder()
        let task = drain(store.observe(sessionID: sessionID), into: rec)
        try? await Task.sleep(for: .milliseconds(220))

        let (events, ended) = await rec.snapshot()
        task.cancel()

        XCTAssertEqual(events, [finishedState], "终态后订阅应回放终态")
        XCTAssertTrue(ended, "回放终态后应立即结束，不得挂起")
    }

    // MARK: - 终态后不再投递

    /// 终态之后不得再向旧订阅者投递（会话已注销）
    func testUpdatesAfterTerminalAreNotDelivered() async {
        let store = InMemoryGameSessionStore()
        await store.register(makeRecord())

        let rec = Recorder()
        let task = drain(store.observe(sessionID: sessionID), into: rec)
        await settle()

        await store.update(finishedState, for: sessionID)
        try? await Task.sleep(for: .milliseconds(160))
        await store.update(runningState, for: sessionID)   // 终态之后的杂散状态
        try? await Task.sleep(for: .milliseconds(160))

        let (events, _) = await rec.snapshot()
        task.cancel()

        XCTAssertEqual(events, [finishedState], "终态后的状态不得再投递给已结束的订阅者")
    }
}
