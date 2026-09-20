//
//  LaunchFixPreflight.swift
//  启动用例层适配器：把 `LaunchFix.perform` 适配为 `LaunchPreflight` 及其四类子协议
//
//  本文件只做适配，不重写任何校验/下载算法：
//  所有 sha1 校验复用 `FileChecker`（与 `LaunchFix.fileIsValid` 同一原语），
//  所有缺失项补齐复用 `LaunchFix.perform`（唯一实现），
//  natives 复用 `MinecraftInstaller.ensureNatives`（与 LaunchFix 第 5 步同一调用）。
//
//  MARK: - 职责映射表（LaunchFix.perform 行号 → 本文件的实现）
//
//  | LaunchFix.perform 步骤                              | 本文件对应实现                     | 委托方式 |
//  |----------------------------------------------------|-----------------------------------|---------|
//  | （无对应步骤：LaunchFix 不校验/补客户端 JAR）        | `LaunchFixClientVerifier`          | 无委托目标，只做只读暴露 |
//  | 1) 缺失支持库分析（libraries + sha1 比对）           | `LaunchFixLibraryVerifier`         | 只读扫描 → 缺失时委托 `LaunchFix.perform` |
//  | 2) 资源索引缺失/损坏判定                               | `LaunchFixAssetVerifier`           | 同上 |
//  | 3) 缺失资源分析（objects 按 hash 比对）               | `LaunchFixAssetVerifier`           | 同上 |
//  | 4) 缺失项下载（MultiFileDownloader）                  | `LaunchFixLibraryVerifier` / `LaunchFixAssetVerifier` 触发 | 委托 `LaunchFix.perform`（整段执行） |
//  | 5) natives 缺失 → 重新解压                            | `LaunchFixNativeInstaller`         | 直接调用 `MinecraftInstaller.ensureNatives` |
//  | 进度回调（libraries 0~0.5 / assets 0.5~1）            | 由 `LaunchFix.perform` 统一产生     | 原样透传，见下方「进度契约」 |
//
//  MARK: - 进度契约（与 DefaultLaunchPreflight 的差异，合并阶段必须统一）
//
//  `DefaultLaunchPreflight` 假设四个子校验器各自输出 0~1 的**局部**进度，
//  再由编排层映射到 0.5 / 0.5 两个区间。
//  但 `LaunchFix.perform` 的 onProgress 已经是**全局** 0~1（库占前段、资源占后段），
//  若再套一层区间映射会把进度压缩一半并出现回跳。
//  因此本适配器**不做区间重映射**，progress 原样透传，且只读扫描阶段不推进度
//  （唯一进度来源是 LaunchFix.perform）。
//
//  MARK: - 触发语义（与桥接层现状的差异）
//
//  桥接层 `pclLaunchInternal` 每次启动都**无条件**调用一次 `LaunchFix.perform`。
//  本适配器改为「只读扫描发现缺失才触发」，等价性论证：
//  `LaunchFix.perform` 在「无缺失」时的唯一副作用是末尾的 `ensureNatives`，
//  而该步骤已由 `LaunchFixNativeInstaller` 单独覆盖（同一调用），
//  故无缺失时不触发补齐不改变最终文件状态。
//  另：`LaunchFix.perform` 内部自带「先补索引、再补 objects」的顺序，无需外层重排。
//
//  MARK: - 关于 skipResourceCheck（重要，勿照搬 DefaultLaunchPreflight）
//
//  `DefaultLaunchPreflight.prepare` 在 `request.skipResourceCheck == true` 时直接返回。
//  本适配器**不采用**该早退：`LaunchRequest.skipResourceCheck` 来源于
//  `LaunchOptions.skipResourceCheck`，而桥接层把它恒置为 true（用于跳过
//  `MinecraftInstance.launch` 内 `config.skipResourcesCheck` 分支的
//  `MinecraftInstaller.createCompleteTask`），与「是否执行 LaunchFix」无关。
//  照搬早退会直接跳过启动前补齐，属于行为回退。
//  该字段语义歧义需在合并阶段改名或拆分（见 DUAL_FLOW.md 风险点 R4）。
//

import Foundation

// MARK: - 委托动作

/// 补齐动作：发现缺失时唯一的执行路径，实现方固定为 `LaunchFix.perform`。
/// 之所以是「整段委托」而不是分段委托：`LaunchFix.perform` 当前未暴露分段入口，
/// 分段会要求重写其内部算法（本阶段禁止）。
public typealias LaunchFixRepairAction = (@escaping (Double) -> Void) async throws -> Void

// MARK: - 上下文构造

/// 从实例 / 清单抽取 `LaunchPreflightContext` 值快照。
///
/// `LaunchPreflightContext` 刻意不持有 `MinecraftInstance`（非 Sendable 引用类型），
/// 故需要在这里做一次读取式抽取；读取路径与 `LaunchFix.perform` 完全同源，不含新判定规则。
enum LaunchFixPreflightContextBuilder {

    /// - Parameters:
    ///   - instance: 已解析的实例（manifest 已合并 inheritsFrom）
    ///   - request: 启动请求（当前仅用于日志与后续扩展，不参与判定）
    static func make(instance: MinecraftInstance, request: LaunchRequest) throws -> LaunchPreflightContext {
        guard let manifest = instance.manifest else {
            throw LaunchError.fileVerificationFailed(reason: "实例缺少清单文件，无法执行启动前校验：\(instance.name)")
        }
        guard let version = instance.version else {
            throw LaunchError.fileVerificationFailed(reason: "实例版本未设置，无法执行启动前校验：\(instance.name)")
        }

        let directory = instance.minecraftDirectory

        // 支持库：与 LaunchFix.perform 第 1 步取值一致（getNeededLibraries 且仅取有 artifact 的项）
        let libraries: [LibraryArtifact] = manifest.getNeededLibraries().compactMap { library in
            guard let artifact = library.artifact else { return nil }
            return LibraryArtifact(path: artifact.path, sha1: artifact.sha1)
        }

        // 资源索引引用 + 本地索引已落地时的对象清单（与 LaunchFix.perform 第 2 步同一读取与解析路径）
        var assetIndexReference: AssetIndexReference?
        var assetObjects: [AssetObject] = []
        if let assetIndex = manifest.assetIndex {
            assetIndexReference = AssetIndexReference(id: assetIndex.id, sha1: assetIndex.sha1, url: assetIndex.url)
            let indexPath = directory.assetsURL
                .appendingPathComponent("indexes", isDirectory: true)
                .appendingPathComponent("\(assetIndex.id).json")
            if FileChecker(hash: assetIndex.sha1).check(indexPath) == nil,
               let data = try? Data(contentsOf: indexPath),
               let index = try? AssetIndex.parse(data) {
                assetObjects = index.objects.map { AssetObject(hash: $0.hash) }
            }
        }

        return LaunchPreflightContext(
            version: version.displayName,
            runningDirectory: instance.runningDirectory,
            clientJAR: instance.runningDirectory.appendingPathComponent("\(instance.name).jar"),
            clientSHA1: manifest.clientDownload?.sha1,
            librariesRoot: directory.librariesURL,
            libraries: libraries,
            assetsRoot: directory.assetsURL,
            assetIndex: assetIndexReference,
            assetObjects: assetObjects,
            nativesDirectory: instance.runningDirectory.appendingPathComponent("natives")
        )
    }
}

// MARK: - client 段

/// 客户端 JAR 校验。**LaunchFix 没有对应步骤**（既不校验也不下载 client JAR），
/// 故这里没有可委托的实现，只做只读校验并显式抛出，把「桥接流程不校验 client JAR」这一缺口暴露出来。
///
/// 行为差异提示：桥接层现状对缺失/损坏的 client JAR **放行**，游戏在启动后才崩；
/// 本校验器一旦接线会把它变成启动前失败。接线前必须由产品确认（见 DUAL_FLOW.md 风险点 R6）。
public struct LaunchFixClientVerifier: ClientFileVerifier, @unchecked Sendable {

    public init() {}

    public func verify(_ context: LaunchPreflightContext) async throws {
        guard let reason = FileChecker(hash: context.clientSHA1).check(context.clientJAR) else { return }
        throw LaunchError.fileVerificationFailed(
            reason: "客户端 JAR 校验失败（\(context.clientJAR.lastPathComponent)）：\(reason)"
        )
    }
}

// MARK: - library 段

/// 支持库分段校验：对应 `LaunchFix.perform` 第 1 步（缺失分析）与第 4 步（下载）。
/// 只读扫描复用与 LaunchFix 完全相同的判定式，缺失时整段委托 `LaunchFix.perform`。
public struct LaunchFixLibraryVerifier: LibraryFileVerifier, @unchecked Sendable {

    private let repair: LaunchFixRepairAction

    public init(repair: @escaping LaunchFixRepairAction) {
        self.repair = repair
    }

    public func verify(_ context: LaunchPreflightContext, progress: LaunchProgressHandler?) async throws {
        guard !context.libraries.isEmpty else { return }

        var missing = 0
        for library in context.libraries {
            let destination = context.librariesRoot.appendingPathComponent(library.path)
            if FileChecker(hash: library.sha1).check(destination) != nil { missing += 1 }
        }
        guard missing > 0 else { return }

        log("[LaunchPreflight] 支持库缺失或损坏 \(missing)/\(context.libraries.count) 项，委托 LaunchFix 补齐")
        try await repair { value in progress?(value) }
    }
}

// MARK: - asset 段

/// 资源分段校验：对应 `LaunchFix.perform` 第 2 步（索引）与第 3 步（objects）。
/// 索引缺失时 `context.assetObjects` 为空，此时按「索引待补」触发补齐，
/// 由 LaunchFix 内部负责「先下索引、再下 objects」的顺序，本适配器不重排。
public struct LaunchFixAssetVerifier: AssetFileVerifier, @unchecked Sendable {

    private let repair: LaunchFixRepairAction

    public init(repair: @escaping LaunchFixRepairAction) {
        self.repair = repair
    }

    public func verify(_ context: LaunchPreflightContext, progress: LaunchProgressHandler?) async throws {
        var indexMissing = false
        if let indexFile = context.assetIndexFileURL,
           let reference = context.assetIndex,
           FileChecker(hash: reference.sha1).check(indexFile) != nil {
            indexMissing = true
        }

        var missingObjects = 0
        for object in context.assetObjects {
            let destination = objectHashDestination(object.hash, root: context.assetsRoot)
            if FileChecker(hash: object.hash).check(destination) != nil { missingObjects += 1 }
        }

        guard indexMissing || missingObjects > 0 else { return }

        let detail = indexMissing
            ? "资源索引缺失（objects 尚未解析，\(context.assetObjects.count) 项待核对）"
            : "资源对象缺失或损坏 \(missingObjects)/\(context.assetObjects.count) 项"
        log("[LaunchPreflight] \(detail)，委托 LaunchFix 补齐")
        try await repair { value in progress?(value) }
    }

    /// 与 `AssetIndex.Object.appendTo` 同一存储路径规则（objects/<hash 前两位>/<hash>）
    private func objectHashDestination(_ hash: String, root: URL) -> URL {
        root.appendingPathComponent("objects")
            .appendingPathComponent(String(hash.prefix(2)))
            .appendingPathComponent(hash)
    }
}

// MARK: - natives 段

/// natives 段：直接委托 `MinecraftInstaller.ensureNatives`，与 `LaunchFix.perform` 第 5 步同一调用，
/// 无独立算法（该函数自身已实现「目录内已有 dylib/jnilib 则跳过」的幂等语义）。
public struct LaunchFixNativeInstaller: NativeInstaller, @unchecked Sendable {

    private let instance: MinecraftInstance

    public init(instance: MinecraftInstance) {
        self.instance = instance
    }

    public func install(_ context: LaunchPreflightContext) async throws {
        do {
            try MinecraftInstaller.ensureNatives(instance)
        } catch {
            throw LaunchError.fileVerificationFailed(reason: "natives 重新解压失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 总入口

/// `LaunchPreflight` 的 LaunchFix 适配实现。
///
/// 实例解析由调用方注入：实例创建（`MinecraftInstance.create`）属于服务层职责，
/// 本适配器只负责文件校验与补齐，避免与桥接层重复实现「建目录 + 建实例」。
public struct LaunchFixPreflight: LaunchPreflight, @unchecked Sendable {

    /// 从启动请求解析实例；实现方通常包 `MinecraftInstance.create(minecraftDirectory, version)`。
    public typealias InstanceResolver = (LaunchRequest) throws -> MinecraftInstance

    private let resolveInstance: InstanceResolver
    private let progress: LaunchProgressHandler?

    public init(instanceResolver: @escaping InstanceResolver, progress: LaunchProgressHandler? = nil) {
        self.resolveInstance = instanceResolver
        self.progress = progress
    }

    public func prepare(_ request: LaunchRequest) async throws {
        let instance = try resolveInstance(request)
        let context = try LaunchFixPreflightContextBuilder.make(instance: instance, request: request)

        // 顺序与 LaunchFix.perform 一致：client → libraries → assets → natives。
        // 其中 client 段 LaunchFix 未覆盖（见 LaunchFixClientVerifier 注释）。
        try await LaunchFixClientVerifier().verify(context)

        // 同一次 prepare 内复用同一个补齐动作：首次补齐后缺失项已被填平，
        // 后续分段不会重复触发完整 perform（顺序天然保证至多一次实际下载）。
        let repair: LaunchFixRepairAction = { onProgress in
            try await LaunchFix.perform(instance: instance, onProgress: onProgress)
        }

        try await LaunchFixLibraryVerifier(repair: repair).verify(context, progress: progress)
        try await LaunchFixAssetVerifier(repair: repair).verify(context, progress: progress)
        try await LaunchFixNativeInstaller(instance: instance).install(context)

        progress?(1.0)
    }
}
