//
//  MinecraftCrashHandler.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/7/14.
//
//  ── 本文件职责 ─────────────────────────────────────────────
//  把「一次崩溃现场」打包成一个 zip：环境信息 + 实际启动命令 + 启动器日志 +
//  游戏输出 + 游戏自己的 latest.log/debug.log/最新 crash-report + 版本 JSON。
//  目的是让用户把 zip 直接丢给开发者，而不必来回问「你的 Java 是什么架构」。
//
//  ── 关键机制：环境信息是「绕道」进报告的，不是直接写的 ─────────
//  文件头这几条 `log(...)`（架构 / 分支 / Java 架构 / 各 dylib 架构）**并没有**写进 zip，
//  它们是写进**启动器自己的日志**（`SharedConstants.shared.logURL`）；
//  随后 `:47` 把整份启动器日志复制成报告里的「SL启动器日志.log」，
//  环境信息就是这样顺带被带进去的。
//
//  因此有一个隐含前提：**写日志之后必须已经刷盘**，否则复制到的日志会缺最后几行。
//  想加新的环境信息，照这个套路写 `log(...)` 即可；但如果你改成直接写 zip，
//  记得两处都要照顾，否则信息会重复或缺失。
//
//  ── 失败策略：几乎全 `try?` ─────────────────────────────────
//  除了「遍历 natives 目录」和「遍历 crash-reports 目录」两处会打错误日志，
//  其余复制/打包失败都是**静默忽略**。也就是说：只要最后能出一个 zip，
//  报告里缺哪几个文件是没人知道的。这是有意的（宁可拿到残缺报告，
//  也不要因为某个文件不存在而让整个导出失败），但排查「报告里怎么没日志」时要记得这一点。
//
//  ── ⚠️ 接线缺口（重要）──────────────────────────────────────
//  `exportErrorReport` 目前**零调用方**（2026-09-23 全库 grep 只命中本定义）。
//  它是一段**完整但没接上线的能力**：`SLCore/Notices/Popup.swift` 的 `PopupManager.showAsync`
//  注释里也明确记着「本启动器当前仍缺失『崩溃后可导出错误报告』这条能力」。
//  所以用户看到的「导出错误报告」按钮点下去是没反应的 —— 这不是本文件的 bug，
//  而是**接线缺失**。接线的现成入口就是 `PopupManager.showAsync`（见该处注释）。
//

import Foundation
import ZIPFoundation

/// 崩溃现场的收集与打包。全部是静态方法/属性，无需实例。
public class MinecraftCrashHandler {
    /// 最近一次实际执行过的启动命令行。由 `MinecraftLauncher.swift:71` 在拼装完参数后写入，
    /// 导出时原样落到报告里的「启动命令.command」（可直接双击复现）。
    /// 初值 `"未设置"` 用来区分「还没启动过」和「启动了但命令为空」。
    public static var lastLaunchCommand: String = "未设置"
    
    /// 收集崩溃现场并打包成 zip 写到 `destination`。
    ///
    /// - Parameters:
    ///   - instance: 崩溃的实例（取它的版本目录、natives、版本 JSON）。
    ///   - launcher: 本次启动的 `MinecraftLauncher`，主要为了拿 `logURL`（游戏输出）。
    ///   - destination: 输出 zip 的落点，由调用方决定（通常走保存面板）。
    ///
    /// 流程与每步的取舍见文件头。特别说明两处：
    /// - **`natives/` 下的 dylib 架构**是排查「原生库加载失败」的关键证据，
    ///   所以逐个 `log` 出来（`:31` 跳过非 dylib 文件）。
    /// - 结尾会 `removeItem(at: launcher.logURL)` —— 报告拿走后**删掉游戏输出文件**；
    ///   而启动器日志本身不删（它还要继续用）。删失败也不管（`try?`）。
    public static func exportErrorReport(_ instance: MinecraftInstance, _ launcher: MinecraftLauncher, to destination: URL) {
        // MARK: - 输出环境信息
        // 注意：这些 log 落在启动器日志里，靠 :47 的复制进入报告 —— 见文件头说明。
        log("以下是 SL启动器 检测到的环境信息:")
        log("架构: \(Architecture.system)")
        log("分支: \(SharedConstants.shared.branch)")
        if let javaURL = instance.config.javaURL {
            log("Java 架构: \(Architecture.getArchOfFile(javaURL))")
        } else {
            log("Java 架构: 未知（未配置 Java 路径）")
        }
        
        // 逐个 native 库报架构：这是「Java 架构对、但某个 dylib 是错架构」这类
        // 疑难崩溃的唯一线索。整个目录不存在也不会中断导出。
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: instance.runningDirectory.appendingPathComponent("natives"),
                includingPropertiesForKeys: nil
            )
            for fileURL in contents {
                if fileURL.pathExtension != "dylib" { continue }
                log("\(fileURL.lastPathComponent) 架构: \(Architecture.getArchOfFile(fileURL))")
            }
        } catch {
            err("无法获取本地库: \(error.localizedDescription)")
        }
        
        debug("正在导出错误报告")
        
        // 先在 Temp 下开一个工作目录攒齐所有文件，最后整目录压成一个 zip。
        // TemperatureDirectory 的语义是「同名目录已存在就先清空」，所以重复导出不会串味。
        let tmp = TemperatureDirectory(name: "ErrorReport")
        try? FileManager.default.createDirectory(at: tmp.root, withIntermediateDirectories: true)
        
        // 导出启动命令
        tmp.createFile(path: "启动命令.command", data: lastLaunchCommand.data(using: .utf8))
        
        // 导出日志与输出
        try? FileManager.default.copyItem(at: SharedConstants.shared.logURL, to: tmp.root.appendingPathComponent("SL启动器日志.log"))
        try? FileManager.default.copyItem(at: launcher.logURL, to: tmp.root.appendingPathComponent("游戏崩溃前的输出.txt"))
        copyGameLogs(instance: instance, report: tmp.root)
        
        // 版本 JSON 一并带走：它包含依赖清单与启动参数模板，是复现环境所必需的。
        try? FileManager.default.copyItem(at: instance.runningDirectory.appendingPathComponent(instance.name + ".json"), to: tmp.root.appendingPathComponent(instance.name + ".json"))
        // shouldKeepParent: false —— 让 zip 解压后直接是这些文件，而不是外面再套一层 ErrorReport/。
        try? FileManager.default.zipItem(at: tmp.root, to: destination, shouldKeepParent: false)
        debug("错误报告导出完成")
        try? FileManager.default.removeItem(at: launcher.logURL)
        tmp.free()
    }
    
    /// 把游戏自己写下的日志补进报告。
    ///
    /// - `logs/latest.log` / `logs/debug.log`：直接复制（不存在就跳过）。
    /// - `crash-reports/`：**只取修改时间最新的那一个**。理由是这个目录会越攒越多，
    ///   全量打包会让报告体积失控；而真正相关的基本就是最后一次崩溃那份。
    ///   取不到修改时间时回落 `Date.distantPast`（即当作最旧，不会被误选为最新）。
    /// - 只扫一层（`.skipsSubdirectoryDescendants`）并跳过子目录（`hasDirectoryPath == false`），
    ///   避免把里面的子目录也当成报告文件。
    private static func copyGameLogs(instance: MinecraftInstance, report: URL) {
        let logsURL = instance.runningDirectory.appendingPathComponent("logs")
        try? FileManager.default.copyItem(at: logsURL.appendingPathComponent("latest.log"), to: report.appendingPathComponent("latest.log"))
        try? FileManager.default.copyItem(at: logsURL.appendingPathComponent("debug.log"), to: report.appendingPathComponent("debug.log"))
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: instance.runningDirectory.appendingPathComponent("crash-reports"), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            
            let latestReport = files
                .filter { $0.hasDirectoryPath == false }
                .max(by: {
                    let date0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    let date1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    return date0 < date1
                })
            
            if let latestFile = latestReport {
                try FileManager.default.copyItem(at: latestFile, to: report.appendingPathComponent(latestFile.lastPathComponent))
            }
        } catch {
            err("无法复制 crash-report: \(error.localizedDescription)")
        }
    }
}
