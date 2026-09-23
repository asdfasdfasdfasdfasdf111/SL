//
//  InstallTaskProgressTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Minecraft/Download/InstallTask.swift` 里两个同名 `getProgress()` 的边界口径：
//  单任务版 `InstallTask.getProgress()`（有 `guard totalFiles > 0`）与
//  任务组版 `InstallTasks.getProgress()`（本轮补上 `guard !tasks.isEmpty`）。
//
//  为什么必须有这一条：
//  任务组版是「各成员进度的算术平均」，分母是 `tasks.count`。**空集合时分子分母同为 0**，
//  `0.0 / 0.0 = NaN`。而 NaN 会穿透所有比较运算（`NaN < 0` 为假），所以视图里
//  `totalFiles < 0 ? "未知" : String(format: "%.1f %%", getProgress() * 100)`
//  这一层守卫**拦不住它** —— NaN 走 else 分支，被 `String(format:)` 原样打印成字面量
//  「nan %」，下载详情页的总进度就是这么显示出 NaN 的。
//  注意 `InstallTasks.totalFiles` 是**求和**得到的计算属性，空集合时是 0（不是单任务版语义里的 -1），
//  所以「用 totalFiles 判断」这条退路在任务组上根本不存在。
//
//  这里的用例都是**反向用例**：构造「本该被拦住」的条件，断言结果有限（不是 NaN）。
//

import XCTest
@testable import qwq

final class InstallTaskProgressTests: XCTestCase {

    // MARK: - InstallTasks.getProgress（本轮修复点）

    /// 空任务组：进度为 0，且**不得是 NaN**。
    /// 修复前这里是 0.0/0.0 = NaN → 界面显示字面量「nan %」。
    func testEmptyTaskGroupProgressIsZeroNotNaN() async {
        let group = InstallTasks.empty()

        XCTAssertEqual(group.tasks.count, 0)
        XCTAssertFalse(group.getProgress().isNaN, "空任务组的进度是 NaN —— 会在界面上打印成「nan %」")
        XCTAssertEqual(group.getProgress(), 0, accuracy: 1e-12)
    }

    /// 单成员任务组、但该成员尚未记账（`totalFiles = -1`）：
    /// 组级进度取的是成员进度的平均，而单任务版对 `totalFiles <= 0` 已返回 0，
    /// 所以平均值也必须是 0 —— 两个同名方法的边界口径必须一致。
    func testTaskGroupWithUnaccountedMemberIsZero() async {
        let fresh = InstallTask()                 // totalFiles / remainingFiles 默认 -1（未记账）
        XCTAssertEqual(fresh.totalFiles, -1)
        XCTAssertEqual(fresh.getProgress(), 0, accuracy: 1e-12)

        let group = InstallTasks.single(fresh)
        XCTAssertEqual(group.tasks.count, 1)
        XCTAssertFalse(group.getProgress().isNaN)
        XCTAssertEqual(group.getProgress(), 0, accuracy: 1e-12)
    }

    /// 分组进度口径：`totalFiles` 是成员求和，空集合时为 0（**不是** -1），
    /// 这正是视图里 `totalFiles < 0` 那层守卫形同虚设的原因。
    /// 这条用例把这个事实钉住：若将来有人把 totalFiles 改成「空时 -1」，
    /// 视图守卫会突然生效、语义也会变，测试必须一起改。
    func testEmptyTaskGroupTotalFilesIsZeroNotMinusOne() async {
        XCTAssertEqual(InstallTasks.empty().totalFiles, 0)
        XCTAssertEqual(InstallTasks.empty().remainingFiles, 0)
    }

    /// 多成员任务组：进度是各成员进度的算术平均（口径说明，防止将来被误改成加权）。
    func testTaskGroupProgressIsMeanOfMembers() async {
        let done = InstallTask()
        done.totalFiles = 10
        done.remainingFiles = 0                   // 单任务版 → 1.0

        let untouched = InstallTask()
        untouched.totalFiles = 10
        untouched.remainingFiles = 10             // 单任务版 → 0.0

        let group = InstallTasks(["minecraft": done, "fabric": untouched])
        XCTAssertEqual(group.tasks.count, 2)
        XCTAssertEqual(group.getProgress(), 0.5, accuracy: 1e-12)
        XCTAssertEqual(group.totalFiles, 20)
        XCTAssertEqual(group.remainingFiles, 10)
    }

    // MARK: - InstallTask.getProgress（既有守卫，作为对照基线）

    /// 未记账 / 空账本时返回 0；正常下载中落在 [0, 1]；
    /// `remainingFiles` 超出 `totalFiles` 时钳到 0（不得为负）。
    func testSingleTaskProgressBoundaries() async {
        let task = InstallTask()
        XCTAssertEqual(task.getProgress(), 0, accuracy: 1e-12)      // totalFiles = -1

        task.totalFiles = 0
        XCTAssertEqual(task.getProgress(), 0, accuracy: 1e-12)      // 显式 0，同样不得除零

        task.totalFiles = 4
        task.remainingFiles = 4
        XCTAssertEqual(task.getProgress(), 0, accuracy: 1e-12)

        task.remainingFiles = 1
        XCTAssertEqual(task.getProgress(), 0.75, accuracy: 1e-12)

        task.remainingFiles = 0
        XCTAssertEqual(task.getProgress(), 1.0, accuracy: 1e-12)

        // 剩余数越界（并发回调多减 / 少减）时钳制，不得越界成 > 1
        task.remainingFiles = -3
        XCTAssertEqual(task.getProgress(), 1.0, accuracy: 1e-12)

        task.remainingFiles = 99
        XCTAssertEqual(task.getProgress(), 0, accuracy: 1e-12)
    }
}
