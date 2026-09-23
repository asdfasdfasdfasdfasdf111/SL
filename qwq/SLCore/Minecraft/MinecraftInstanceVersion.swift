//
//  MinecraftInstanceVersion.swift
//  SL启动器
//
//  实例的版本 / 清单辅助职责（从 MinecraftInstance.swift 逐字搬移，逻辑与文案未变）：
//  - getClientBrand：按清单文本关键字判定加载器品牌
//  - loadManifest：读取并解析客户端清单，同时记录品牌
//  - detectVersion：从客户端 jar 的 version.json 探测版本，失败回退清单 id
//  - getIconName：实例图标名（原版取版本图标，加载器取品牌图标）
//
//  访问级别：loadManifest / detectVersion 由 private 放宽为 internal（主文件 setup() 与 launch() 调用）；
//  getClientBrand 仅本文件 loadManifest 调用，保持 private static。对外接口零变化。
//
//  ── 一条容易踩的约束：这两步的失败都不会抛错 ───────────────────
//  `loadManifest()` 返回 Bool（失败已打过日志），`detectVersion()` 连返回值都没有，
//  失败时它会**自己落到一个兜底值**（用清单 id 当版本名）。
//  也就是说调用方**看不出「版本是探测来的还是兜底来的」** ——
//  用户在界面上看到版本号，不代表 jar 里的 version.json 真的读到了。
//

import Foundation
import SwiftyJSON
import ZIPFoundation

extension MinecraftInstance {
    /// 按清单原文里的关键字猜客户端品牌。
    ///
    /// 判定顺序**不能调换**：`neoforged` → `fabric` → `forge`。原因是
    /// 这几家的清单文本会互相包含 —— NeoForge 的清单里同样出现 `forge` 字样，
    /// 先判 `forge` 会把 NeoForge 误判成 Forge。同理 Fabric 与 Forge 混装时也算 Fabric。
    ///
    /// 判定依据是**整个清单文件的文本**（不是解析后的结构），所以是「尽力而为」的启发式：
    /// 只要文本里出现对应子串就算。返回 `.vanilla` 代表「三个关键字都没有」，
    /// 而不是「确认是原版」。
    private static func getClientBrand(_ manifestString: String) -> ClientBrand {
        if manifestString.contains("neoforged") {
            return .neoforge
        } else if manifestString.contains("fabric") {
            return .fabric
        } else if manifestString.contains("forge") {
            return .forge
        } else {
            return .vanilla
        }
    }

    /// 读取并解析本实例的客户端清单（`<版本目录>/<版本目录名>.json`），
    /// 同时把品牌写进 `clientBrand`。
    ///
    /// - Returns: 成功 `true`；任何一步失败 `false`（并已打错误日志），**不抛错**。
    ///
    /// 三个失败点：
    /// 1. 文件打不开 / 读不出来 → `false`；
    /// 2. 文件能读但内容为空（`readToEnd()` 返回 nil）→ 专门判了一次并打日志。
    ///    这里用 `guard let` 而不是强解包：空文件时强解包会**直接崩**（修过的缺陷）；
    /// 3. `ClientManifest.parse` 返回 nil（清单损坏 / 父版本缺失 / 循环继承）→ `false`。
    ///
    /// 顺序细节：**品牌先于清单解析**。因为品牌只看原始文本，即使后面 `parse` 失败
    /// （例如 Fabric 版的父版本没装），`clientBrand` 也已经被正确写入了 —— 界面上仍能显示对。
    ///
    /// `@discardableResult`：`setup()` 里只想知道失败与否，不关心返回值时可以直接忽略。
    @discardableResult
    func loadManifest() -> Bool {
        do {
            let manifestPath = runningDirectory.appendingPathComponent(runningDirectory.lastPathComponent + ".json")
            
            // readToEnd 可能返回 nil（空/损坏清单文件），强解包会崩；失败按读取失败处理
            let fh = try FileHandle(forReadingFrom: manifestPath)
            defer { try? fh.close() }
            guard let data = try fh.readToEnd() else {
                err("无法读取 \(manifestPath.lastPathComponent): 文件为空")
                return false
            }
            self.clientBrand = MinecraftInstance.getClientBrand(String(data: data, encoding: .utf8) ?? "")
            
            guard let manifest = try ClientManifest.parse(
                url: manifestPath, minecraftDirectory: minecraftDirectory
            ) else { return false }
            self.manifest = manifest
        } catch {
            err("无法加载客户端清单: \(error.localizedDescription)")
            return false
        }
        
        return true
    }

    /// 从客户端 jar 里的 `version.json` 探测真实版本号。
    ///
    /// **重入保护**：已经探测出 `version` 就直接返回 —— 本方法的兜底分支会写 `version`，
    /// 没有这道守卫的话「探测失败 → 写兜底 → 再调用一次」会反复覆盖。
    ///
    /// 两个数据源与优先级：
    /// 1. 首选 jar 内 `version.json` 的 `"id"`（这是**实际安装的这个 jar** 的真实版本，
    ///    在与「目录名被改过」或「整合包覆盖了 jar」的情况下比清单更可信）；
    /// 2. 拿不到就回落到清单的 `id`，只打一条错误日志。
    ///
    /// 注意 `version.json` 不存在时会抛 `MyLocalizedError` 走 catch ——
    /// 也就是说**走兜底路径不是异常，而是设计好的正常分支**（很多整合包会删掉这个文件）。
    func detectVersion() {
        guard version == nil else {
            return
        }
        do {
            let archive = try Archive(url: runningDirectory.appendingPathComponent("\(name).jar"), accessMode: .read)
            guard let entry = archive["version.json"] else {
                throw MyLocalizedError(reason: "version.json 不存在")
            }
            
            var data = Data()
            _ = try archive.extract(entry, consumer: { (chunk) in
                data.append(chunk)
            })
            
            let version = MinecraftVersion(displayName: try JSON(data: data)["id"].stringValue)
            self.version = version
        } catch {
            err("无法检测版本: \(error.localizedDescription)，正在使用清单版本")
            self.version = .init(displayName: manifest.id)
        }
    }

    /// 实例在列表里用的图标资源名。
    ///
    /// 原版按版本类型（正式版/快照/远古/愚人节）取不同图标；
    /// 装过加载器的一律用品牌图标（`Fabric` / `Forge` / `Neoforge` + `Icon`）——
    /// 靠 `rawValue.capitalized` 拼出资源名，所以**枚举 case 名改了这里会静默取不到图**。
    public func getIconName() -> String {
        if self.clientBrand == .vanilla {
            return self.version.getIconName()
        }
        return "\(self.clientBrand.rawValue.capitalized)Icon"
    }
}
