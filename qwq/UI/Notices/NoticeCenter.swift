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

    public init(id: UUID = UUID(),
                level: NoticeLevel,
                title: String,
                message: String,
                allowsReportExport: Bool = false,
                buttons: [NoticeButton] = [.ok]) {
        self.id = id
        self.level = level
        self.title = title
        self.message = message
        self.allowsReportExport = allowsReportExport
        self.buttons = buttons
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
    init(_ model: PopupModel) {
        self.init(
            level: NoticeLevel(model.type),
            title: model.title,
            message: model.message,
            allowsReportExport: model.buttons.contains { $0.label.contains("导出") },
            buttons: model.buttons.map { NoticeButton(label: $0.label, style: $0.style) }
        )
    }
}

// MARK: - NoticeCenter

/// 全局统一的用户提示通道。
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
    private static let responseTimeoutNanos: UInt64 = 300 * 1_000_000_000

    /// 尚未应答的 `showAsync` 等待者。
    private var pending: [UUID: CheckedContinuation<Int, Never>] = [:]

    private nonisolated init() {}

    // MARK: 投递

    /// 投递一条提示。**线程安全**：可在任意线程/任意 actor 调用。
    public nonisolated func post(_ notice: Notice) {
        Task { @MainActor in self.deliver(notice) }
    }

    @MainActor
    private func deliver(_ notice: Notice) {
        history.append(notice)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        // `current` 是单槽：新提示会顶替旧的，被顶替那条在 UI 上已不复存在，
        // 若它仍在等待点选，用户永远点不到它 —— 必须**立刻**按默认按钮应答，
        // 否则调用方只能等满 `responseTimeoutNanos` 兜底（崩溃弹窗的「导出报告」因此挂 5 分钟）。
        if let displaced = current, displaced.id != notice.id {
            answer(displaced.id, index: 0)
        }
        current = notice
    }

    // MARK: 展示 + 等待点选

    /// 展示提示并等待用户点选，返回被点按钮在 `notice.buttons` 中的下标。
    ///
    /// - 有 UI 承载者时：真正挂起，直到用户点击 / 关闭 / 被新提示顶替 / 兜底超时。
    /// - 无 UI 承载者（overlay 未挂载）时：不挂起，直接返回 `0`（默认按钮），
    ///   语义与旧桩实现一致，保证不会把调用方卡死。
    @MainActor
    public func presentAndWait(_ notice: Notice) async -> Int {
        guard hasPresenter else {
            deliver(notice)
            current = nil
            return 0
        }

        // 兜底：极端情况下（窗口关闭、用户始终不点）不能让调用方永久挂起。
        // 该任务不随用户点选而取消，但「迟到触发」是安全的：`answer` 摘不到条目即无操作，
        // 见其「恰好一次」说明。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.responseTimeoutNanos)
            self?.choose(notice, index: 0)
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            // 同一 `notice.id` 若已有未应答的等待（同一个 `Notice` 值被等待两次），
            // 先按默认按钮应答旧的：否则下面的字典赋值会覆盖旧 continuation，使它永不 resume。
            answer(notice.id, index: 0)
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

    /// 用户关闭当前提示（点右上角 ×）。若该提示正在等待选择，则按默认按钮（下标 0）应答。
    @MainActor
    public func dismiss() {
        guard let notice = current else { return }
        choose(notice, index: 0)
    }

    // MARK: 承载者注册

    @MainActor
    func setPresenter(_ attached: Bool) {
        hasPresenter = attached
    }
}
