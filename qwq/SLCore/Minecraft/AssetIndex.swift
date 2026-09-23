//
//  AssetIndex.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/6/15.
//
//  ── 本文件职责 ─────────────────────────────────────────────
//  解析 Minecraft 的**资源索引文件**（版本 JSON 里 `assetIndex.url` 指向的那个
//  `<assetsIndexId>.json`），把它变成一组「待下载/待校验的资源对象」。
//
//  官方文件结构：
//      { "objects": { "<逻辑路径>": { "hash": "<sha1>", "size": 123 }, ... } }
//
//  ── 边界（本文件不管什么）─────────────────────────────────
//  - 不下载、不落盘、不校验本地文件是否存在 —— 那是调用方的事。
//  - **不保留字典的 key（资源的逻辑路径）**。资源按「内容哈希」寻址，下载只需要
//    hash + size；路径信息在这里就被丢掉了。若将来要还原真实目录结构，这里不够用。
//
//  ── 已知消费方 ────────────────────────────────────────────
//  `LaunchFix.swift`（启动前资源补全，:63 / :79 / :86 / :114）、
//  `MinecraftInstaller.swift`（:143 统计进度总量）、
//  `MinecraftInstallerDownloads.swift`（:206 / :212 实际下载与落盘）。
//

import SwiftyJSON
import Foundation

/// 一个游戏版本所引用的资源清单。
public class AssetIndex {
    /// 全部资源对象（正式版通常是数千个）。
    public let objects: [Object]
    
    /// 从索引 JSON 构造。
    /// **注意**：只取 `objects` 字典的 value（hash/size），key（逻辑路径）被丢弃 —— 见文件头说明。
    public init(_ json: JSON) {
        self.objects = json["objects"].dictionaryValue.values.map(Object.init)
    }
    
    /// 由已有对象数组构造（从缓存重建、或测试时手工构造用）。
    public init(objects: [Object]) {
        self.objects = objects
    }
    
    /// 单个资源对象。寻址依据是内容哈希，而不是路径 —— 同一份内容无论被多少版本引用，
    /// 都只存一份。
    public class Object {
        /// 内容的 SHA-1（小写十六进制）。同时也是它在磁盘上的**文件名**。
        public let hash: String
        /// 内容字节数。用于进度统计与校验。
        public let size: Int32
        
        public init(_ json: JSON) {
            self.hash = json["hash"].stringValue
            self.size = json["size"].int32Value
        }
        
        /// 把本资源拼到资源根目录下，返回最终文件 URL。
        ///
        /// 路径规则是 `<base>/<hash 前两位>/<hash>`，这是 Minecraft 官方的**分桶布局**：
        /// 用哈希前两位开一级子目录，避免单个 `objects/` 目录里堆几万个文件
        /// （文件系统与 Finder 都撑不住）。
        ///
        /// 因此调用方传入的 `url` 应当是 `.../assets/objects` 本身，而**不是**版本目录 ——
        /// 见 `LaunchFix.swift:86` 与 `MinecraftInstallerDownloads.swift:212`。
        public func appendTo(_ url: URL) -> URL {
            return url.appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash)
        }
    }
    
    /// 从索引文件的原始字节解析。`JSON(data:)` 失败时抛出，调用方负责降级处理。
    public static func parse(_ data: Data) throws -> AssetIndex {
        let json = try JSON(data: data)
        return AssetIndex(json)
    }
}
