//
//  NoticeCenterTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//  1. 投递：`post(_:)` 是 nonisolated 的，从任意线程调用都必须最终落到 MainActor 的
//     `current` 与 `history` 上（这是 `hint()` 等非隔离调用点能看到提示的前提）；
//  2. 历史上限：history 最多 20 条，超出时**从头部丢弃最早**的条目，
//     顺序不得错乱（超限后「最近 20 条」必须仍是这 20 条）；
//  3. 级别映射与文案：`PopupType` / `HintType` → `NoticeLevel` 的映射、默认标题、
//     由 `PopupModel` 转换时的按钮与「导出错误报告」判定，全部是用户可见文案，改一处即回归；
//  4. 应答语义：无 UI 承载者（overlay 未挂载）时 `presentAndWait` 必须立即按提示声明的
//     隐式按钮返回且不留 current，绝不阻塞调用方；有承载者时真正挂起，`choose` / `dismiss`
//     分别按点选下标与该提示的隐式按钮应答。隐式按钮由 `Notice.fallbackChoiceIndex` 指定
//     （默认 0，即历史行为），三条隐式路径——无承载者 / 点 × / 兜底超时——都走同一个下标；
//  5. 非当前提示的点选不得关掉当前提示。
//
//  注意：`NoticeCenter` 只有私有 init，测试只能使用 `shared` 单例，
//  因此每个用例开头都复位承载者状态，避免用例间串扰。
//
//  被测：UI/Notices/NoticeCenter.swift
//

import XCTest
@testable import qwq

@MainActor
final class NoticeCenterTests: XCTestCase {

    private let center = NoticeCenter.shared

    override func setUp() {
        super.setUp()
        center.setPresenter(false)
        center.dismiss()
    }

    override func tearDown() {
        center.setPresenter(false)
        center.dismiss()
        super.tearDown()
    }

    // MARK: - 异步等待辅助

    /// 等待某条提示成为 history 末条（即已被投递）
    private func waitUntilDelivered(_ id: UUID,
                                    timeout: TimeInterval = 2,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) async {
        await waitUntil(timeout: timeout, file: file, line: line) {
            self.center.history.last?.id == id
        }
    }

    /// 等待某条提示成为 current
    private func waitUntilCurrent(_ id: UUID,
                                  timeout: TimeInterval = 2,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) async {
        await waitUntil(timeout: timeout, file: file, line: line) {
            self.center.current?.id == id
        }
    }

    private func waitUntil(timeout: TimeInterval,
                           file: StaticString,
                           line: UInt,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("等待条件超时（\(timeout)s）", file: file, line: line)
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)
        }
    }

    private func makeNotice(level: NoticeLevel = .info,
                            title: String = "提示",
                            message: String = "正文") -> Notice {
        Notice(level: level, title: title, message: message)
    }

    // MARK: - 投递

    /// post 之后 current 与 history 同步更新，字段原样保留
    func testPostDeliversNoticeToCurrentAndHistory() async {
        let notice = makeNotice(level: .warning, title: "注意", message: "磁盘空间不足")

        center.post(notice)
        await waitUntilDelivered(notice.id)

        XCTAssertEqual(center.current?.id, notice.id)
        XCTAssertEqual(center.current?.level, NoticeLevel.warning)
        XCTAssertEqual(center.current?.title, "注意")
        XCTAssertEqual(center.current?.message, "磁盘空间不足")
        XCTAssertEqual(center.history.last?.id, notice.id)
    }

    /// 从后台线程投递同样必须送达（nonisolated + 内部 hop 到 MainActor）
    func testPostFromBackgroundThreadIsDelivered() async {
        let notice = makeNotice(message: "来自后台线程")
        let center = self.center

        DispatchQueue.global(qos: .userInitiated).async {
            center.post(notice)
        }

        await waitUntilDelivered(notice.id)
        XCTAssertEqual(center.current?.id, notice.id)
    }

    /// 主线程上投递必须**同步**生效，不得被推迟到下一轮 runloop。
    ///
    /// 否则「先 `post` 后 `presentAndWait`」会出现投递顺序倒置 —— 后发的 `presentAndWait`
    /// （其内部 `deliver` 是同步的）反而先落到 `current` 上，先 post 的那条被当成"被顶替"
    /// 立即按默认按钮应答，用户看不到它。
    ///
    /// 反证：摘掉 `post` 里 `Thread.isMainThread` 的同步分支（退回裸 `Task { @MainActor in }`）后，
    /// 本用例会在断言处变红 —— 因为 `Task` 要到下一轮 runloop 才执行。
    func testPostOnMainThreadIsSynchronous() async {
        let notice = makeNotice(message: "同步投递")

        center.post(notice)

        // 关键：不做任何等待、不 await，紧接着断言 —— 只有同步投递才可能成立
        XCTAssertEqual(center.current?.id, notice.id, "主线程投递被推迟到了下一轮 runloop")
        XCTAssertEqual(center.history.last?.id, notice.id, "history 未同步更新")
    }

    /// 连续投递：每次投递都成为新的 current
    func testLaterPostReplacesCurrent() async {
        let first = makeNotice(message: "第一条")
        let second = makeNotice(level: .error, message: "第二条")

        center.post(first)
        await waitUntilDelivered(first.id)
        center.post(second)
        await waitUntilDelivered(second.id)

        XCTAssertEqual(center.current?.id, second.id)
        XCTAssertEqual(center.history.suffix(2).map(\.id), [first.id, second.id],
                       "历史必须按投递顺序追加")
    }

    // MARK: - 历史上限

    /// history 上限为 20；连续投递 25 条后只保留最近 20 条，最早的 5 条被挤出
    func testHistoryIsCappedAtLimitAndDropsOldestEntries() async {
        XCTAssertEqual(NoticeCenter.historyLimit, 20, "历史上限被改动时本用例必须同步复核")

        let batch = (0..<25).map { index in makeNotice(message: "第 \(index) 条") }
        for notice in batch {
            center.post(notice)
            await waitUntilDelivered(notice.id)
        }

        XCTAssertEqual(center.history.count, NoticeCenter.historyLimit)
        XCTAssertEqual(Array(center.history.suffix(20)).map(\.id), Array(batch.suffix(20).map(\.id)),
                       "超限后保留的必须是最近 20 条且顺序不变（应从头部丢弃）")

        let dropped = Set(batch.prefix(5).map(\.id))
        XCTAssertFalse(center.history.contains { dropped.contains($0.id) },
                       "最早的 5 条应已被挤出历史")
        XCTAssertEqual(center.current?.id, batch.last?.id)
    }

    // MARK: - 交互

    /// dismiss 只关闭当前提示，不清空历史（历史用于事后排查）
    func testDismissClearsCurrentButKeepsHistory() async {
        let notice = makeNotice()
        center.post(notice)
        await waitUntilDelivered(notice.id)
        XCTAssertNotNil(center.current)

        center.dismiss()

        XCTAssertNil(center.current)
        XCTAssertTrue(center.history.contains { $0.id == notice.id },
                      "关闭提示不得删除历史记录")
    }

    /// current 为空时 dismiss 是 no-op
    func testDismissWithoutCurrentIsNoOp() async {
        XCTAssertNil(center.current)
        center.dismiss()
        XCTAssertNil(center.current)
        center.dismiss()
        XCTAssertNil(center.current)
    }

    /// 非当前提示的点选不得关掉当前提示
    func testChooseIgnoresNoticeThatIsNotCurrent() async {
        let shown = makeNotice(message: "当前提示")
        center.post(shown)
        await waitUntilDelivered(shown.id)

        let other = makeNotice(level: .error, message: "另一条提示")
        center.choose(other, index: 1)

        XCTAssertEqual(center.current?.id, shown.id,
                       "归属校验失败会导致迟到回调误关当前提示")
    }

    /// 点选当前提示会关闭它
    func testChooseClosesMatchingCurrent() async {
        let notice = makeNotice()
        center.post(notice)
        await waitUntilDelivered(notice.id)

        center.choose(notice, index: 0)

        XCTAssertNil(center.current)
    }

    // MARK: - presentAndWait：无承载者（overlay 未挂载）

    /// 无承载者时必须立即返回默认下标 0，且不留 current（语义与旧桩实现一致）
    func testPresentAndWaitWithoutPresenterReturnsDefaultIndex() async {
        center.setPresenter(false)
        let notice = makeNotice(level: .error, message: "无 UI 承载者")

        let index = await center.presentAndWait(notice)

        XCTAssertEqual(index, 0, "overlay 未挂载时必须按默认按钮返回，不得阻塞调用方")
        XCTAssertNil(center.current, "无承载者路径不应留下待展示提示")
        XCTAssertEqual(center.history.last?.id, notice.id, "无承载者路径仍需记入历史便于排查")
    }

    // MARK: - presentAndWait：有承载者

    /// 有承载者时真正挂起，返回被点选按钮的下标
    func testPresentAndWaitWithPresenterReturnsChosenButtonIndex() async {
        center.setPresenter(true)
        let notice = Notice(level: .warning,
                            title: "注意",
                            message: "请选择",
                            buttons: [NoticeButton(label: "取消"),
                                      NoticeButton(label: "继续", style: .accent)])

        async let pending = center.presentAndWait(notice)
        await waitUntilCurrent(notice.id)

        center.choose(notice, index: 1)
        let chosen = await pending

        XCTAssertEqual(chosen, 1)
        XCTAssertEqual(notice.buttons[chosen].label, "继续")
        XCTAssertNil(center.current, "点选后应关闭当前提示")
    }

    /// 用户点右上角 × 关闭时按默认按钮（下标 0）应答，调用方不得永久挂起
    func testPresentAndWaitReturnsDefaultIndexWhenDismissed() async {
        center.setPresenter(true)
        let notice = Notice(level: .info,
                            title: "提示",
                            message: "正文",
                            buttons: [NoticeButton(label: "确定"), NoticeButton(label: "取消")])

        async let pending = center.presentAndWait(notice)
        await waitUntilCurrent(notice.id)

        center.dismiss()
        let chosen = await pending

        XCTAssertEqual(chosen, 0)
        XCTAssertNil(center.current)
    }

    /// 有承载者的路径同样要记入历史（历史与展示互不替代）
    func testPresentAndWaitWithPresenterRecordsHistory() async {
        center.setPresenter(true)
        let notice = makeNotice()

        async let pending = center.presentAndWait(notice)
        await waitUntilCurrent(notice.id)

        XCTAssertTrue(center.hasPresenter)
        XCTAssertTrue(center.history.contains { $0.id == notice.id },
                      "presentAndWait 展示的提示也必须进入历史，否则事后无法排查")

        center.dismiss()
        let chosen = await pending
        XCTAssertEqual(chosen, 0)
    }

    /// hasPresenter 跟随承载者挂载/卸载
    func testHasPresenterFollowsRegistration() async {
        center.setPresenter(true)
        XCTAssertTrue(center.hasPresenter)
        center.setPresenter(false)
        XCTAssertFalse(center.hasPresenter)
    }

    // MARK: - 级别映射与文案

    /// PopupType → NoticeLevel：三种类型一一对应，无 success 分支
    func testNoticeLevelFromPopupType() async {
        XCTAssertEqual(NoticeLevel(PopupType.info), .info)
        XCTAssertEqual(NoticeLevel(PopupType.warning), .warning)
        XCTAssertEqual(NoticeLevel(PopupType.error), .error)
    }

    /// HintType → NoticeLevel：finish 是成功提示（不是 info），critical 是错误
    func testNoticeLevelFromHintType() async {
        XCTAssertEqual(NoticeLevel(HintType.info), .info)
        XCTAssertEqual(NoticeLevel(HintType.finish), .success)
        XCTAssertEqual(NoticeLevel(HintType.critical), .error)
    }

    /// 四个级别都有非空默认标题（hint 只有正文，标题由此补全）
    func testDefaultTitlesForEachLevel() async {
        XCTAssertEqual(NoticeLevel.info.defaultTitle, "提示")
        XCTAssertEqual(NoticeLevel.success.defaultTitle, "完成")
        XCTAssertEqual(NoticeLevel.warning.defaultTitle, "注意")
        XCTAssertEqual(NoticeLevel.error.defaultTitle, "错误")
    }

    /// 默认按钮：单个「确定」，样式 normal；默认不提供错误报告导出
    func testDefaultNoticeShape() async {
        let notice = Notice(level: .info, title: "提示", message: "正文")

        XCTAssertEqual(notice.buttons.count, 1)
        XCTAssertEqual(notice.buttons[0].label, "确定")
        XCTAssertEqual(notice.buttons[0].style, .normal)
        XCTAssertFalse(notice.allowsReportExport)
        XCTAssertEqual(NoticeButton.ok.label, "确定")
        XCTAssertEqual(NoticeButton.ok.style, .normal)
    }

    /// 由 PopupModel 转换：级别/标题/正文/按钮顺序与样式逐项保留
    func testNoticeFromPopupModelMapsFieldsAndButtons() async {
        let model = PopupModel(.error,
                               "启动失败",
                               "无法定位 Java 运行时",
                               [PopupButton(label: "确定"),
                                PopupButton(label: "导出错误报告", style: .accent)],
                               allowsReportExport: true)

        let notice = Notice(model)

        XCTAssertEqual(notice.level, .error)
        XCTAssertEqual(notice.title, "启动失败")
        XCTAssertEqual(notice.message, "无法定位 Java 运行时")
        XCTAssertEqual(notice.buttons.map(\.label), ["确定", "导出错误报告"])
        XCTAssertEqual(notice.buttons.map(\.style), [.normal, .accent])
        XCTAssertTrue(notice.allowsReportExport)
    }

    /// 不含「导出」按钮时不得出现导出入口（显式字段默认 false）
    func testNoticeFromPopupModelWithoutExportButtonDisablesReportExport() async {
        let model = PopupModel(.warning, "注意", "磁盘空间不足", [PopupButton(label: "去清理")])
        let notice = Notice(model)

        XCTAssertEqual(notice.level, .warning)
        XCTAssertFalse(notice.allowsReportExport)
    }

    /// 导出判定走显式字段（2026-10-02 起替代「按钮文案包含『导出』」的字符串推导）：
    /// 按钮 label 与 allowsReportExport 完全解耦——含「导出」字样但未声明 true 则不开启，
    /// 未含字样但声明 true 则开启（崩溃弹窗「导出错误报告」接线即属后者）。
    func testAllowsReportExportComesFromExplicitField() async {
        // 按钮含「导出」字样但未声明 → 不开启（不再按文案反猜）
        let labelOnly = Notice(PopupModel(.error, "错误", "正文",
                                          [PopupButton(label: "导出日志", style: .danger)]))
        XCTAssertFalse(labelOnly.allowsReportExport)

        // 显式声明 true（按钮是普通「确定」）→ 开启
        let explicit = Notice(PopupModel(.error, "错误", "正文",
                                         [PopupButton(label: "确定")],
                                         allowsReportExport: true))
        XCTAssertTrue(explicit.allowsReportExport)

        // 显式声明 false → 不开启
        let explicitOff = Notice(PopupModel(.error, "错误", "正文",
                                            [PopupButton(label: "导出日志", style: .danger)],
                                            allowsReportExport: false))
        XCTAssertFalse(explicitOff.allowsReportExport)
    }

    // MARK: - Notice 相等语义

    /// Notice 的相等按 id 判定（内容相同但 id 不同即不相等）
    func testNoticeEqualityIsIdentityBased() async {
        let id = UUID()
        let lhs = Notice(id: id, level: .info, title: "标题", message: "正文")
        let rhs = Notice(id: id, level: .error, title: "别的标题", message: "别的正文")
        XCTAssertEqual(lhs, rhs)

        let other = Notice(level: .info, title: "标题", message: "正文")
        XCTAssertNotEqual(lhs, other)
    }

    // MARK: - 300s 兜底超时（2026-10-03 补覆盖）

    /// 兜底超时到期后必须按默认按钮（下标 0）应答，调用方不得永久挂起。
    ///
    /// 注入短超时（`responseTimeoutNanos` 已放宽为 internal static var，默认仍 300s）：
    /// 0.05s 到期后 `presentAndWait` 应返回 0，且当前提示被关闭。
    func testPresentAndWaitTimesOutToDefaultIndex() async {
        let original = NoticeCenter.responseTimeoutNanos
        NoticeCenter.responseTimeoutNanos = 50_000_000 // 0.05s
        defer { NoticeCenter.responseTimeoutNanos = original }

        center.setPresenter(true)
        let notice = Notice(level: .warning,
                            title: "注意",
                            message: "无人应答",
                            buttons: [NoticeButton(label: "取消"),
                                      NoticeButton(label: "继续", style: .accent)])

        async let pending = center.presentAndWait(notice)
        await waitUntilCurrent(notice.id)

        let chosen = await pending

        XCTAssertEqual(chosen, 0, "超时后必须按默认按钮（下标 0）应答，调用方不得永久挂起")
        XCTAssertNil(center.current, "超时应答后应关闭当前提示")
    }

    // MARK: - 隐式应答：由提示自己指定下标（fallbackChoiceIndex）

    /// 无承载者时必须按**该提示自己声明的**隐式按钮应答，而不是硬编码的 0。
    /// 反例（真实存在）：更新提示的首按钮是「立即更新」，硬编码 0 会把
    /// 「用户没看见弹窗」变成「自动开始下载并替换 App」。
    func testWithoutPresenterUsesNoticesOwnFallbackIndex() async {
        center.setPresenter(false)
        let notice = Notice(level: .warning,
                            title: "有新版本",
                            message: "请选择",
                            buttons: [NoticeButton(label: "立即更新", style: .accent),
                                      NoticeButton(label: "下次再说")],
                            fallbackChoiceIndex: 1)

        let index = await center.presentAndWait(notice)

        XCTAssertEqual(index, 1, "无承载者路径必须按提示声明的隐式按钮应答")
    }

    /// 点右上角 × 同样按该提示声明的隐式按钮应答 —— 「关掉弹窗」不得等于「执行首个按钮」。
    func testDismissUsesNoticesOwnFallbackIndex() async {
        center.setPresenter(true)
        let notice = Notice(level: .warning,
                            title: "有新版本",
                            message: "请选择",
                            buttons: [NoticeButton(label: "立即更新", style: .accent),
                                      NoticeButton(label: "下次再说")],
                            fallbackChoiceIndex: 1)

        async let pending = center.presentAndWait(notice)
        await waitUntilCurrent(notice.id)
        center.dismiss()

        let chosen = await pending
        XCTAssertEqual(chosen, 1, "点 × 必须按隐式按钮应答，不得触发「立即更新」")
    }

    /// 兜底超时同样按该提示声明的隐式按钮应答。
    func testTimeoutUsesNoticesOwnFallbackIndex() async {
        let original = NoticeCenter.responseTimeoutNanos
        NoticeCenter.responseTimeoutNanos = 50_000_000 // 0.05s
        defer { NoticeCenter.responseTimeoutNanos = original }

        center.setPresenter(true)
        let notice = Notice(level: .warning,
                            title: "有新版本",
                            message: "无人应答",
                            buttons: [NoticeButton(label: "立即更新", style: .accent),
                                      NoticeButton(label: "下次再说")],
                            fallbackChoiceIndex: 1)

        async let pending = center.presentAndWait(notice)
        await waitUntilCurrent(notice.id)

        let chosen = await pending
        XCTAssertEqual(chosen, 1, "超时后必须按提示声明的隐式按钮应答")
    }

    // MARK: - 就地更新（进度条类提示）

    /// 越界/无按钮时的夹取：隐式应答下标必须始终落在 `buttons` 合法范围内，
    /// 否则 `choose(index:)` 的语义没有定义（调用方会读到错误分支）。
    func testFallbackIndexIsClampedIntoButtonRange() async {
        let two = Notice(level: .info, title: "t", message: "m",
                         buttons: [NoticeButton(label: "a"), NoticeButton(label: "b")],
                         fallbackChoiceIndex: 99)
        XCTAssertEqual(two.safeFallbackChoiceIndex, 1, "越界必须夹到最后一个按钮")

        let negative = Notice(level: .info, title: "t", message: "m",
                              buttons: [NoticeButton(label: "a")],
                              fallbackChoiceIndex: -5)
        XCTAssertEqual(negative.safeFallbackChoiceIndex, 0, "负数必须夹到 0")

        let empty = Notice(level: .info, title: "t", message: "m", buttons: [])
        XCTAssertEqual(empty.safeFallbackChoiceIndex, 0, "没有按钮时固定为 0，不得越界读取")
    }

    /// `update` 必须**原地**替换同一 id 的提示：内容更新、id 不变。
    /// id 不变是硬要求 —— overlay 用 `.id(notice.id)` 作卡片身份，id 一变卡片就重建、
    /// 出现动画重放，用户看到的就是「进度条每刷新一次抽搐一下」。
    func testUpdateReplacesContentInPlaceKeepingIdentity() async {
        center.setPresenter(true)
        let id = UUID()
        let first = Notice(id: id, level: .warning, title: "正在下载更新 v9", message: "0%",
                           buttons: [], progress: 0)
        center.post(first)
        await waitUntilCurrent(id)

        let second = Notice(id: id, level: .warning, title: "正在下载更新 v9", message: "45%",
                            buttons: [], progress: 0.45)
        center.update(second)

        XCTAssertEqual(center.current?.id, id, "就地更新必须保持同一个 id（否则卡片会重建）")
        XCTAssertEqual(center.current?.message, "45%", "内容必须换成新值")
        XCTAssertEqual(center.current?.progress, 0.45)
    }

    /// `update` 不得把**已经不在展示**的提示拉回屏幕（用户已点 × 或已被顶替）。
    func testUpdateIgnoresNoticeThatIsNotCurrent() async {
        center.setPresenter(true)
        let other = Notice(level: .info, title: "别的提示", message: "占位")
        center.post(other)
        await waitUntilCurrent(other.id)

        let stale = Notice(id: UUID(), level: .warning, title: "下载", message: "50%", buttons: [], progress: 0.5)
        center.update(stale)

        XCTAssertEqual(center.current?.id, other.id, "不在展示中的提示不得被 update 拉回来")
    }

    /// `update` 同步替换 history 里同 id 的那条：事后排查看到的是最终内容而不是中间态。
    func testUpdateRewritesHistoryEntry() async {
        center.setPresenter(true)
        let id = UUID()
        center.post(Notice(id: id, level: .warning, title: "下载", message: "10%", buttons: [], progress: 0.1))
        await waitUntilCurrent(id)
        center.update(Notice(id: id, level: .warning, title: "下载", message: "100%", buttons: [], progress: 1.0))

        let entry = center.history.last(where: { $0.id == id })
        XCTAssertEqual(entry?.message, "100%", "history 里同 id 的条目必须被替换成最新内容")
        XCTAssertEqual(center.history.filter { $0.id == id }.count, 1, "不得为同一 id 堆积多条历史")
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. `presentAndWait` 的 300s 兜底超时（`responseTimeoutNanos`）：**已覆盖**（2026-10-03，
//     `testPresentAndWaitTimesOutToDefaultIndex`）。做法：`responseTimeoutNanos` 由
//     `private static let` 放宽为 `internal static var`（默认值仍 300s，生产行为不变），
//     测试注入 0.05s 直接断言超时到期按默认按钮应答。
//  2. `NoticeOverlay` 的 onAppear/onDisappear → `setPresenter` 挂载时机依赖 SwiftUI
//     视图生命周期，无 UI 承载时无法验证，本文件只直接驱动 `setPresenter`。
//  3. `shared` 单例的历史无法在用例间清空（无 reset 接口），因此断言一律写成
//     「相对形状」（末 N 条 / 不含某 id），不依赖绝对下标。
