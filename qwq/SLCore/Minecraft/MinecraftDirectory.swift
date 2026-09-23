//
//  MinecraftDirectory.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/5/30.
//
//  ── 本文件职责 ─────────────────────────────────────────────
//  1. `MinecraftDirectory`：一个「游戏根目录」（即 .minecraft 那一层）的值模型 ——
//     它只描述**在哪里**（rootURL）与**叫什么**（name），并派生三个标准子目录路径；
//  2. `InstanceInfo`：该目录下单个版本实例的**不可变快照**，供 UI 列表消费。
//
//  ── 三个必须知道的设计事实 ─────────────────────────────────
//  **① `instances` 不落盘。** `CodingKeys` 只声明了 `id` / `rootURL` / `name`，
//    所以 `instances` 是纯运行期字段，每次启动都要重新扫描版本目录来重建。
//    想「读实例列表」请走 `Core/Minecraft/Module/MinecraftRepository`（异步、无副作用），
//    不要直接读这个属性当作真值。
//
//  **② 判等只看路径。** `==` 与 `hash` 都只用 `rootURL`：同一个物理目录无论被包装几次
//    都算同一个；反之 `id`（每次 init 新生成的 UUID）**不参与判等**，
//    所以它不适合当作跨启动的稳定标识 —— `MinecraftInstanceInfo.id` 用的是路径，那个才是。
//
//  **③ `loadInnerInstances` 有副作用且当前无调用方。** 它会真的去创建
//    `MinecraftInstance` 并触发全局刷新（见 `MinecraftModule.swift:6` 与
//    `MinecraftRepository.swift:20` 的说明）。模块化收口后实例扫描已改走 Repository
//    协议（异步 + `Task.detached`，跨线程只传 Sendable 的 `MinecraftInstanceInfo`），
//    本方法属遗留路径，保留但**不要在新代码里调用**。
//

import Foundation
import Combine

/// 一个游戏根目录。同时作为版本实例的容器。
public class MinecraftDirectory: Codable, Identifiable, Hashable {
    /// 默认目录：`~/Library/Application Support/minecraft`。
    /// 注意 `AppSettings.currentMinecraftDirectory` 目前恒等于它（该字段全库无写入点），
    /// 也就是说「切换游戏目录」这条路径实际上还没接通 —— 见 `MinecraftRepository.swift:40-41`。
    public static let `default`: MinecraftDirectory = .init(rootURL: URL.applicationSupportDirectory.appendingPathComponent("minecraft"), name: "默认文件夹")
    
    /// 运行期身份（每次构造重新生成，不持久化也不参与判等 —— 见文件头「设计事实 ②」）。
    public var id: UUID
    /// 根目录绝对路径。**这是本类型的真正标识**。
    public let rootURL: URL
    /// 用户可见的目录名。
    public var name: String
    /// 运行时扫出来的实例列表，不落盘（见文件头「设计事实 ①」）。
    public var instances: [InstanceInfo] = []
    
    /// 按根路径判等 —— 同一个物理目录视为同一个对象。
    public func hash(into hasher: inout Hasher) {
        hasher.combine(rootURL)
    }
    
    /// `<root>/versions`：每个子目录是一个版本实例。
    public var versionsURL: URL {
        rootURL.appendingPathComponent("versions")
    }
    
    /// `<root>/assets`：资源与资源索引。注意资源实际落在 `assets/objects/<hash前2位>/<hash>`。
    public var assetsURL: URL {
        rootURL.appendingPathComponent("assets")
    }
    
    /// `<root>/libraries`：依赖库（含各平台的 natives 解压产物）。
    public var librariesURL: URL {
        rootURL.appendingPathComponent("libraries")
    }
    
    public init(rootURL: URL, name: String) {
        self.id = .init()
        self.rootURL = rootURL
        self.name = name
    }
    
    /// 只持久化 id / rootURL / name —— `instances` 刻意排除（见文件头「设计事实 ①」）。
    enum CodingKeys: CodingKey {
        case id
        case rootURL
        case name
    }
    
    /// 与 `hash` 保持一致：只比根路径。
    public static func == (lhs: MinecraftDirectory, rhs: MinecraftDirectory) -> Bool {
        lhs.rootURL == rhs.rootURL
    }
    
    /// 扫描 `versions/` 下的子目录，逐个尝试构建实例并汇总到 `instances`。
    ///
    /// **有副作用、且是遗留路径** —— 见文件头「设计事实 ③」，新代码请改用
    /// `Core/Minecraft/Module/MinecraftRepository.instances()`。
    ///
    /// 线程纪律（万一要复活它，这几条必须保持）：
    /// - `removeAll()` 在**调用线程**立刻执行，随后的目录遍历在 `Task` 里进行；
    /// - 中途每收集到一个实例，都单独回到主队列 append（而不是全部扫完再一次性提交），
    ///   所以 UI 上会看到列表**逐个长出来**；
    /// - 全部结束后才回主队列调 callback 并发一次 `objectWillChange`，触发界面刷新；
    /// - `[weak self]` + `guard let self`：扫描期间目录对象可能已被释放，避免悬挂引用。
    ///
    /// 单个版本目录构建失败（`create` 返回 nil）会**静默跳过**，不中断整轮扫描 ——
    /// 一个损坏的版本不该导致其它版本也看不见。
    /// 只有「读 versions 目录本身失败」才打错误日志（此时列表会是空的）。
    public func loadInnerInstances(callback: (([InstanceInfo]) -> Void)? = nil) {
        instances.removeAll()
        Task { [weak self] in
            guard let self else { return }
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: versionsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                let instanceDirectories = contents.filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                for instanceDirectory in instanceDirectories {
                    if let instance = MinecraftInstance.create(self, instanceDirectory) {
                        let info = InstanceInfo(
                            minecraftDirectory: self,
                            icon: instance.getIconName(),
                            name: instance.name,
                            version: instance.version,
                            runningDirectory: instanceDirectory,
                            brand: instance.clientBrand
                        )
                        DispatchQueue.main.async {
                            self.instances.append(info)
                        }
                    }
                }
                DispatchQueue.main.async {
                    callback?(self.instances)
                    DataManager.shared.objectWillChange.send()
                }
            } catch {
                err("读取版本目录失败: \(error.localizedDescription)")
            }
        }
    }
}

/// 版本实例的**不可变快照**，专供界面列表消费。
///
/// 为什么要有这层：`MinecraftInstance` 是引用类型且持有文件句柄/配置等可变状态，
/// 不适合跨线程传递。这里抽成值类型后可以安全地跨 actor 传递
/// （`MinecraftInstanceInfo` 是它的模块化版本，见 `Core/Minecraft/Module/`）。
///
/// 字段来源：全部取自 `MinecraftInstance` 的只读属性，其中
/// `runningDirectory` 是实例所在的那层版本目录（不是游戏根目录），
/// `brand` 是客户端品牌（原版/Fabric/… ，定义在 `MinecraftInstanceConfig.swift:94`）。
public struct InstanceInfo: Identifiable, Hashable {
    /// 每次构造生成新 UUID —— **不要**用它做跨启动的稳定标识，用 `runningDirectory` 的路径。
    public let id: UUID = .init()
    /// 该实例所属的游戏根目录（反向引用，用于拼各类资源路径）。
    public let minecraftDirectory: MinecraftDirectory
    /// 列表图标资源名，来自 `MinecraftInstance.getIconName()`。
    public let icon: String
    /// 实例显示名（版本目录名）。
    public let name: String
    /// 版本标识（`MinecraftVersion`，含排序用的发布时间）。
    public let version: MinecraftVersion
    /// 版本目录本身（`<root>/versions/<name>`）—— 它才是实例的稳定标识。
    public let runningDirectory: URL
    /// 客户端品牌（原版 / Fabric / Forge / …）。
    public let brand: ClientBrand
}
