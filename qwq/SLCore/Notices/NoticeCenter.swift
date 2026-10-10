import Combine
import Foundation
import SwiftUI

// MARK: - Notice 数据模型

/// 提示级别。决定展示颜色与图标。
public enum NoticeLevel: Equatable {
    case info
    case success
    case warning
    case error
}

/// 提示上的一个按钮（`PopupButton` 的可渲染版本）。
public struct NoticeButton: Identifiable, Equatable {
    public let id: UUID
    public let label: String
    public let style: PopupButtonStyle

    public init(label: String, style: PopupButtonStyle = .normal) {
        self.id = UUID()
        self.label = label
        self.style = style
    }

    public static let ok = NoticeButton(label: "确定")

    /// 该按钮是否只是「知道了」——即其唯一语义就是关闭本条提示。
    ///
    /// 用途：`NoticeOverlay` 据此**不渲染**与右上角 `×` 重复的那个控件。
    /// 依据：`NoticeCenter.dismiss()` 内部就是 `choose(notice, index: 0)`，点 `×` 与点本按钮是
    /// 同一个动作（`choose` 会把下标回传给 `presentAndWait` 的等待者），因此「不渲染它」
    /// 不影响任何调用方拿到的下标值 —— 这是零行为变更的收敛。
    public var isAcknowledge: Bool {
        ["确定", "好的", "关闭", "知道了"].contains(label)
    }
}

/// 一条 **用户可见** 的提示。`NoticeCenter` 负责把它送到 `NoticeOverlay` 上。
public struct Notice: Identifiable, Equatable {
    public let id: UUID
    public let level: NoticeLevel
    public let title: String
    public let message: String
    /// 错误类提示是否附带「导出错误报告」入口。
    public let allowsReportExport: Bool
    /// 需要展示的按钮。默认单个「确定」。
    public let buttons: [NoticeButton]
    /// **没有真人点选时**按哪个按钮应答（兜底超时 / 点右上角 × / 被新提示顶替 / 同一 id 重复等待）。
    /// 默认 `0` —— 即首个按钮，与历史行为逐字一致。
    ///
    /// 为什么需要它：调用方不能假设「隐式应答」等于「用户想执行第一个按钮」。
    /// 反例（2026-10-10 实测存在）：更新提示的按钮是「立即更新 / 下次再说」，此前所有隐式
    /// 应答都硬编码下标 0，于是**用户没看见弹窗（或点了 ×、或晾着不管 5 分钟）＝ 自动开始
    /// 下载并替换 App**。凡是「首个按钮不是安全选项」的提示，都必须显式指定本字段。
    public let fallbackChoiceIndex: Int
    /// 进度类提示的完成度（`0...1`）。`nil` = 不显示进度条。
    ///
    /// 必须配合 `NoticeCenter.update(_:)` 用**同一个 `id`** 就地刷新：`post` 一条新 id
    /// 的提示会让 overlay 按 `.id(notice.id)` 把卡片拆掉重建、重放出现动画，
    /// 表现成「进度条每刷新一次就抽搐一下」（用户 2026-10-10 实测反馈）。
    public let progress: Double?

    public init(id: UUID = UUID(),
                level: NoticeLevel,
                title: String,
                message: String,
                allowsReportExport: Bool = false,
                buttons: [NoticeButton] = [.ok],
                fallbackChoiceIndex: Int = 0,
                progress: Double? = nil) {
        self.id = id
        self.level = level
        self.title = title
        self.message = message
        self.allowsReportExport = allowsReportExport
        self.buttons = buttons
        self.fallbackChoiceIndex = fallbackChoiceIndex
        self.progress = progress
    }

    /// 隐式应答实际使用的下标：把 `fallbackChoiceIndex` 夹进 `buttons` 的合法范围。
    /// （提示可能没有按钮，或调用方给了越界值 —— 越界会让 `choose` 的语义变得没有定义。）
    public var safeFallbackChoiceIndex: Int {
        guard !buttons.isEmpty else { return 0 }
        return min(max(0, fallbackChoiceIndex), buttons.count - 1)
    }

    public static func == (lhs: Notice, rhs: Notice) -> Bool { lhs.id == rhs.id }
}

// MARK: - 级别映射

public extension NoticeLevel {
    /// `PopupModel` 的类型 → 提示级别。
    init(_ type: PopupType) {
        switch type {
        case .info: self = .info
        case .warning: self = .warning
        case .error: self = .error
        }
    }

    /// `HintType` → 提示级别（PCL2 中 `finish` 为成功提示，`critical` 为错误）。
    init(_ type: HintType) {
        switch type {
        case .info: self = .info
        case .finish: self = .success
        case .critical: self = .error
        }
    }

    /// 提示标题（`hint` 只有正文，没有标题，这里补一个默认标题）。
    var defaultTitle: String {
        switch self {
        case .info: return "提示"
        case .success: return "完成"
        case .warning: return "注意"
        case .error: return "错误"
        }
    }
}

public extension Notice {
    /// 由旧的 `PopupModel` 构造提示，保持 `PopupManager` 调用点的语义不变。
    /// `allowsReportExport` 直接透传 `PopupModel.allowsReportExport`（显式字段，
    /// 2026-10-02 起不再靠「按钮 label 含『导出』」的字符串推导）。
    init(_ model: PopupModel) {
        self.init(
            level: NoticeLevel(model.type),
            title: model.title,
            message: model.message,
            allowsReportExport: model.allowsReportExport,
            buttons: model.buttons.map { NoticeButton(label: $0.label, style: $0.style) }
        )
    }
}

// MARK: - NoticeCenter

/// 全局统一的用户提示通道。
///
/// **归属**：本类型 2026-10-04 从 `UI/Notices/` 下沉到 `SLCore/Notices/`。
/// 它是 `@MainActor` 的全局通知通道（不渲染任何 UI——渲染在 `UI/Notices/NoticeOverlay`），
/// 本质是基础设施层组件；放 UI 目录导致 `SLCore/Notices/Hint.swift`/`Popup.swift`
/// 反向依赖 UI 层（分层倒置，SLOP-AUDIT REV2 §2 判据 A）。下沉后 SLCore 内部自洽，
/// UI 层只保留渲染（NoticeOverlay 消费 `NoticeCenter.shared`，方向 UI→SLCore 正确）。
///
/// 设计约定：
///  - 唯一的可变状态（`current` / `history` / `pending`）都在 MainActor 上，
///    因此对 SwiftUI 是安全的；
///  - `post(_:)` 是 `nonisolated` 的，**可以从任意线程调用**（内部 hop 到 MainActor），
///    这是让 `hint()` 这类非隔离全局函数也能投递提示的关键；
///  - `presentAndWait(_:)` 供 `PopupManager.showAsync` 使用，会真正等待用户点选按钮；
///    当 UI 承载者（`NoticeOverlay`）未挂载时**不会阻塞调用方**，直接按默认按钮（下标 0）返回。
@MainActor
public final class NoticeCenter: ObservableObject {
    /// `shared` 必须是非隔离的：`hint()` 等非隔离调用方需要直接拿到实例再走 `post`。
    public nonisolated static let shared = NoticeCenter()

    /// 当前正在展示的提示；`nil` 表示无提示。
    @Published public private(set) var current: Notice?
    /// 历史提示（最多 `historyLimit` 条），仅用于事后排查，不参与渲染。
    @Published public private(set) var history: [Notice] = []
    /// 是否已有 UI 承载者挂载。由 `NoticeOverlay.onAppear/onDisappear` 维护。
    @Published public private(set) var hasPresenter: Bool = false

    public static let historyLimit = 20
    /// 等待用户点选的兜底超时：超时按默认按钮（下标 0）返回，避免调用方永久挂起。
    /// `internal static var`（2026-10-03 由 `private static let` 放宽）：供测试注入短时长
    /// 直接断言超时路径（真等 300s 不现实）。默认值保持 300s，生产行为不变。
    static var responseTimeoutNanos: UInt64 = 300 * 1_000_000_000

    /// 尚未应答的 `showAsync` 等待者。
    private var pending: [UUID: CheckedContinuation<Int, Never>] = [:]

    private nonisolated init() {}

    // MARK: 投递

    /// 投递一条提示。**线程安全**：可在任意线程/任意 actor 调用。
    public nonisolated func post(_ notice: Notice) {
        // 已在主线程上时**同步**投递：否则 `Task { @MainActor in }` 会把投递推迟到下一轮 runloop，
        // 导致「先 post 后 presentAndWait」这类同线程调用出现投递顺序倒置 ——
        // 后发的 `presentAndWait`（其 `deliver` 是同步的）反而先落到 `current` 上。
        // `MainActor.assumeIsolated` 仅在确实位于主 actor 时执行闭包（主线程即主 actor），否则即崩溃；
        // 后台线程走原 hop 路径，行为不变。
        // 可用性已实测：`assumeIsolated` 在本工程部署目标 macOS 13.0 下类型检查通过（非 14.0-only）。
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.deliver(notice) }
        } else {
            Task { @MainActor in self.deliver(notice) }
        }
    }

    @MainActor
    private func deliver(_ notice: Notice) {
        history.append(notice)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        // `current` 是单槽：新提示会顶替旧的，被顶替那条在 UI 上已不复存在，
        // 若它仍在等待点选，用户永远点不到它 —— 必须**立刻**按该提示自己的隐式按钮应答，
        // 否则调用方只能等满 `responseTimeoutNanos` 兜底（崩溃弹窗的「导出报告」因此挂 5 分钟）。
        if let displaced = current, displaced.id != notice.id {
            answer(displaced.id, index: displaced.safeFallbackChoiceIndex)
        }
        current = notice
    }

    /// **就地更新**正在展示的那条提示（同一个 `id`）：只换内容，不重放出现动画。
    ///
    /// 为什么必须存在这个方法：overlay 用 `.id(notice.id)` 作卡片身份，`post` 一条新 id
    /// 的提示等于「旧卡拆掉、新卡建起」，出现动画（opacity + scale + punchySpring）
    /// 会重放一次 —— 表现为进度条一刷新就抽搐。下载/安装进度这类高频更新走这里。
    ///
    /// 边界：
    ///  - 只更新**正在展示**的那条（`current?.id == notice.id`）；提示已被用户关闭或被别的
    ///    提示顶替时**静默忽略** —— 否则会把用户已经关掉的卡片重新拉回屏幕上；
    ///  - 同步替换 `history` 里同 id 的那条，让事后排查看到的是最终内容而不是中间态。
    @MainActor
    public func update(_ notice: Notice) {
        guard current?.id == notice.id else { return }
        current = notice
        if let index = history.lastIndex(where: { $0.id == notice.id }) {
            history[index] = notice
        }
    }

    // MARK: 展示 + 等待点选

    /// 展示提示并等待用户点选，返回被点按钮在 `notice.buttons` 中的下标。
    ///
    /// - 有 UI 承载者时：真正挂起，直到用户点击 / 关闭 / 被新提示顶替 / 兜底超时。
    /// - 无 UI 承载者（overlay 未挂载）时：不挂起，直接返回 `notice.safeFallbackChoiceIndex`，
    ///   保证不会把调用方卡死（对默认提示即历史行为的下标 0）。
    @MainActor
    public func presentAndWait(_ notice: Notice) async -> Int {
        guard hasPresenter else {
            deliver(notice)
            current = nil
            return notice.safeFallbackChoiceIndex
        }

        // 兜底：极端情况下（窗口关闭、用户始终不点）不能让调用方永久挂起。
        // 该任务不随用户点选而取消，但「迟到触发」是安全的：`answer` 摘不到条目即无操作，
        // 见其「恰好一次」说明。
        // 应答下标取提示自己的 `fallbackChoiceIndex`：**不得**硬编码 0（见该字段说明）。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.responseTimeoutNanos)
            self?.choose(notice, index: notice.safeFallbackChoiceIndex)
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            // 同一 `notice.id` 若已有未应答的等待（同一个 `Notice` 值被等待两次），
            // 先按默认按钮应答旧的：否则下面的字典赋值会覆盖旧 continuation，使它永不 resume。
            answer(notice.id, index: notice.safeFallbackChoiceIndex)
            pending[notice.id] = continuation
            deliver(notice)
        }
    }

    // MARK: 用户交互

    /// 用户点选了 `index` 号按钮：关闭提示，并把下标回传给等待者（若有）。
    @MainActor
    public func choose(_ notice: Notice, index: Int) {
        if current?.id == notice.id { current = nil }
        answer(notice.id, index: index)
    }

    /// 应答一个等待点选的调用方：摘除并 resume 它的 continuation。
    ///
    /// **「恰好一次」保证**（唯一入口 + 原子摘除）：
    ///  - 全部应答来源——用户点选 `choose`、关闭 `dismiss`、兜底超时任务、被新提示顶替
    ///    （`deliver`）、同一 id 重复等待（`presentAndWait`）——都只走这一个入口；
    ///  - `pending` 只在 MainActor 上读写，`removeValue` 是同步的原子摘除，
    ///    摘到即立刻 resume、摘不到即返回，**不存在「摘到一次以上」或「无摘除却 resume」的路径**；
    ///  - 因此每个 continuation 至多 resume 一次，且迟到的应答（用户已点选后兜底超时才到期、
    ///    被顶替后原超时才到期）一律摘不到条目，直接无操作，不会重复 resume、也不会误伤后来者。
    @MainActor
    private func answer(_ noticeID: UUID, index: Int) {
        guard let continuation = pending.removeValue(forKey: noticeID) else { return }
        continuation.resume(returning: index)
    }

    /// 用户关闭当前提示（点右上角 ×）。若该提示正在等待选择，则按该提示的隐式按钮
    /// （`fallbackChoiceIndex`，默认下标 0）应答 —— 「关掉弹窗」绝不能等于「执行首个按钮」，
    /// 除非提示自己就是这么声明的。
    @MainActor
    public func dismiss() {
        guard let notice = current else { return }
        choose(notice, index: notice.safeFallbackChoiceIndex)
    }

    // MARK: 承载者注册

    @MainActor
    func setPresenter(_ attached: Bool) {
        hasPresenter = attached
    }
}
