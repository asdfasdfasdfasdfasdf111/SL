//
//  LauncherError.swift
//  启动器的统一错误枚举（`Error` + `LocalizedError`，文案即用户可见提示）。
//
//  现状（2026-10-02 复核）：本文件仅保留**在用**的 2 个 case（皮肤 / 资源包注入）：
//  - `skinValidationFailed`（10 处）：`SkinAvatarCropper.swift` 7 处、
//    `OfflineSkinService.swift:105`、`UI/ViewComponents.swift:129`
//  - `jarModificationFailed`（1 处）：`SkinResourcePackApplier.swift:172`
//
//  原 5 个「启动」相关的 case（`noJavaFound` / `noGameDirectoryFound` / `noVersionsFound` /
//  `versionJsonMissing` / `versionJarMissing`）已于 2026-10-02 删除：它们在全库（含
//  qwqTests）没有任何抛出点，对应场景现由别处提示（Java 缺失走 `JavaResolver` /
//  Java 选择气泡，游戏目录与版本缺失走启动前置检查的 `hint()` 通道），其文案从未到达过用户。
//

import Foundation

/// 启动器错误。文案直接展示给用户，故每条都要能让人知道「下一步做什么」。
enum LauncherError: Error, LocalizedError {
    /// 皮肤文件校验或处理失败；字符串为具体原因（如「不支持的尺寸: 64×32」）
    case skinValidationFailed(String)
    /// 向版本 jar 注入皮肤资源包后处理失败；字符串为具体原因
    case jarModificationFailed(String)

    /// 用户可见文案。
    var errorDescription: String? {
        switch self {
        case .skinValidationFailed(let msg): return "皮肤无效: \(msg)"
        case .jarModificationFailed(let msg): return "修改皮肤失败: \(msg)"
        }
    }
}