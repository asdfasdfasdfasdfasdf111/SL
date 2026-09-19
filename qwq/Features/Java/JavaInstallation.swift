import Foundation

// MARK: - Java 安装架构

/// Java 安装的执行架构。
///
/// 与 PCLCore 的 `Architecture` 一一对应（`JavaVirtualMachine.arch` 的类型），
/// 单独建模是为了让 Java 模块不反向依赖 PCLCore 的具体枚举，便于后续替换为自有实现。
enum JavaArchitecture: String, Sendable, Hashable {
    /// Apple Silicon
    case arm64
    /// Intel x86_64
    case x64
    /// Universal / fat binary，同时在两种架构下可执行
    case universal
    /// 未能判定
    case unknown

    /// 本机架构。与 `Architecture.system` 保持一致。
    static var system: JavaArchitecture {
        JavaArchitecture(Architecture.system)
    }

    /// 由 PCLCore 的 `Architecture` 转换。
    init(_ arch: Architecture) {
        switch arch {
        case .arm64: self = .arm64
        case .x64: self = .x64
        case .fatFile: self = .universal
        case .unknown: self = .unknown
        }
    }

    /// 由架构字符串转换。兼容常见写法：arm64/aarch64/arm、x64/x86_64/amd64/universal。
    init(rawArchitecture description: String) {
        switch description {
        case "arm64", "aarch64", "arm": self = .arm64
        case "x64", "x86_64", "amd64", "x86": self = .x64
        case "fat", "universal": self = .universal
        default: self = .unknown
        }
    }

    /// 是否为本机原生可执行（无需 Rosetta 转译）。
    /// 未判定的架构按原生处理，避免因 `file` 探测失败而误降级。
    var isNative: Bool {
        self == .universal || self == .unknown || self == .system
    }
}

// MARK: - 统一的 Java 安装模型

/// 统一的 Java 安装描述，替代以下四套并存的数据表达：
/// `JavaManager` 扫描出的 `JavaInfo`、`DataManager.javaVirtualMachines` 的 `JavaVirtualMachine`、
/// `LauncherSettings.availableJavaList` 以及各调用点零散的 java 路径。
///
/// 本模型只读、值语义，可跨线程传递。
struct JavaInstallation: Sendable, Hashable, Identifiable {

    /// 以可执行文件路径作为标识：同一份 Java 无论来自哪套数据源，都合并为同一条记录。
    var id: String { executableURL.standardizedFileURL.path }

    /// java 可执行文件的绝对 URL
    let executableURL: URL

    /// 主版本号（8、17、21 等）；解析失败时为 0
    let majorVersion: Int

    /// 完整版本串（release 文件中的 JAVA_VERSION，或 `java -version` 的首行版本号）
    let fullVersion: String

    /// 执行架构
    let architecture: JavaArchitecture

    /// 发行方（IMPLEMENTOR / 版本串识别），可能为空
    let vendor: String?

    /// 是否可作为本机启动目标。
    /// 判定条件：版本号可被解析（> 0）且架构已判定。
    /// macOS 上 x64 JVM 可经 Rosetta 2 运行，因此非本机架构不判为不可用，仅在排序时降权。
    let isCompatible: Bool

    /// 是否为 JDK；`nil` 表示未检测。
    /// 来源为 `JavaInfo` 时不可得（`JavaInfo` 未携带该信息），故为可选。
    let isJDK: Bool?

    init(
        executableURL: URL,
        majorVersion: Int,
        fullVersion: String,
        architecture: JavaArchitecture,
        vendor: String? = nil,
        isCompatible: Bool,
        isJDK: Bool? = nil
    ) {
        self.executableURL = executableURL
        self.majorVersion = majorVersion
        self.fullVersion = fullVersion
        self.architecture = architecture
        self.vendor = vendor
        self.isCompatible = isCompatible
        self.isJDK = isJDK
    }

    /// 可执行文件当前是否真实存在（某些登记记录指向已被卸载的 JDK）。
    var fileExists: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    var executablePath: String { executableURL.path }
}

// MARK: - 由既有数据模型转换

extension JavaInstallation {

    /// 由 `JavaManager` / `JavaVersionParser` 产出的 `JavaInfo` 转换。
    /// `JavaInfo.architecture` 由解析器归一化为 x64 / aarch64 / unknown。
    init(_ info: JavaInfo) {
        let architecture = JavaArchitecture(rawArchitecture: info.architecture)
        self.init(
            executableURL: URL(fileURLWithPath: info.path),
            majorVersion: info.majorVersion,
            fullVersion: info.fullVersion,
            architecture: architecture,
            vendor: info.vendor,
            isCompatible: info.isValid && info.majorVersion > 0 && architecture != .unknown,
            isJDK: nil
        )
    }

    /// 由 `DataManager.javaVirtualMachines` 中的 `JavaVirtualMachine` 转换。
    /// `callMethod == .incompatible` 或错误占位（`isError`）的 JVM 判为不可用。
    init(_ vm: JavaVirtualMachine) {
        self.init(
            executableURL: vm.executableURL,
            majorVersion: vm.version,
            fullVersion: vm.displayVersion,
            architecture: JavaArchitecture(vm.arch),
            vendor: vm.implementor,
            isCompatible: !vm.isError && vm.callMethod != .incompatible && vm.version > 0,
            isJDK: vm.isJdk
        )
    }
}
