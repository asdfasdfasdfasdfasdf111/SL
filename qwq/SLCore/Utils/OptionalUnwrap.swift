//
//  OptionalUnwrap.swift
//  SL启动器
//
//  从 Stubs.swift 迁移而来：将 `Optional.unwrap` 从兼容层搬到正式模块文件，
//  签名、默认参数（`file` / `line`）、错误类型（`MyLocalizedError`，同模块 Utils）均保持不变，
//  因此所有调用点无需任何修改。
//

import Foundation

public extension Optional {
    /// 解包失败时抛出带调用位置信息的 `MyLocalizedError`。
    /// 使用方：`SLCore/Minecraft/Download/InstallTask.swift`、
    /// `SLCore/Download/DownloadSource.swift`、`SLCore/Download/DownloadSourceManager.swift`、
    /// `Features/ModBrowser/ModDownloader.swift` 等（调用点未改动）。
    func unwrap(_ errorMessage: String? = nil, file: String = #file, line: Int = #line) throws -> Wrapped {
        guard let value = self else {
            throw MyLocalizedError(reason: errorMessage ?? "\(file.split(separator: "/").last!):\(line) 解包失败")
        }
        return value
    }
}
