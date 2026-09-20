//
//  MinecraftRepository.swift
//  模块化拆分：Minecraft 实例仓储协议与只读扫描实现
//
//  只读抽象：本文件**不构造** `MinecraftInstance`。
//  `MinecraftInstance.create` 会解析清单、自动选择 Java 并写回 `.PCL_Mac.json`（有副作用），
//  只读查询不应触发实例初始化，因此默认实现直接读版本目录与清单 JSON。
//
//  扫描结果的字段可得性低于 `MinecraftInstanceInfo(_:)`（后者取自已初始化的实例）：
//  例如清单缺失时 `versionName` 回落为目录名。转换入口见 `MinecraftInstanceInfo.swift`。
//

import Foundation

// MARK: - 仓储协议

/// 实例数据的唯一出入口。
///
/// 上层不再直接遍历 `MinecraftDirectory.versionsURL` 或调用
/// `MinecraftDirectory.loadInnerInstances`（后者会创建实例并产生副作用），统一经由此协议获取。
protocol MinecraftRepository: Sendable {

    /// 当前已知的全部实例快照。按实例名排序，保证同一批文件的输出顺序稳定。
    func instances() async -> [MinecraftInstanceInfo]

    /// 按实例标识取单个快照。
    /// - Parameter id: `MinecraftInstanceInfo.id`，即版本目录的绝对路径（传入非标准化的路径亦可）。
    func inspect(id: String) async -> MinecraftInstanceInfo?
}

// MARK: - 默认实现

/// 扫描游戏根目录下 `versions/*` 并解析清单 JSON 产出快照。
///
/// 清单解析口径对齐既有实现：
/// - 版本名与类型取清单的 `id` / `type` 字段（对应 `MinecraftVersion.displayName` / `ClientManifest.type`）；
/// - 加载器按清单文本关键字判定，规则与 `MinecraftInstance.getClientBrand(_:)` 一致；
/// - Java 需求取清单的 `javaVersion` 字段（对应 `ClientManifest.javaVersion`）。
///
/// 根目录来源：显式传入；未传入时取 `AppSettings.currentMinecraftDirectory`（该字段当前恒为
/// `MinecraftDirectory.default`，全库无写入点）。
struct DirectoryScanningMinecraftRepository: MinecraftRepository {

    /// 显式指定的根目录。为空表示运行时从 `AppSettings` 解析。
    private let explicitRoots: [URL]

    init(roots: [URL]) {
        self.explicitRoots = roots
    }

    init() {
        self.explicitRoots = []
    }

    func instances() async -> [MinecraftInstanceInfo] {
        let roots = await resolveRoots()
        guard !roots.isEmpty else { return [] }
        // 目录列举与清单读取是同步阻塞 IO，放到 utility 优先级的 detached task，
        // 跨线程只传递 Sendable 的 MinecraftInstanceInfo。
        return await Task.detached(priority: .utility) { () -> [MinecraftInstanceInfo] in
            roots.flatMap(Self.scan(root:))
        }.value
    }

    func inspect(id: String) async -> MinecraftInstanceInfo? {
        let target = URL(fileURLWithPath: id).standardizedFileURL.path
        let all = await instances()
        return all.first { $0.runningDirectory.standardizedFileURL.path == target }
    }

    // MARK: - 根目录解析

    private func resolveRoots() async -> [URL] {
        if !explicitRoots.isEmpty { return explicitRoots }
        // `AppSettings` 是 UI 层可变状态，只在主线程读取。
        let root = await MainActor.run { AppSettings.shared.currentMinecraftDirectory?.rootURL }
        return root.map { [$0] } ?? []
    }

    // MARK: - 目录扫描

    private static func scan(root: URL) -> [MinecraftInstanceInfo] {
        let versionsURL = root.appendingPathComponent("versions", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { snapshot(instanceDirectory: $0, root: root) }
    }

    private static func snapshot(instanceDirectory: URL, root: URL) -> MinecraftInstanceInfo {
        let name = instanceDirectory.lastPathComponent
        let manifest = parseManifest(at: instanceDirectory.appendingPathComponent("\(name).json"))
        return MinecraftInstanceInfo(
            name: name,
            runningDirectory: instanceDirectory,
            minecraftRootDirectory: root,
            versionName: manifest.id ?? name,
            versionKind: MinecraftVersionKind(rawVersionType: manifest.type ?? MinecraftVersionKind.release.rawValue),
            loader: MinecraftLoaderKind(manifestText: manifest.text ?? ""),
            manifestJavaVersion: manifest.javaVersion
        )
    }

    // MARK: - 清单解析

    /// 清单中本模块关心的字段。
    private struct ParsedManifest {
        /// 清单 `id`（版本名）
        let id: String?
        /// 清单 `type`（版本类型）
        let type: String?
        /// 清单 `javaVersion`
        let javaVersion: Int?
        /// 清单原文，供加载器关键字判定使用
        let text: String?
    }

    /// 解析清单 JSON。文件不存在 / 内容损坏时各字段为 nil，由调用方回落。
    private static func parseManifest(at url: URL) -> ParsedManifest {
        guard let data = try? Data(contentsOf: url) else {
            return ParsedManifest(id: nil, type: nil, javaVersion: nil, text: nil)
        }
        let text = String(data: data, encoding: .utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 文本仍可参与加载器关键字判定（对应 getClientBrand 直接扫字符串的行为）
            return ParsedManifest(id: nil, type: nil, javaVersion: nil, text: text)
        }
        return ParsedManifest(
            id: json["id"] as? String,
            type: json["type"] as? String,
            javaVersion: json["javaVersion"] as? Int,
            text: text
        )
    }
}
