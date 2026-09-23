# qwq 单元测试说明

本目录是给 `qwq` 工程补的单元测试，覆盖 `Core/`（下载、模块内核）、`Features/Java/`、
`Features/Launch/`、`App/ViewModels/`、`UI/Notices/` 与下载适配器层。

**当前状态：工程已包含 `qwqTests` unit-test target（`productType = com.apple.product-type.bundle.unit-test`）。`qwq.xcodeproj` 通过 `PBXFileSystemSynchronizedRootGroup` 自动同步整个 `qwqTests/` 目录，新增 / 删除测试文件无需手工加入 target；`qwq.xcscheme` 的 TestAction 已挂 `qwqTests.xctest`，直接 ⌘U 即可运行。详细进展见 `REFACTOR_PLAN.md`。**

## 一、XCTest target（已完成，无需手工创建）

工程已包含 `qwqTests` unit-test target（`productType = com.apple.product-type.bundle.unit-test`）。`qwq.xcodeproj` 通过 `PBXFileSystemSynchronizedRootGroup` 自动同步整个 `qwqTests/` 目录，新增 / 删除测试文件无需手工加入 target；`qwq.xcscheme` 的 TestAction 已挂 `qwqTests.xctest`，直接 ⌘U 即可运行。详细进展见 `REFACTOR_PLAN.md`。

- **target**：`qwqTests`，产物 `qwqTests.xctest`，类型 unit-test bundle。
- **目录自动同步**：`qwqTests/` 作为 `PBXFileSystemSynchronizedRootGroup` 自动纳入编译，测试文件放在该目录下即生效，不需要拖进 Xcode 或在 File Inspector 里勾选 Target Membership。
- **运行**：Xcode 中 ⌘U；或 Terminal 执行 `./scripts/verify-test.sh run`（宿主型 XCTest 依赖 testmanagerd 的 XPC，需在脱离 AI 沙箱的 Terminal 里跑，详见 `REFACTOR_PLAN.md` §六）。
- **接线记录**：见 `REFACTOR_PLAN.md` 第 15 项（`8172dbf`，TEST BUILD SUCCEEDED，14 文件 181 用例可编译）。

测试文件清单（共 14 个，目录自动同步，无需手工加入 target）：

| 文件 | 被测对象 | 备注 |
| --- | --- | --- |
| `JavaResolverTests.swift` | JavaRequirement / DefaultJavaResolver / JavaInstallation | 经 `JavaRepository` 协议注入 fake，无需真实扫描 |
| `DownloadVerifierTests.swift` | CryptoKitDownloadVerifier | 临时目录造真实文件，不依赖网络 |
| `DownloadMergerTests.swift` | DownloadMerger 契约 | 协议无默认实现，用测试替身验证契约 |
| `DownloadStateTests.swift` | DownloadProgress / DownloadState / DownloadError | 纯值类型 |
| `LaunchStateTests.swift` | LaunchState / LaunchError / LaunchResult | 纯值类型 |
| `ModuleRegistryTests.swift` | SLModule / ModuleContext / ModuleRegistry / ModuleCapabilityKey | 用 `SLModule` 替身，不触发真实模块副作用 |
| `JavaResolverBridgeTests.swift` | JavaResolverBridge | 只覆盖超时/边界；无 resolver 注入点，见缺口 §4.3 |
| `NoticeCenterTests.swift` | NoticeCenter / Notice / NoticeLevel / NoticeButton | MainActor 单例，用例内复位承载者状态 |
| `NavigationStateTests.swift` | NavigationState | 断言已复位 `DownloadDetailManager.shared` |
| `LaunchPanelStateTests.swift` | LaunchPanelState | 断言已复位 `LauncherSettings` 四个内存字段 |
| `HomeInteractionStateTests.swift` | HomeInteractionState | 纯视图级状态容器 |
| `DropInstallCoordinatorTests.swift` | DropInstallCoordinator | 只覆盖分流与失败分支；成功安装分支见缺口 §4.5 |
| `DownloadAdapterTests.swift` | DownloadSourceResolver / DefaultDownloadSourceResolver / NetDownloaderDownloadEngine / DefaultDownloadVerifier.checker | 经构造参数注入 resolver，`precheck` 跳过路径无需网络 |
| `RealLaunchIntegrationTests.swift` | （见 §4.14，默认跳过）真实启动链路集成用例 | 拉起真实 Minecraft 进程，靠 `/tmp/sl-real-launch.enabled` 开关默认跳过 |

每个测试文件顶部都有 `@testable import qwq`，因为多数被测类型（`JavaInstallation`、
`JavaRequirement`、`DefaultJavaResolver`、`SLModule`、`ModuleContext`、
`NetDownloaderDownloadEngine` 等）是 internal 或依赖 internal 类型，不加这一行编译不过。

> 旧文档曾指导手工建 target、把测试文件拖进 Xcode 并逐个勾选 membership——该步骤已不适用，现由文件夹同步组自动完成。

## 二、不建 target 也能做的类型检查

也可以用下面的命令做纯编译期校验（只做 `-typecheck`，不链接、不运行；完整 test run 仍走 ⌘U 或 `verify-test.sh`）。

> **注意：正文里给出的最简命令（`xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps $(find qwq -name "*.swift") qwqTests/*.swift`）跑不通**，
> 实测缺三个必要条件，见下面各条。可用命令如下：

```bash
cd /path/to/Swim111Launcher_副本
SDK=$(xcrun --show-sdk-path)
DEV=$(xcode-select -p)
FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"
LIB="$DEV/Platforms/MacOSX.platform/Developer/usr/lib"

xcrun swiftc -typecheck \
  -sdk "$SDK" -F "$FW" -I "$LIB" -I /tmp/deps \
  -target arm64-apple-macosx13.0 -module-name qwq \
  $(find qwq -name "*.swift") qwqTests/*.swift
```

三个 flag 的必要性（逐个实测确认，缺一即失败）：

| 缺什么 | 报错 | 原因 |
| --- | --- | --- |
| `-sdk` / `-F "$FW"` / `-I "$LIB"` | `no such module 'XCTest'` | `XCTest` 的 Swift 模块不在 SDK 里，位于 Xcode 的 MacOSX Platform Developer 目录 |
| `-module-name qwq` | `no such module 'qwq'` | 不加时所有源文件被视为无模块名，`@testable import qwq` 无从解析 |
| `-I /tmp/deps` | `no such module 'SwiftyJSON'`（`SLCore/Utils/Requests.swift`） | 第三方依赖（SwiftyJSON / ZIPFoundation）以预编译模块放在 `/tmp/deps` |

单模块编译下，`@testable import qwq` 会产生一条
`file ... is part of module 'qwq'; ignoring import` 警告，属预期，不影响结果。
把全部源文件与测试文件放进同一次 `swiftc` 调用，等价于「测试代码与生产代码同属 qwq 模块」，
因此顶层的 `internal` 类型可直接访问，不需要 `@testable` 的额外可见性提升。

### 2.1 配套修正：`FakeJavaRepository` 补齐 `preScan()`

全量 typecheck 在本轮开始前是**通不过**的，原因不在新增文件，而在既有测试文件：

```
qwqTests/JavaResolverTests.swift：error: type 'FakeJavaRepository' does not conform to protocol 'JavaRepository'（缺 preScan()）
```

`Features/Java/JavaRepository.swift` 后来给协议加了 `preScan()` 要求，
而 `JavaResolverTests` 里的替身 `FakeJavaRepository` 未跟进（测试文件早于协议变更）。
该文件是既有文件，本轮已随配套改动一并补齐（5 行，只记录调用、不触发真实扫描）：

```swift
/// 预扫描在本 fake 中只记录调用，不触发真实扫描。
func preScan() {
    callLog.append("preScan")
}
```

补齐后全量 typecheck 退出码为 0。若需回退这份修正，全量 typecheck 会立刻退回 1 个 error。

### 2.2 实测结果

- **退出码 0，0 个 error**（全部 14 个测试文件 + 全部生产源码）。
- 48 条 warning，其中绝大多数是每个测试文件各一条
  `warning: file '...' is part of module 'qwq'; ignoring import`（单模块编译的预期产物）；
  其余是生产代码里既有的 warning（未使用的局部变量、Swift 6 并发警告等），与测试无关。

> 注：编辑过程中曾因并发写盘（`input file ... was modified during the build`）出现瞬时失败，
> 重跑即可。命令本身无随机性。

各文件对应的源文件集合（供单独校验时参考）：

- `DownloadStateTests.swift` → `Core/Download/DownloadState.swift`、`DownloadProgress.swift`、`DownloadError.swift`
- `DownloadVerifierTests.swift` → `Core/Download/DownloadVerifier.swift`、`DownloadError.swift`
- `DownloadMergerTests.swift` → `Core/Download/DownloadMerger.swift`、`DownloadSliceStore.swift`
- `LaunchStateTests.swift` → `Features/Launch/LaunchState.swift`、`LaunchError.swift`、`LaunchResult.swift`
- `ModuleRegistryTests.swift` → `Core/Module/SLModule.swift`、`ModuleRegistry.swift`、`Features/Settings/AppSettingsStore.swift`
- `JavaResolverBridgeTests.swift` → `Features/Java/` 下 `JavaResolverBridge.swift`、`JavaResolver.swift`、
  `JavaRepository.swift`、`JavaRequirement.swift`、`JavaInstallation.swift`、`JavaInfo.swift`
- `NoticeCenterTests.swift` → `UI/Notices/NoticeCenter.swift`、`SLCore/Stubs.swift`
- `NavigationStateTests.swift` → `App/ViewModels/NavigationState.swift`、`Features/ModBrowser/Category.swift`、`Features/Download/DownloadDetailManager.swift`
- `LaunchPanelStateTests.swift` → `App/ViewModels/LaunchPanelState.swift`、`Features/Settings/ThemeManager.swift`
- `HomeInteractionStateTests.swift` → `App/ViewModels/HomeInteractionState.swift`
- `DropInstallCoordinatorTests.swift` → `App/ViewModels/DropInstallCoordinator.swift`、`Features/ModBrowser/ModVersionDetector.swift`、`Services/DragDropHandler.swift`
- `DownloadAdapterTests.swift` → `Core/Download/DownloadSourceResolver.swift`、`Adapters/` 下
  `DefaultDownloadSourceResolver.swift`、`DefaultDownloadVerifier.swift`、`NetDownloaderDownloadEngine.swift`、
  `SLCore/Download/NetDownloader.swift`、`MultiFileDownloader.swift`、`DownloadSourceManager.swift`
- `JavaResolverTests.swift` → `Features/Java/` 下 `JavaResolver.swift`、`JavaInstallation.swift`、
  `JavaRequirement.swift`、`JavaInfo.swift`，外加 `SLCore` 的
  `Java/JavaVirtualMachine.swift`、`Utils/MyLocalizedError.swift`、`Utils/PropertiesParser.swift`

> `JavaResolverTests` 的命令行校验有个已知折中：被测主体（`JavaResolver` / `JavaInstallation` /
> `JavaRequirement` / `JavaVirtualMachine`）都是真实源码，但三处**直接依赖**用签名一致的替身
> 顶替，否则会牵出整条依赖链（`JavaRepository` → `JavaManager` → `LauncherSettings` /
> `AppContext` / SwiftUI；`Stubs.swift`（离线账号 / 提示通道）依赖 `VersionManifest` /
> `MinecraftDirectory`；全局 `err()` 所在的 `LogManager.swift` 依赖 `SharedConstants`）。
> 替身放在 `/tmp`，不入库；在 Xcode 里跑真身 target 时不受此影响。

## 三、测试用例分布与真实断言说明

| 文件 | 用例数 | 断言性质 |
| --- | --- | --- |
| `JavaResolverTests.swift` | 24 | 真实断言（注入 fake 仓储） |
| `DownloadVerifierTests.swift` | 14 | 真实断言（临时目录真实文件） |
| `DownloadMergerTests.swift` | 8 | 契约断言（测试替身） |
| `DownloadStateTests.swift` | 10 | 真实断言（纯值类型） |
| `LaunchStateTests.swift` | 9 | 真实断言（纯值类型） |
| `ModuleRegistryTests.swift` | 13 | 真实断言（`SLModule` 替身 + 真实 `AppModuleBootstrap`） |
| `JavaResolverBridgeTests.swift` | 8 | **部分为条件断言**，见下方说明 |
| `NoticeCenterTests.swift` | 21 | 真实断言 |
| `NavigationStateTests.swift` | 16 | 真实断言 |
| `LaunchPanelStateTests.swift` | 11 | 真实断言 |
| `HomeInteractionStateTests.swift` | 5 | 真实断言 |
| `DropInstallCoordinatorTests.swift` | 16 | 真实断言（失败/分流分支） |
| `DownloadAdapterTests.swift` | 25 | 真实断言（注入 resolver + `precheck` 跳过路径） |
| `RealLaunchIntegrationTests.swift` | 1 | 默认跳过：真实拉起 Minecraft 进程验证启动链路健康（见 §4.14） |
| **合计** | **181** | |

关于「非纯真实断言」的两处，均为无法消除的环境约束，已在对应文件注释中写明：

1. `JavaResolverBridgeTests.testNonNilResultIsAnExistingLocalFile` 是**条件断言**：
   桥接层内部硬编码 `DefaultJavaResolver()`，没有 resolver 注入点，
   「解析成功」与「解析失败」无法与本机是否装有 Java 解耦，因此断言写成
   `if let url = result { 断言它必须是真实存在的本地文件 }`；结果为 nil 时不做断言。
   其余 7 条（timeout=0 / 极小 / 负数超时、超时耗时有上界、`minimumMajor` 取 `Int.min`/`Int.max`、
   `mcVersion` 为 nil/空串、并发不死锁）都是确定性的真实断言。
2. `DownloadAdapterTests` 中涉及引擎终态的用例依赖 `NetDownloaderDownloadEngine` 的
   `precheck` 分支（目标文件已存在且无校验要求 → `.skip`），因此**不触网**即可稳定得到
   `completed`；失败终态则用 `replaceMethod = .throw` + 已存在目标文件构造
   `NetDownloadError.fileExists`，期望值直接取自旧错误类型的 `errorDescription`，
   断言的是「与旧描述同源」而非手写字符串。

**因缺注入点而跳过（不是硬测）的主要行为**，逐条记录在各测试文件末尾的注释中，
汇总见下一节。

## 四、已知覆盖率缺口与后续计划

本节按「最该补」的优先级排列。

### 4.1 下载器的真实并发与断点续传（最高优先级）

- 未覆盖：`DownloadScheduler` 的分片切分与并发额度、`DownloadSliceStore` 的续传台账、
  `DownloadEngine` 的状态流发布。
- 阻塞原因：三者都只有协议声明，无实现；且真实验证需要受控 HTTP 服务端。
- 计划：引入进程内 mock HTTP server（`Swifter` 或基于 `Network.framework` 的最小实现），
  支持返回 206 + `Content-Range`、可控限速、中途断连，再补：
  - 分片切分边界（文件大小不能被分片数整除、单分片、0 字节）
  - 续传：写入半片后中断 → 重连带 `Range` → 合并结果哈希一致
  - 源切换：主源 5xx → 落到备用源（配合 `SequentialDownloadSourceResolver`）
  - 取消：`.cancelled` 终态后临时文件被清理

### 4.2 `legacyFailureReason` 的**网络失败**文案回放

- 现状：`DownloadAdapterTests` 已覆盖「失败终态回放旧错误描述（`NetDownloadError.fileExists`，
  不触网）」「成功/取消终态与未知 taskID 返回 nil」两侧。
- 未覆盖：真实线上最常见的失败来自 HTTP 层（`<name>：无可用下载源。`、慢速断开、
  分片校验失败、`远程服务器返回了 4xx。`）。这些文案能否被
  `NetDownloaderDownloadEngine.map(_:)` 正确归类、以及归类后 `legacyFailureReason`
  是否仍为**原文**（而 `.failed` 是归一化后的结构化错误），尚无断言。
- 阻塞原因：`NetDownloaderDownloadEngine` 内部直接调用 `NetManager.shared`（actor 单例），
  无网络后端注入点。
- 计划：给引擎加 `NetManager` 协议抽象，注入返回「远程服务器返回了 404」一类错误的 fake，
  断言 `legacyFailureReason` 保留原始文本、`.failed` 为 `.httpStatus(404)`（两者文案不同，
  正是该接口存在的理由）。

### 4.3 `JavaResolverBridge` 的「解析失败（非超时）」确定性覆盖

- 现状：只覆盖了「超时 → nil」（`timeout <= 0` 的确定性分支）与边界输入。
- 未覆盖：`JavaResolutionError.scanFailed` / `.noCompatibleVersion` / `.notFound`
  三条失败原因返回 nil 的正向断言——实现内部硬编码 `DefaultJavaResolver()`，
  失败与超时都表现为 nil，无法区分。
- 计划：把 resolver 提为可注入参数（`resolver: JavaResolver = DefaultJavaResolver()`），
  再用「必抛错的 fake」+ 小 timeout 断言「返回 nil 且耗时远小于 timeout」。

### 4.4 `DefaultDownloadSourceResolver` 的镜像（自动切换）方向

- 未覆盖：`AppSettings.fileDownloadSource == .both` 且主源属于官方域名族时，
  追加 BMCLAPI 备用源（第二个候选仅 host 被替换，path / query 保持不变）。
- 阻塞原因：`DownloadSourceManager` 是单例，both 模式下 `getDownloadSource()`
  会触发真实的官方源测速后台任务，测速结果会改写当前主源，
  导致候选个数在官方源与镜像源之间漂移，无法稳定断言。
- 计划：给源管理器加注入点或把「当前源 + 互补源」改成纯函数后再补。
- 已覆盖的单源一侧：非官方域名、手动限定「仅官方 / 仅镜像」、无 host 的本地路径，
  均断言只返回一个候选。

### 4.5 `DropInstallCoordinator` 的成功安装分支

- 未覆盖：
  - `beginModInstall` 的成功分支（`ModVersionDetector.detectVersion` 返回结果 +
    `ModDragInstaller.findInstances` 命中实例 → 打开模组弹窗）；
  - `confirmModInstall` 的成功分支（会真实拷贝文件到 `versions/<v>/mods`）；
  - `confirmModpackInstall` 的成功分支（`ModpackInstaller().install` 真实解压）。
- 阻塞原因：`versionDetector` / `settings` 是硬编码私有依赖，`ModDragInstaller` /
  `ModpackInstaller` 无注入点；成功后投递的用户文案
  「模组已安装到 N 个实例」「整合包安装完成」「整合包安装失败: …」因此仍不受保护。
- 计划：把三者抽成协议并在 `DropInstallCoordinator` 构造时注入。

### 4.6 `NoticeCenter` 的 300s 兜底超时

- 未覆盖：`responseTimeoutNanos`（300s）到期后按默认按钮（下标 0）应答。
  真等 5 分钟不现实，时限被 `private static let` 固定，无注入点。
- 已覆盖的等价分支：`dismiss()` 走同一个 `choose(notice, index: 0)`。
- 计划：把超时时长改为可注入（`init` 参数或 internal static var）后，用 0.05s 断言。

### 4.7 `DownloadMerger` 的真实实现

- 协议注释已约定「单分片允许直接移动临时文件」，但工程内无实现（旧逻辑在 `NetManager.merge`）。
- 计划：落地 `FileManagerDownloadMerger` 后，把 `DownloadMergerTests` 里的
  `OffsetOrderingMerger` 替换为真实实现，保留现有断言（乱序/倒序拼接、目录自动创建、
  分片缺失报错、空分片列表）。

### 4.8 `LaunchService` 全链路

- `LaunchService` / `LaunchArgumentBuilder` / `GameProcessController` 均为纯协议，无实现、无注入点。
- 计划：落地 `DefaultLaunchService` 时把参数组装器与进程控制器作为构造参数注入，
  用 fake 断言参数顺序（JVM 参数 → 主类 → 游戏参数）、classpath 拼接符与 `-Xmx` 生成。

### 4.9 `DefaultLaunchPreflight`

- 已有可注入的四个校验器（`ClientFileVerifier` / `LibraryFileVerifier` /
  `AssetFileVerifier` / `NativeInstaller`），具备可测性，本轮未覆盖。
- 计划：补 `LaunchPreflightTests`，断言 `skipResourceCheck` 短路、四段调用顺序、
  进度区间映射（支持库 0~0.5、资源 0.5~1）。

### 4.10 `GameSessionStore`

- `InMemoryGameSessionStore` 有实现，但 `register` 需要 `ManagedProcess`，
  而 `ManagedProcess` 直接持有 `Process`，缺少协议抽象。
- 建议改造：把 `ManagedProcess` 抽成协议（如 `GameProcess`），
  或在测试中以 `/bin/sleep` 作为受控进程验证 register → observe → terminate。

### 4.11 `JavaModule` 的注册结果

- `SLModule` / `ModuleContext` / `ModuleCapabilityKey` 已就位，`JavaModule` 现在可以编译了，
  但注册结果仍无法有效断言：其 `register` 直接构造 `DefaultJavaRepository()` →
  `JavaManager.shared.scanInstalledJava`，只能验证「上下文里存在一个 `DefaultJavaResolver`」，
  无法验证解析是否可用，而真实磁盘扫描会 fork `java -version`。
- 另外 `AppModuleBootstrap` 中 `JavaModule()` 目前处于注释状态，即使补测也不会被装配入口覆盖。
- 计划：`JavaModule` 支持注入仓储后，补「注册后可从 ModuleContext 取到 java.resolver 且行为正确」。

### 4.12 `ModuleRegistry` 的并发安全

- `ModuleRegistry.register(_:)` 与 `ModuleContext.values` 都未加锁，
  实现假定「装配期单线程、注册完成后只读」。
- 该约定无法在不改源码的前提下用用例表达：用例若并发调用 `register`，
  观测到的是数据竞争而非稳定结论，属于不确定性测试，因此**故意不写**。

### 4.13 CI

- 工程当前没有任何 CI。计划：target 建好后接一条
  `xcodebuild -scheme qwq -destination 'platform=macOS' test` 的流水线，
  并逐步给出覆盖率门禁。
- 在此之前，`§2` 的 `swiftc -typecheck` 命令可作为低成本的前置门禁（实测退出码 0）。

### 4.14 真实启动（已落地，默认跳过）

`RealLaunchIntegrationTests.swift` 是唯一一条**会真的拉起 Minecraft 进程**的用例。它存在的理由是
其余用例都停在「纯值类型 / 纯协议 / 可注入桩」层，而启动链路风险最高的几处（natives 架构、
Java 解析与版本门槛、classpath 去重、进程生命周期）只有在真机上跑一次才能证伪。

之所以默认跳过（靠 `/tmp/sl-real-launch.enabled` 标记文件开关，而不是环境变量 ——
`xcodebuild test` 不会把调用方 shell 的环境带进宿主进程）：跑一次要占几 GB 内存、弹一个游戏窗口、
最长数分钟，塞进日常 `verify-test.sh` 会把每次单测都变成一次游戏启动。

```bash
touch /tmp/sl-real-launch.enabled
SL_DERIVED=/tmp/SL-DD-real ./scripts/verify-test.sh run
rm /tmp/sl-real-launch.enabled
```

断言口径（也是「启动链路健康」的可证据清单）：

1. 收到 `.launcherReady` → 实例可创建、客户端 JAR 非空、Java 已解析；
2. 收到 `.running` → 游戏窗口被 `CGWindowList` 观测到；
3. 日志里不出现 `UnsatisfiedLinkError` / `NoClassDefFoundError` /
   `Could not find or load main class` → natives 架构与 classpath 正确；
4. 测试末尾自行 `terminate()` 收尾，**因此不要求退出码为 0**（被杀进程本就非 0）。

用例里硬编码了 `~/Library/Application Support/minecraft` + `26.2-Fabric`。
刻意不读 `LauncherSettings`：真实启动用例要能脱离 App 状态独立复现，取值被 UI 改动后
应当**失败并提示**，而不是悄悄换个版本再跑。

若在无法驱动 UI 的环境里（无辅助功能权限）需要跑一次启动，还有第三条路，见
`REFACTOR_PLAN.md` §七：`SL_DEBUG_AUTO_LAUNCH=1`。

## 五、必须遵守：用例一律写成 `async`（Xcode 26.2 隔离析构缺陷）

**结论**：`qwqTests` 里**每个 `test…()` 方法都必须写成 `async`**。这不是为了等待什么，
而是为了躲开一条会把整个测试进程打死的工具链缺陷。当前 14 个测试文件、181 个用例已全部统一。

### 现象

在**同步**用例里创建并释放任何一个 `@MainActor` 类实例，测试宿主 100% 直接 abort：

```
Test Case '-[qwqTests.LaunchPanelStateTests testClearLaunchErrorClearsTextOnly]' started.
qwq(30095,0x20e2462c0) malloc: *** error for object 0x2a0b603b0: pointer being freed was not allocated
```

XCTest 会不断重启宿主继续往下跑，所以表面症状是「一堆用例通过、然后无限重启、套件再也前进不了」。
2026-09-22 的全量运行共 **39 次崩溃**，卡在第 5 个测试类。

### 根因（已定位到构建设置这一层）

1. 工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（Debug / Release 都开）。
2. 这个设置会把**没有显式 `deinit` 的类**的隐式析构推断成「隔离析构（isolated deinit）」。
3. 于是析构入口不再直接释放对象，而是调用运行时垫片
   `swift_task_deinitOnExecutorMainActorBackDeploy`（macOS < 15.4 的兼容路径；
   在 macOS 26 上它转发给运行时的 `swift_task_deinitOnExecutor`）。
4. 同步用例跑在主线程上但**不在任何 Task 里**，运行时因此走了「把析构推迟到主 actor」的慢路径，
   在 `TaskLocal::StopLookupScope` 收尾处对同一个对象二次释放 → `pointer being freed was not allocated`。

硬证据（同一份源码，只改这一个构建设置，统计反汇编里调用该垫片的析构函数个数）：

| 构建设置 | 走隔离析构的类数量 |
|---|---|
| `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（现状） | **102** |
| 关掉该设置 | **0** |

上游同源问题：[swiftlang/swift#87422](https://github.com/swiftlang/swift/issues/87422)
（环境栏写的正是 Xcode 26.2 / 17C52）。

### 为什么选「用例 async」而不是别的修法

| 方案 | 代价 | 为什么不采用 |
|---|---|---|
| **用例一律 `async`**（已采用） | 14 个测试文件、140 行；生产代码零改动 | —— |
| 给 102 个类各加 `nonisolated deinit {}` | 102 个生产文件 | 为一条工具链缺陷改 102 个类；而且会把「析构推迟到主 actor」这一语义一起改掉 |
| 关掉 `SWIFT_DEFAULT_ACTOR_ISOLATION` | 1 行设置 | 实测**编译 0 报错**，但 Swift 5 语言模式下默认隔离会「静默失效」—— 不报错、只悄悄改变语义，比崩溃更难发现 |
| 等 Apple 修 | 0 | 无法预期周期；且升级工具链后 `async` 写法依然正确，**不需要回滚** |

### 为什么 app 本身没事

app 里这些对象都在主队列上下文（SwiftUI / Combine / AppKit 回调）里释放，此时「当前执行器」
就是主 actor，运行时走**内联快路径**，不碰那条有缺陷的慢路径。只有 XCTest 的同步用例
是在主线程上、却不在任何 Task 里的调用点。

### 写法

```swift
// ✅ 正确：async 把用例体放进一个 MainActor 任务里执行
func testClearLaunchErrorClearsTextOnly() async {
    let panel = LaunchPanelState()
    panel.presentError("启动失败")
    XCTAssertNil(panel.launchErrorMessage)
}

// ❌ 会 abort 整个测试进程
func testClearLaunchErrorClearsTextOnly() {
    let panel = LaunchPanelState()
    ...
}
```

带 `throws` 的写成 `func testX() async throws`。用例体内不需要 `await` 任何东西 ——
`async` 在这里只是手段，不是目的。

**注意**：不要试图写一条「释放 MainActor 类不崩溃」的同步回归用例 ——
它在有缺陷的工具链上必然 abort，会让套件永远是红的。要在本机单独验证这条，
只能用临时探针（跑完即删），不能进套件。
