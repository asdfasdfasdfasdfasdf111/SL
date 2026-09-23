//
//  InstallProgress.swift
//  SL启动器
//
//  安装进度词汇（从 InstallTask.swift 逐字搬移，逻辑与文案未变）：
//  - InstallStage：阶段枚举与显示名
//  - InstallState：阶段状态与图标名
//
//  ── 这套词汇怎么被用起来 ────────────────────────────────────
//  每个 `InstallTask` 通过 `getInstallStates() -> [InstallStage: InstallState]`
//  自报「我有哪些阶段、各自什么状态」；`DownloadDetailView.entries(for:)` 把它渲染成
//  下载详情页里的那串清单。
//
//  ── 关键约束：rawValue 就是 UI 的显示顺序 ─────────────────────
//  `DownloadDetailView.entries(for:)` 里是这样排序的：
//      states.sorted { $0.key.rawValue < $1.key.rawValue }
//  也就是说**显示的先后完全由这里的 Int 决定，不是由 case 的书写顺序决定**。
//  新增阶段时选错数值，界面上就会跳到别处（例如把新阶段写成 3，它会插到
//  「原版 jar」和「资源索引」之间）。数值分段是有意的（见下）。
//

// MARK: - 安装进度定义
/// 安装流水线的阶段。
///
/// **数值分段（改动前务必想清楚）**：
/// - `0...7`：固定的原版安装流水线，顺序即真实执行顺序（json → 索引 → jar → 资源 →
///   依赖 → 本地库 → 结束）。
/// - `1000+`：**加载器安装**（Fabric / Forge / NeoForge）。刻意跳开 0...7，
///   这样以后往原版流水线里插入新阶段时，不必回头去挪这一段的数值。
/// - `2000+`：**自定义文件 / 模组下载**，同样是留白分段。
///
/// 因此这里的 Int 不是「序号」而是「排序键」，新增时请沿用分段惯例。
public enum InstallStage: Int {
    case before = 0
    case clientJson = 1
    case clientIndex = 2
    case clientJar = 3
    case clientResources = 4
    case clientLibraries = 5
    case natives = 6
    case end = 7
    
    case installFabric = 1000
    case installForge = 1001
    case installNeoforge = 1002
    
    case customFile = 2000
    case modDownload = 2001
    
    /// 面向用户的中文阶段名，直接显示在下载详情页的清单里（`DownloadDetailView.swift:107`）。
    /// 另有一条调试日志也会用到：`InstallTask.swift:65` 的「切换阶段: …」。
    ///
    /// 文案就是产品界面的一部分，改动即为用户可见变更 —— 不要为了「顺眼」而调整措辞。
    public func getDisplayName() -> String {
        switch self {
        case .before: "未启动"
        case .clientJson: "下载原版 json 文件"
        case .clientJar: "下载原版 jar 文件"
        case .installFabric: "安装 Fabric"
        case .installForge: "安装 Forge"
        case .installNeoforge: "安装 NeoForge"
        case .clientIndex: "下载资源索引文件"
        case .clientResources: "下载散列资源文件"
        case .clientLibraries: "下载依赖项文件"
        case .natives: "下载本地库文件"
        case .customFile: "下载自定义文件"
        case .modDownload: "下载文件"
        case .end: "结束"
        }
    }
}

// MARK: - 安装进度状态定义
/// 单个阶段的状态。
public enum InstallState {
    case waiting, inprogress, finished, failed
    /// 阶段图标名（资源名，不是 SF Symbol）。
    ///
    /// **当前零调用方**（2026-09-23 全库 grep `getImageName()` 只命中本定义）：
    /// 界面实际走的是 `DownloadDetailView.iconName(for:)` —— 那边返回 SF Symbol，
    /// 且四种状态都有图标。本方法只剩 `waiting`/`finished` 两枚自绘资源，
    /// 另两种状态返回占位串 `"Missingno"`。属遗留代码，可清理但尚未清理。
    public func getImageName() -> String {
        switch self {
        case .waiting:
            "InstallWaiting"
        case .finished:
            "InstallFinished"
        default:
            "Missingno"
        }
    }
}
