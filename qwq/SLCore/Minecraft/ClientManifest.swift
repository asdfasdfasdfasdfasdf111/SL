//
//  ClientManifest.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/5/20.
//
//  ── 本文件职责 ─────────────────────────────────────────────
//  客户端清单（`<版本目录>/<版本名>.json`）的模型与解析：一个版本要用什么 mainClass、
//  哪些依赖库、哪些 JVM/游戏参数、资源索引指向哪个文件。
//
//  它是**整个启动链的参数源头** —— 启动时 `SLLaunchBridge` → `MinecraftLauncher` →
//  `MinecraftLauncherArguments` 全部围绕这份对象工作。
//
//  ── 继承合并（inheritsFrom）是本文件最容易出错的地方 ────────────
//  加载器（Fabric/Forge）安装出的清单只写「自己那部分」，用 `inheritsFrom` 指向原版版本。
//  解析时必须把父清单**拉平进来**，否则 classpath 会缺库、参数会缺项。
//  三条铁律（都踩过）：
//  1. **父清单不存在 → 整体解析失败返回 nil**，绝不返回一份「只有一半」的清单；
//  2. **父清单存在但解析失败 → 向上抛错**，同样不返回半成品 ——
//     理由见 `parse` 里 `catch` 段的长注释（缺库的症状要到游戏里才以
//     `NoClassDefFoundError` 暴露，极难定位）；
//  3. **递归深度上限 16**，防 `inheritsFrom` 互相引用导致无限递归。
//
//  ── 与 `ArtifactVersionMapper` 的耦合 ────────────────────────
//  `deduplicateLibraries` 内部会调 `ArtifactVersionMapper.map(..., arch: .x64)` ——
//  即「借去重的机会顺手做一次架构映射」。这个耦合是隐式的，改动去重逻辑时别把它弄丢
//  （详见 `deduplicateLibraries` 的注释与 `ArtifactVersionMapper.swift` 文件头的顺序说明）。
//

import Foundation
import SwiftyJSON

/// 一个版本的客户端清单。
///
/// **注意是 class**：`merge` 会就地改写父清单并把它返回（省一次深拷贝），
/// 所以「解析出的清单」可能**就是**父版本那份对象，不是新的副本。
public class ClientManifest {
    /// 版本 id（多数情况下等于版本目录名）。
    public let id: String
    /// 入口类。加载器会覆盖它（见 `merge`），所以是 `var`。
    public var mainClass: String
    /// 清单里的 `"type"` 原文（release / snapshot / …），**字符串而非 `VersionType`** ——
    /// 这里只做透传，类型判定在 `MinecraftVersion` 那边。
    public let type: String
    /// 资源索引（内含该版本引用的全部资源对象）。个别版本没有这个字段。
    public let assetIndex: AssetIndex?
    /// 资源索引标识（如 `"1.21"`），用于拼资源目录名。
    public let assets: String
    /// 依赖库。解析期已按 `rules` 过滤过一遍；启动前还会被 `ArtifactVersionMapper` 改写。
    public var libraries: [Library]
    /// 新版参数结构（1.13+）。旧版清单没有这个字段，为 `nil`。
    public let arguments: Arguments?
    /// 旧版参数（1.12-）：一整行空格分隔的字符串。由 `getArguments()` 兜底转换。
    public var minecraftArguments: String?
    /// 清单声明的最低 Java 大版本（如 17 / 21）。`nil` 表示清单没写 ——
    /// 此时由调用方按版本号自行推断（见 `MinecraftInstance` 里的几个阈值常量）。
    public let javaVersion: Int?
    /// 客户端 jar 的下载信息。`nil` 表示这不是「可下载的原版版本」（例如加载器版本）。
    public let clientDownload: DownloadInfo?
    /// 客户端混淆映射表（给调试/反编译用）。启动流程不依赖它。
    public let clientMappingsDownload: DownloadInfo?

    /// 从已解析好的 JSON 构造。**private** —— 对外统一走 `parse(url:...)`，
    /// 因为那条路径才会处理 `inheritsFrom` 合并与各种合法性检查。
    private init?(json: JSON) {
        self.id = json["id"].stringValue
        self.mainClass = json["mainClass"].stringValue
        self.type = json["type"].stringValue
        self.assets = json["assets"].stringValue
        self.assetIndex = json["assetIndex"].exists() ? AssetIndex(json: json["assetIndex"]) : nil
        self.libraries = json["libraries"].arrayValue.compactMap(Library.init(json:)).filter { Rule.check($0.rules) }
        self.arguments = json["arguments"].exists() ? Arguments(json: json["arguments"]) : nil
        self.minecraftArguments = json["minecraftArguments"].string
        self.javaVersion = json["javaVersion"]["majorVersion"].int
        self.clientDownload = json["downloads"]["client"].exists() ? .init(json: json["downloads"]["client"]) : nil
        self.clientMappingsDownload = json["downloads"]["client_mappings"].exists() ? .init(json: json["downloads"]["client_mappings"]) : nil
    }

    /// 尝试解析与自动合并客户端清单，不会对实例进行操作
    /// - Parameter url: 清单路径
    /// - Parameter minecraftDirectory: 若需自动合并，该参数的值为实例所在的 minecraft 目录，否则为空
    /// - Parameter depth: 递归层数，**调用方一律不要传**（内部用于 `inheritsFrom` 自身递归时计数）。
    ///   超过 16 层会打日志并返回 nil，防止 A→B→A 这类循环继承把栈打爆。
    ///
    /// - Returns: 解析（并可能已合并父版本）后的清单；失败返回 `nil`。
    /// - Throws: JSON 层错误、父清单解析错误、文件读取错误。
    ///   **失败一律不返回「半成品清单」** —— 理由见下面 `catch` 段的长注释。
    ///
    /// 三种输入形态与各自的处理：
    /// 1. **旧版启动器装的 Fabric**（有 `loader`/`intermediary` 但没有 `id`）：
    ///    结构不兼容，打警告返回 nil。这是一个识别性的特判，不是通用规则。
    /// 2. **有 `inheritsFrom` 且传了 `minecraftDirectory`**：递归解析父版本再 `merge`。
    ///    父清单路径固定按 `<versionsURL>/<父id>/<父id>.json` 拼 —— 与目录名强绑定。
    /// 3. **其余情况**：直接构造。
    ///
    /// 注意：**没传 `minecraftDirectory` 时，`inheritsFrom` 会被静默忽略**
    /// （走到分支 3 直接返回自身），拿到的是缺父级内容的清单。
    /// 所有真实调用点都应传这个参数 —— 不传只适用于「确定没有 inheritsFrom」的场景。
    public static func parse(url: URL, minecraftDirectory: MinecraftDirectory? = nil, depth: Int = 0) throws -> ClientManifest? {
        guard depth < 16 else {
            err("inheritsFrom 递归深度超过 16，疑似循环引用")
            return nil
        }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let data = (try? fh.readToEnd()) ?? Data()
        let json = try JSON(data: data)
        
        if json["loader"].exists() && json["intermediary"].exists() && !json["id"].exists() { // 旧版启动器的 Fabric 安装逻辑
            warn("无法解析旧版启动器安装的 Fabric 版本: \(url.lastPathComponent)")
            return nil
        }
        
        if let inheritsFrom = json["inheritsFrom"].string,
           let minecraftDirectory = minecraftDirectory {
            let parentURL = minecraftDirectory.versionsURL.appendingPathComponent(inheritsFrom).appendingPathComponent("\(inheritsFrom).json")
            
            guard FileManager.default.fileExists(atPath: parentURL.path) else {
                err("\(url.path) 中有 inheritsFrom 字段，但其对应的 JSON 不存在")
                return nil
            }
            
            guard let manifest = ClientManifest(json: json) else { return nil }
            let parent: ClientManifest
            do {
                guard let parsedParent = try ClientManifest.parse(url: parentURL, minecraftDirectory: minecraftDirectory, depth: depth + 1) else { return nil }
                parent = parsedParent
            } catch {
                // 父清单存在但无法解析（文件损坏 / 读取失败 / 上游 JSON 非法）时不能再跳过合并：
                // 合并是补齐父版本 libraries 与 arguments 的唯一途径，缺失父清单会得到一份
                // classpath 不完整的清单，进游戏后才以 NoClassDefFoundError 之形式暴露，难以定位。
                // 与「父 JSON 不存在 → return nil」保持一致判定为解析失败，此处向上抛出原始错误
                // （parse 本身即 throws，JSON 层错误同样以抛出方式上报），不返回缺库的清单。
                // 注意：不要退回 break/跳过合并的写法。
                err("无法解析父版本清单 \(parentURL.path)（\(url.lastPathComponent) 的 inheritsFrom=\(inheritsFrom)）: \(error.localizedDescription)")
                throw error
            }
            
            return merge(parent: parent, manifest: manifest)
        }
        return ClientManifest(json: json)
    }
    
    /// 去重依赖库，并顺带做一次架构适配。
    ///
    /// 两件事，顺序不能换：
    /// 1. `ArtifactVersionMapper.map(manifest, arch: .x64)` —— 注意这里**固定传 `.x64`**，
    ///    不是笔误也不是按当前机器判断的。它只把 natives 的 `name` 统一成 `natives-macos`。
    ///    为什么在去重里做这件事：去重键含 classifier（见 `HashableLibrary`），
    ///    而架构改写会改 classifier，**必须先把坐标统一到最终形态再去重**，
    ///    否则同一份库的不同架构写法会被当成两条留着。
    ///    （与 `SLLaunchBridge.swift:292/295` 按真实架构做的映射谁先谁后，见
    ///    `ArtifactVersionMapper.swift` 文件头的「调用顺序」一节。）
    /// 2. 按 `HashableLibrary`（groupId + artifactId + classifier，**忽略版本**）去重，
    ///    保留**先出现的那条**。忽略版本是有意的：加载器清单会把同名库声明成不同版本，
    ///    我们以前面的为准（合并时子清单的库被插到最前，所以子版本优先于父版本）。
    public static func deduplicateLibraries(_ manifest: ClientManifest) {
        // 修正 libraries
        ArtifactVersionMapper.map(manifest, arch: .x64)
        
        var librarySet: Set<HashableLibrary> = .init()
        manifest.libraries = manifest.libraries.filter { librarySet.insert(.init($0)).inserted }
    }
    
    /// 把子清单的内容并入父清单，返回父清单对象（**就地改写，不复制**）。
    ///
    /// - 依赖库：子清单的库 `insert(..., at: 0)` 插到**最前面**，再整体去重。
    ///   插前面是「子版本覆盖父版本」的实现方式（去重保留先出现的）。
    /// - 参数：game/jvm 都是**追加到末尾**。注意 `parent.arguments` 为 nil 时
    ///   两行 append 都是空操作（`?.` 短路）—— 即旧版父清单（用 `minecraftArguments`）
    ///   的 `arguments` 是 nil，子清单的新式参数会被**整体丢掉**。
    ///   这是历史行为，改动前先确认是否真的存在「旧父 + 新加载器」的组合。
    /// - `minecraftArguments` 与 `mainClass`：**直接覆盖**为子清单的值（子版本说了算）。
    ///   加载器据此把自己的入口类顶上去。
    private static func merge(parent: ClientManifest, manifest: ClientManifest) -> ClientManifest {
        parent.libraries.insert(contentsOf: manifest.libraries, at: 0)
        deduplicateLibraries(parent)
        
        parent.arguments?.game.append(contentsOf: manifest.arguments?.game ?? [])
        parent.arguments?.jvm.append(contentsOf: manifest.arguments?.jvm ?? [])
        parent.minecraftArguments = manifest.minecraftArguments
        parent.mainClass = manifest.mainClass
        
        return parent
    }

    /// 需要进 **classpath** 的库（即非 natives 的普通依赖）。
    ///
    /// natives 包不算在内 —— 它们要被解压到 `natives/` 目录，而不是丢给 `-cp`。
    /// 两者的区分依据是 `Library.isNativeLibrary`（解析期看有没有命中 `natives["osx"]`）。
    public func getNeededLibraries() -> [Library] {
        getAllowedLibraries().filter { !$0.isNativeLibrary }
    }
    
    /// 解析期已按 `allow` / `disallow` 规则筛选完毕的库列表，即「规则允许使用的库」。
    ///
    /// 规则判定集中在 `ClientManifest.init(json:)` 的 `Rule.check` 一处完成，故本方法按设计
    /// 等价于 `libraries` 的恒等返回，不做二次过滤：重复过滤不改变结果，只会让规则判定
    /// 出现第二个入口。名称沿用上游 PCL.Mac 同源实现，含义是「已通过规则筛选」而非
    /// 「此处再筛一遍」。natives 与普通库的区分由 getNeededLibraries / getNeededNatives 承担。
    public func getAllowedLibraries() -> [Library] { libraries }
    
    /// 需要**解压到 `natives/` 目录**的 natives 包，键是库、值是它的下载信息。
    ///
    /// 用 `[Library: DownloadInfo]` 而不是数组，是为了让调用方能按库查进度/去重
    /// （哈希取 `Library.name`，见 `Library.hash`）。
    ///
    /// 细节：`library.artifact` 是可选值，而字典的值非可选 —— 赋 `nil` 在 Swift 里等价于
    /// **删键**。这里之所以安全，是因为 `isNativeLibrary == true` 的分支保证
    /// `artifact` 一定非空（见 `Library.init?(json:)`）。若将来放开这个不变量，
    /// 这行会静默丢条目而不是报错。
    public func getNeededNatives() -> [Library: DownloadInfo] {
        var result: [Library: DownloadInfo] = [:]
        for library in getAllowedLibraries() {
            if library.isNativeLibrary {
                result[library] = library.artifact
            }
        }
        return result
    }
    
    /// 取本版本的参数集合，**新旧两代格式统一成一个 `Arguments`**。
    ///
    /// 三条分支：
    /// 1. 有 `arguments`（1.13+）→ 直接返回。
    /// 2. 没有 `arguments` 但有 `minecraftArguments`（≤1.12）→ **现场合成**：
    ///    游戏参数按空格切分逐个包装；jvm 参数用一组**硬编码**的模板
    ///    （G1GC 调优 + `-Djava.library.path` 等四个 `-D` + `-cp`）。
    ///    这也解释了为什么老版本能启动：光有游戏参数是拼不出命令行来的。
    /// 3. 两者都没有 → 返回空的 `Arguments`（不崩，但启动必然失败）。
    ///
    /// 注意分支 2 的合成结果是**每次调用都新建**的，改它不会影响 `manifest`。
    /// 而分支 1 返回的是**清单内部那个对象**（`ClientManifest.arguments` 是引用类型），
    /// 调用方改 `jvm`/`game` 会直接影响清单 —— `SLLaunchBridge` 正是利用这一点
    /// 过滤掉当前 Java 不支持的参数（见该文件 :298 附近的注释）。
    public func getArguments() -> Arguments {
        if let arguments = self.arguments {
            return arguments
        } else if let minecraftArguments = self.minecraftArguments {
            let gameArgs = minecraftArguments.split(separator: " ").map { Arguments.GameArgument(json: JSON(stringLiteral: String($0))) }
            let jvmArgs: [Arguments.JvmArgument] = [
                "-XX:+UnlockExperimentalVMOptions", "-XX:+UseG1GC", "-XX:-UseAdaptiveSizePolicy", "-XX:-OmitStackTraceInFastThrow",
                "-Djava.library.path=${natives_directory}",
                "-Dorg.lwjgl.system.SharedLibraryExtractPath=${natives_directory}",
                "-Dio.netty.native.workdir=${natives_directory}",
                "-Djna.tmpdir=${natives_directory}",
                "-cp", "${classpath}"
            ].map { Arguments.JvmArgument(json: JSON(stringLiteral: $0)) }
            return Arguments(game: gameArgs, jvm: jvmArgs)
        } else {
            return Arguments(game: [], jvm: [])
        }
    }
    
    /// 去重用的包装类型：把 `Library` 的判等粒度从「完整坐标」改为
    /// 「groupId + artifactId + classifier，**忽略版本**」。
    ///
    /// 为什么不直接用 `Library`：它的 `==` 比的是完整 `name`（含版本），
    /// 而加载器清单里同一个库常带着不同版本号重复出现，按完整坐标去重会全部留下，
    /// classpath 里就会出现同名不同版本的 jar，行为不可预测。
    ///
    /// 为什么**保留 classifier**：`natives-macos` 与 `natives-macos-arm64`、
    /// 以及普通库与它的 natives 包，都是「同 group+artifact、不同 classifier」，
    /// 它们必须共存，所以 classifier 不能从键里去掉。
    ///
    /// 与 `Library` 的关系：这只是个包一层的外壳，`library` 仍指向同一个对象，
    /// 去重结果通过 `filter` 的 `.inserted` 作用在原数组上。
    private class HashableLibrary: Hashable {
        private let library: Library
        
        init(_ library: Library) {
            self.library = library
        }
        
        static func == (lhs: HashableLibrary, rhs: HashableLibrary) -> Bool {
            lhs.library.groupId == rhs.library.groupId
            && lhs.library.artifactId == rhs.library.artifactId
            && lhs.library.classifier == rhs.library.classifier
        }
        
        /// 必须与 `==` 用同样的三个字段，否则 `Set` 行为未定义。
        func hash(into hasher: inout Hasher) {
            hasher.combine(library.groupId)
            hasher.combine(library.artifactId)
            hasher.combine(library.classifier)
        }
    }
}
