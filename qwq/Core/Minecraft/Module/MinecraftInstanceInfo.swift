//
//  MinecraftInstanceInfo.swift
//  模块化拆分：Minecraft 模块的只读实例快照
//
//  `MinecraftInstance`（`qwq/SLCore/Minecraft/MinecraftInstance.swift`）是启动核心：
//  构造即产生副作用（解析清单、自动选 Java、写回 `.SL.json`），因此本阶段只做只读抽象，
//  不改动它，也不在本模型里持有它。
//
//  本模型只抽取**真实存在的属性**，把非 Sendable 的 SLCore 类型镜像为自身枚举，
//  从而可以跨任务传递（与 `JavaInstallation` 镜像 `Architecture` 的做法一致）。
//
//  刻意未建模的字段：
//  - 「最后启动时间」：`MinecraftInstance` 与 `.SL.json` 均**没有**该字段，
//    全库也没有任何写入点。不臆造字段，改用文件系统时间需要先定义语义（是启动时间、还是清单修改时间），
//    该定义属新增能力，留待确认后再加。
//  - `isUsingRosetta`：运行期瞬时状态（由启动时的 JVM 架构判定），不是实例的持久属性。
//  - `config` / `process`：分别属启动参数与进程管理职责，由启动模块持有。
//

import Foundation

// MARK: - 加载器

/// 实例的加载器类型，镜像 `ClientBrand`（`MinecraftInstance.clientBrand`）。
///
/// 单独建模的原因：`ClientBrand` 是 SLCore 的公开非 frozen 枚举，未声明 `Sendable`，
/// 不能作为本模块值类型快照的字段。
enum MinecraftLoaderKind: String, Sendable, Hashable, CaseIterable {
    case vanilla
    case fabric
    case quilt
    case forge
    case neoforge

    /// 由 `ClientBrand` 直接映射。取值一一对应。
    init(_ brand: ClientBrand) {
        self = MinecraftLoaderKind(rawValue: brand.rawValue) ?? .vanilla
    }

    /// 由清单文本判定加载器。
    ///
    /// 判定顺序与关键字与 `MinecraftInstance.getClientBrand(_:)` 完全一致
    /// （neoforged → fabric → forge → vanilla）。该方法**无法识别 quilt**，
    /// 因此文件扫描路径不会产出 `.quilt`；该分支只可能来自 `ClientBrand` 转换。
    init(manifestText: String) {
        if manifestText.contains("neoforged") {
            self = .neoforge
        } else if manifestText.contains("fabric") {
            self = .fabric
        } else if manifestText.contains("forge") {
            self = .forge
        } else {
            self = .vanilla
        }
    }

    /// 展示名。与 `ClientBrand.getName()` 一致（NeoForge 单独处理，其余首字母大写）。
    var displayName: String {
        self == .neoforge ? "NeoForge" : rawValue.capitalized
    }
}

// MARK: - 版本类型

/// 实例的版本类型，镜像 `VersionType`（`MinecraftVersion.type`）。
///
/// 取值字符串与 `VersionType` 的 rawValue 完全一致，可直接互转。
enum MinecraftVersionKind: String, Sendable, Hashable, CaseIterable {
    case release
    case snapshot
    case prerelease = "pre-release"
    case rc
    case alpha = "old_alpha"
    case beta = "old_beta"
    case aprilFool = "april_fool"
    case pending

    /// 由 `VersionType` 直接映射。
    init(_ type: VersionType) {
        self = MinecraftVersionKind(rawValue: type.rawValue) ?? .release
    }

    /// 由清单 JSON 的 `type` 字段构造。
    /// 取值无法识别时回落 `.release`，与 `VersionType.parse` 的回落行为一致。
    init(rawVersionType: String) {
        self = MinecraftVersionKind(rawValue: rawVersionType) ?? .release
    }
}

// MARK: - 实例快照

/// 实例的只读快照。可跨线程传递，不含任何 SLCore 引用类型。
struct MinecraftInstanceInfo: Sendable, Hashable, Identifiable {

    /// 以版本目录的绝对路径作为标识：同一目录无论从哪条路径发现，都合并为同一条记录。
    var id: String { runningDirectory.standardizedFileURL.path }

    /// 实例名，取版本目录末段（对应 `MinecraftInstance.name`）
    let name: String

    /// 版本目录（对应 `MinecraftInstance.runningDirectory`）
    let runningDirectory: URL

    /// 所在游戏根目录（对应 `MinecraftInstance.minecraftDirectory.rootURL`）
    let minecraftRootDirectory: URL

    /// 版本名（对应 `MinecraftInstance.version.displayName`）；清单缺失时回落为实例名
    let versionName: String

    /// 版本类型（对应 `MinecraftInstance.version.type`）
    let versionKind: MinecraftVersionKind

    /// 加载器（对应 `MinecraftInstance.clientBrand`）
    let loader: MinecraftLoaderKind

    /// 清单声明的 Java 主版本（对应 `ClientManifest.javaVersion`）；未声明时为 nil。
    /// 与 `MinecraftInstance.resolveMinJavaVersion(manifest:version:)` 的取值口径一致。
    let manifestJavaVersion: Int?

    /// 版本目录内的客户端清单文件路径（`<name>/<name>.json`）
    var manifestPath: URL {
        runningDirectory.appendingPathComponent("\(name).json")
    }

    /// 实例配置文件路径（对应 `MinecraftInstance.configPath`）
    var configPath: URL {
        runningDirectory.appendingPathComponent(".SL.json")
    }
}

// MARK: - 由既有数据模型转换

extension MinecraftInstanceInfo {

    /// 由已构造的 `MinecraftInstance` 取快照。
    ///
    /// 供接线层（`LaunchCoordinator` 等已持有实例的位置）使用；`clientBrand` 为 nil 时
    /// 按 `getClientBrand` 的默认值 `.vanilla` 处理。
    init(_ instance: MinecraftInstance) {
        self.init(
            name: instance.name,
            runningDirectory: instance.runningDirectory,
            minecraftRootDirectory: instance.minecraftDirectory.rootURL,
            versionName: instance.version?.displayName ?? instance.name,
            versionKind: MinecraftVersionKind(instance.version?.type ?? .release),
            loader: MinecraftLoaderKind(instance.clientBrand ?? .vanilla),
            manifestJavaVersion: instance.manifest?.javaVersion
        )
    }
}
