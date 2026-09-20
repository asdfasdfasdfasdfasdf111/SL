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
//  4. 应答语义：无 UI 承载者（overlay 未挂载）时 `presentAndWait` 必须立即按默认按钮（下标 0）
//     返回且不留 current，绝不阻塞调用方；有承载者时真正挂起，`choose` / `dismiss`
//     分别按点选下标与默认按钮（0）应答；
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
    func testDismissWithoutCurrentIsNoOp() {
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
    func testHasPresenterFollowsRegistration() {
        center.setPresenter(true)
        XCTAssertTrue(center.hasPresenter)
        center.setPresenter(false)
        XCTAssertFalse(center.hasPresenter)
    }

    // MARK: - 级别映射与文案

    /// PopupType → NoticeLevel：三种类型一一对应，无 success 分支
    func testNoticeLevelFromPopupType() {
        XCTAssertEqual(NoticeLevel(PopupType.info), .info)
        XCTAssertEqual(NoticeLevel(PopupType.warning), .warning)
        XCTAssertEqual(NoticeLevel(PopupType.error), .error)
    }

    /// HintType → NoticeLevel：finish 是成功提示（不是 info），critical 是错误
    func testNoticeLevelFromHintType() {
        XCTAssertEqual(NoticeLevel(HintType.info), .info)
        XCTAssertEqual(NoticeLevel(HintType.finish), .success)
        XCTAssertEqual(NoticeLevel(HintType.critical), .error)
    }

    /// 四个级别都有非空默认标题（hint 只有正文，标题由此补全）
    func testDefaultTitlesForEachLevel() {
        XCTAssertEqual(NoticeLevel.info.defaultTitle, "提示")
        XCTAssertEqual(NoticeLevel.success.defaultTitle, "完成")
        XCTAssertEqual(NoticeLevel.warning.defaultTitle, "注意")
        XCTAssertEqual(NoticeLevel.error.defaultTitle, "错误")
    }

    /// 默认按钮：单个「确定」，样式 normal；默认不提供错误报告导出
    func testDefaultNoticeShape() {
        let notice = Notice(level: .info, title: "提示", message: "正文")

        XCTAssertEqual(notice.buttons.count, 1)
        XCTAssertEqual(notice.buttons[0].label, "确定")
        XCTAssertEqual(notice.buttons[0].style, .normal)
        XCTAssertFalse(notice.allowsReportExport)
        XCTAssertEqual(NoticeButton.ok.label, "确定")
        XCTAssertEqual(NoticeButton.ok.style, .normal)
    }

    /// 由 PopupModel 转换：级别/标题/正文/按钮顺序与样式逐项保留
    func testNoticeFromPopupModelMapsFieldsAndButtons() {
        let model = PopupModel(.error,
                               "启动失败",
                               "无法定位 Java 运行时",
                               [PopupButton(label: "确定"),
                                PopupButton(label: "导出错误报告", style: .accent)])

        let notice = Notice(model)

        XCTAssertEqual(notice.level, .error)
        XCTAssertEqual(notice.title, "启动失败")
        XCTAssertEqual(notice.message, "无法定位 Java 运行时")
        XCTAssertEqual(notice.buttons.map(\.label), ["确定", "导出错误报告"])
        XCTAssertEqual(notice.buttons.map(\.style), [.normal, .accent])
        XCTAssertTrue(notice.allowsReportExport)
    }

    /// 不含「导出」按钮时不得出现导出入口
    func testNoticeFromPopupModelWithoutExportButtonDisablesReportExport() {
        let model = PopupModel(.warning, "注意", "磁盘空间不足", [PopupButton(label: "去清理")])
        let notice = Notice(model)

        XCTAssertEqual(notice.level, .warning)
        XCTAssertFalse(notice.allowsReportExport)
    }

    /// 导出判定按「按钮文案包含『导出』」，只要有一个命中即开启
    func testAllowsReportExportOnlyDependsOnButtonLabels() {
        let withExport = Notice(PopupModel(.error, "错误", "正文",
                                           [PopupButton(label: "取消"),
                                            PopupButton(label: "导出日志", style: .danger)]))
        XCTAssertTrue(withExport.allowsReportExport)

        let withoutExport = Notice(PopupModel(.error, "错误", "正文",
                                              [PopupButton(label: "取消"),
                                               PopupButton(label: "重试", style: .accent)]))
        XCTAssertFalse(withoutExport.allowsReportExport)
    }

    // MARK: - Notice 相等语义

    /// Notice 的相等按 id 判定（内容相同但 id 不同即不相等）
    func testNoticeEqualityIsIdentityBased() {
        let id = UUID()
        let lhs = Notice(id: id, level: .info, title: "标题", message: "正文")
        let rhs = Notice(id: id, level: .error, title: "别的标题", message: "别的正文")
        XCTAssertEqual(lhs, rhs)

        let other = Notice(level: .info, title: "标题", message: "正文")
        XCTAssertNotEqual(lhs, other)
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. `presentAndWait` 的 300s 兜底超时（`responseTimeoutNanos`）不做断言：
//     等待真实超时会把测试挂起 5 分钟；把常量改小又需要改动被测源码。
//     已覆盖的等价路径是 `dismiss()` 按默认按钮应答（同一 `choose(notice, index: 0)` 分支）。
//  2. `NoticeOverlay` 的 onAppear/onDisappear → `setPresenter` 挂载时机依赖 SwiftUI
//     视图生命周期，无 UI 承载时无法验证，本文件只直接驱动 `setPresenter`。
//  3. `shared` 单例的历史无法在用例间清空（无 reset 接口），因此断言一律写成
//     「相对形状」（末 N 条 / 不含某 id），不依赖绝对下标。
