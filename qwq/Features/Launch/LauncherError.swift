//
//  LauncherError.swift
//  启动器的统一错误枚举（`Error` + `LocalizedError`，文案即用户可见提示）。
//
//  ⚠️ 现状与命名已经脱节（2026-09-23 全库核实，逐条列出以便后续处置）：
//  本文件位于 `Features/Launch/` 且名为 `LauncherError`，但**实际在用的只有 2 个 case，
//  且全部属于皮肤 / 资源包注入**；其余 5 个与「启动」相关的 case 在全库（含 qwqTests）
//  **没有任何抛出点**，只在本文件的 `errorDescription` 的 switch 里出现。
//
//  有抛出点的 case（11 处调用）：
//  - `skinValidationFailed`（10 处）：`SkinAvatarCropper.swift` 7 处、
//    `OfflineSkinService.swift:105`、`UI/ViewComponents.swift:129`
//  - `jarModificationFailed`（1 处）：`SkinResourcePackApplier.swift:172`
//
//  零抛出点的 case（5 个，属死枚举）：`noJavaFound`、`noGameDirectoryFound`、
//  `noVersionsFound`、`versionJsonMissing(path:)`、`versionJarMissing(path:)`。
//  它们对应的场景现在由别处负责提示（Java 缺失走 `JavaResolver` / Java 选择气泡，
//  游戏目录与版本缺失走启动前置检查的 `hint()` 通道），因此这几条文案从未到达过用户。
//  与工程里其它死代码不同，这里**尚未**加 `@available(*, deprecated, message: "全库无引用，待清理")`
//  标注 —— 若要沿用同一约定，可补标注；本文档只记录事实，不擅自改动枚举。
//

import Foundation

/// 启动器错误。文案直接展示给用户，故每条都要能让人知道「下一步做什么」。
enum LauncherError: Error, LocalizedError {
    // MARK: - 以下 5 个 case 当前无任何抛出点（见文件头说明）
    case noJavaFound
    case noGameDirectoryFound
    case noVersionsFound
    case versionJsonMissing(path: String)
    case versionJarMissing(path: String)

    // MARK: - 以下 2 个 case 是当前唯一在用的（皮肤 / 资源包注入）
    /// 皮肤文件校验或处理失败；字符串为具体原因（如「不支持的尺寸: 64×32」）
    case skinValidationFailed(String)
    /// 向版本 jar 注入皮肤资源包后处理失败；字符串为具体原因
    case jarModificationFailed(String)

    /// 用户可见文案。Java 版本要求（Java 17）与 `noJavaFound` 的提示保持一致口径。
    var errorDescription: String? {
        switch self {
        case .noJavaFound: return "未找到任何 Java 运行时，请安装 Java 17 或更高版本"
        case .noGameDirectoryFound: return "未找到有效的 Minecraft 游戏目录（缺少 versions 子目录）"
        case .noVersionsFound: return "版本目录为空，请确保 versions 下至少有一个版本子目录"
        case .versionJsonMissing(let path): return "版本 JSON 文件不存在: \(path)"
        case .versionJarMissing(let path): return "版本 JAR 文件不存在: \(path)"
        case .skinValidationFailed(let msg): return "皮肤无效: \(msg)"
        case .jarModificationFailed(let msg): return "修改皮肤失败: \(msg)"
        }
    }
}