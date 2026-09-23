//
//  ArchiveUtil.swift
//  SL启动器
//
//  zip / jar 归档的**只读取值**工具（基于 ZIPFoundation）：
//  判断条目是否存在、把条目内容整份取成 Data。
//  本类型不提供写入或修改归档的能力 —— 写入路径不在 SLCore 这一层。
//
//  Created by YiZhiMCQiu on 2025/7/30.
//

import Foundation
import ZIPFoundation

/// 归档只读工具。全部方法都是 `static`，且 `init` 被私有化 ——
/// 本类型只是一个命名空间，不应（也无法）被实例化。
public class ArchiveUtil {
    /// 归档里是否存在名为 name 的条目。
    ///
    /// ⚠️ 归档**打不开**（不存在 / 不是 zip / 已损坏）时同样返回 `false`：
    /// 调用方无法区分「没有这个条目」与「这个归档根本读不了」。
    /// 需要区分时请改用 `getEntryOrThrow`，它会把打开失败也抛出来。
    public static func hasEntry(url: URL, name: String) -> Bool {
        do {
            let archive = try Archive(url: url, accessMode: .read)
            return hasEntry(archive: archive, name: name)
        } catch {
            err("无法读取归档: \(error.localizedDescription)")
        }
        return false
    }
    
    /// 已打开归档的重载版本。**批量查询时应当用这个**：
    /// `Archive(url:)` 每次都会重新打开文件并解析一遍中央目录，
    /// 循环里逐个调用 URL 版本等于把同一份目录解析 N 遍。
    public static func hasEntry(archive: Archive, name: String) -> Bool {
        return archive[name] != nil
    }
    
    /// 取出条目的原始字节。条目不存在时抛 `MyLocalizedError`；
    /// 归档打不开或解压出错时，底层错误同样直接向上抛。
    public static func getEntryOrThrow(url: URL, name: String) throws -> Data {
        return try getEntryOrThrow(archive: Archive(url: url, accessMode: .read), name: name)
    }
    
    /// 已打开归档的重载版本（同样只在批量取用时才划算，见上方 `hasEntry` 的说明）。
    public static func getEntryOrThrow(archive: Archive, name: String) throws -> Data {
        // 整份读进内存：条目小时无所谓，但**大条目（几十 MB 的 jar）会全量驻留内存**。
        // 需要流式处理时请绕过本方法，直接用 Archive.extract 的 consumer 回调。
        if let manifest = archive[name] {
            var data = Data()
            _ = try archive.extract(manifest, consumer: { (chunk) in
                data.append(chunk)
            })
            return data
        }
        throw MyLocalizedError(reason: "项 \(name) 不存在")
    }
    
    /// 静默版本：条目不存在 / 归档打不开 / 解压失败，一律返回 `nil`，且**不打日志**。
    /// 因此它适合「有没有都行」的探测，不适合需要区分失败原因的场景。
    public static func getEntry(url: URL, name: String) -> Data? {
        try? getEntryOrThrow(url: url, name: name)
    }
    
    private init() {}
}
