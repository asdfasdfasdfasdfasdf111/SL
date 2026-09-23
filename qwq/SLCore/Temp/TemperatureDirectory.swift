//
//  TemperatureManager.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/8/1.
//
//  ── 本文件职责 ─────────────────────────────────────────────
//  一个「按名字开一块临时目录」的小工具：目录落在 `<Application Support>/Temp/<name>`，
//  用完可以整体 `free()` 掉。给需要「先攒一堆中间文件、再一次性打包/移走」的场景用。
//
//  ── 关键语义：同名即独占 ────────────────────────────────────
//  `init` 里如果发现同名目录**已经存在**，会先打一条警告、再把它**删掉重建**。
//  也就是说这个名字在全局只能有一份，后来的会覆盖先来的 —— 这是有意的
//  （避免残留的脏文件混进新任务的结果），但也意味着**两个任务用同一个 name
//  会互相踩**。新增使用点时请取一个能体现归属的名字。
//
//  ── 维护提示 ───────────────────────────────────────────────
//  1. 文件名与文件头注释不一致（注释写的是 `TemperatureManager.swift`，
//     实际文件名是 `TemperatureDirectory.swift`）—— 是改名后漏改的注释，非功能问题。
//  2. `root` 是**计算属性**，每次访问都重新拼一次路径。所以拿到 `TemperatureDirectory`
//     之后立刻 `free()`、再访问 `root`，得到的仍是同一条路径（不会报错，只是目录已不在）。
//  3. 目前唯一的使用点是 `MinecraftCrashHandler.swift:40`（导出崩溃报告）——
//     而那个导出功能本身还没接线，所以这条路径现在跑不到。
//

import Foundation

/// `<Application Support>/Temp/<name>` 形式的一次性工作目录。
public class TemperatureDirectory {
    /// 本目录的绝对路径。注意是计算属性，每次访问都重新拼（见文件头「维护提示 2」）。
    public var root: URL { SharedConstants.shared.temperatureURL.appendingPathComponent(name) }
    /// 目录名。`init` 之后不可变，也是「同名独占」的判据。
    private let name: String
    
    /// 创建并使用该名字的临时目录。
    ///
    /// - 若同名目录已存在：打 `warn` 日志并 `free()` 清空（见文件头「关键语义」）；
    /// - 随后无条件 `createDirectory`，所以 `init` 返回后目录**一定存在**（除非磁盘写不进去，
    ///   那种情况会被 `try?` 静默吞掉，后续写入才会失败）。
    public init(name: String) {
        self.name = name
        if FileManager.default.fileExists(atPath: root.path) {
            warn("\(name) 对应的 URL 已被占用")
            free()
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    
    /// 在目录下写一个文件，返回它的 URL；失败返回 `nil`。
    ///
    /// - `path` 可以是**多级相对路径**（如 `"a/b/c.txt"`）：会自动把父目录建出来，
    ///   调用方不需要自己 `createDirectory`。
    /// - `data` 传 `nil` 时只创建空文件。
    /// - 返回值标了 `@discardableResult`：不关心落点时可以忽略返回值。
    ///
    /// 注意：这里**不会覆盖**已存在的文件（`createFile` 在文件已存在时返回 false），
    /// 而 `init` 已经保证了目录是空的，所以实际使用时不会撞上这一点。
    @discardableResult
    public func createFile(path: String, data: Data? = nil) -> URL? {
        let path = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.createFile(atPath: path.path, contents: data) {
            return path
        } else {
            return nil
        }
    }
    
    /// 取目录内某个文件的 URL，**不创建也不检查存在性** —— 纯拼路径。
    public func getURL(path: String) -> URL { root.appendingPathComponent(path) }
    
    /// 删除整个目录（递归）。
    ///
    /// 目录不存在时什么都不做（不报错）；删除失败会打 `err` 但**不抛出** ——
    /// 清理失败不该反过来让调用方失败。
    public func free() {
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        } catch {
            err("在释放 \(name) 时发生错误: \(error)")
        }
    }
}
