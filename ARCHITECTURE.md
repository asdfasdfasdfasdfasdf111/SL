# SL 架构

> **本文档的定位**：描述**当前真实存在**的结构。
> 不写"目标结构"，不写"待接线"的蓝图 —— 那些内容曾让本文件长期描述一个运行时不存在
> 的架构（详见 §三）。要提改进设想，请开 issue 或写进提交信息，不要写进本文档。

## 一、分层

```
View → ViewModel → UseCase / Service → Infrastructure（SLCore/、Core/）
```

目录即分层：

| 目录 | 职责 |
| --- | --- |
| `qwq/App/` | 应用入口、装配根、全局导航/面板状态 |
| `qwq/Features/` | 按功能切分（Download/Game/Java/Launch/ModBrowser/Settings/Skin/Theme/Translation） |
| `qwq/Core/` | 跨功能的领域模型与抽象（Download 的引擎门面、Events） |
| `qwq/SLCore/` | 基础设施实现（账号、下载引擎、Java、Minecraft、存储、日志、通知） |
| `qwq/UI/` | 可复用视图组件与窗口修饰器 |
| `qwq/Models/` | 纯数据模型 |

## 二、依赖注入的实际形态：构造器默认参数

本项目**不用** DI 容器。跨模块取用依赖的统一写法是构造器默认参数：

```swift
// qwq/Features/Game/ViewModels/DownloadCategoryViewModel.swift
init(versionCatalog: VersionCatalogService = DefaultVersionCatalogService(),
     versionFilter: VersionFilterUseCase = VersionFilterUseCase()) {
```

选它的理由（对比已废弃的注册表方案）：

| | 构造器默认参数 | 运行时注册表（已废弃） |
| --- | --- | --- |
| 拼错依赖名 | 编译失败 | 运行期才发现 |
| 缺依赖 | 编译失败 | 静默降级（曾用 `NSLog` 吞掉） |
| 测试注入 | 直接传替身 | 需先建注册表 |
| 阅读依赖 | 看 init 签名 | 全局搜字符串键 |
| 额外代码量 | 0 | 注册表 + 各模块 register() + 专属测试 |

**约定**：新增可替换的服务时，定义协议 + 默认实现，在**使用方的 init 默认值**里注入。
不要引入容器、不要用字符串键解析能力。

### 仍然存在的单例

`static let shared` 目前有 20 余处，集中在两类，暂不清理：

- **进程级基础设施**：`AppContext`（URLSession/进程池/缓存根，28 处真实使用；2026-10-02 连同
  `ProcessPool`/`CacheManager` 自 App/Features/Services 归位至 `SLCore/` 基础设施层，消除
  Features→App 反向依赖，`Services/` 目录已随之删除）、
  `LogStore`、`MemoryPressureBroadcaster`、`PopupManager`、`NoticeCenter`
- **全局 UI 状态**：`NavigationIntent`、`LaunchPanelState`、`DownloadDetailManager`

它们是**有意的全局状态**，不是待迁移的遗留物。要收敛的是"业务服务藏在单例里"，
而不是"进程只有一个缓存根"。

## 三、已放弃：`ModuleContext` 模块内核（2026-10 删除）

**曾做过的**：`SLModule` / `ModuleCapabilityKey` / `ModuleContext` / `ModuleRegistry` /
`AppModuleBootstrap`，8 个模块注册 10 项能力，配套 244 行专属测试。

**为什么删**：全库**没有任何一处从 `ModuleContext` 解析能力**。26 个单例一个没少，
注册表在生产代码里零调用方（只有测试在调），**真实运行时不存在这个注册表**。
它带来的是一套与 `AppContext` 并行的第二套 DI，以及"结构已完成、待接线"的持续幻觉。

**删除即结论**：不是"暂时搁置"，是**判定该方案不适用于本项目**。
若要重提模块化，请先回答：它比构造器默认参数多解决什么问题？
（净删除 1231 行，见提交 `cdf9dee`。）

## 四、设置层收口

- `qwq/Features/Settings/AppSettingsStore.swift`：设置数据的**唯一存储点**
  - 只负责设置数据的持有与持久化
  - 不持有 Java、下载、启动等业务状态
  - 复用项目既有的 `UDK` 键名，保证与旧数据兼容
- `ThemeManager` / `LauncherSettings`：**兼容层**，不再新增字段，逐步收窄后移除
  - 两者均已完成向 `AppSettingsStore` 的转发收敛（不再自持持久化字段、不再各自写 `UserDefaults`）
  - ⚠️ 两者各有一条 `AnyCancellable` 桥接订阅 `AppSettingsStore.objectWillChange` 并转发到自身
    `objectWillChange`。**这条订阅是功能必需的，不是优化**：转发字段已不是 `@Published`，
    订阅这些兼容层的视图（`ContentView` 等）只能靠它刷新，断掉后**静默不重绘**、编译期无提示。
    契约用例：`qwqTests/LaunchPanelStateTests.swift`
  - 剩余短生命周期 UI 状态（`showLaunchAlert` / `launchErrorMessage` / `showJavaPopup` /
    `javaPopupMessage` / `availableJavaList` / `isJavaScanning`）**不是设置**，不入库、不转发。

## 五、Java

问题背景：Java 数据源曾分裂成四套（`DataManager.javaVirtualMachines`、
`LauncherSettings.availableJavaList`、`JavaManager`、`MinecraftInstance.findSuitableJava`），
`SLLaunchBridge` 里还有一条四级降级链。

现有（`qwq/Features/Java/`）：

- `JavaInstallation`：统一的 Java 安装模型，可从 `JavaInfo` / `JavaVirtualMachine` 转换
- `JavaRequirement`：版本需求，含 MC 版本 → Java 版本推导规则
- `JavaRepository`：扫描与持久化
- `JavaResolver`：唯一选择入口 `resolve(_:)`
- `JavaResolverBridge`：桥接 `SLLaunchBridge` 的同步上下文

目标：启动器只调用 `JavaResolver`，不再有多级 fallback。

## 六、下载

**当前是双轨，且这是有意的**：

| | 位置 | 规模 | 角色 |
| --- | --- | --- | --- |
| 旧引擎 | `qwq/SLCore/Download/`（17 文件） | ~1983 行 | **实际下载算法**：预检、多源、分片、重试、黑名单、测速、合并、校验、取消清理 |
| 新门面 | `qwq/Core/Download/`（10 文件） | ~765 行 | 对外抽象：`DownloadEngine` + 数据/错误/状态类型 + 适配器 |

关键事实：

- `DownloadEngine` 是**对外唯一入口**，只有"提交 / 观测 / 取消"三件事。
- 唯一实现 `NetDownloaderDownloadEngine` 是**适配器**，后端仍转发到
  `SLCore/Download/NetDownloader.swift` 的 `NetManager`。它**已接入 5 处调用方**：
  `ModFileDownloadTask`、`MinecraftLauncherDownload`、`MinecraftInstallerDownloads`、
  `ForgeInstaller`、`FabricInstaller`（切换记录见 `Core/Download/Adapters/MIGRATION.md`）。
- 未接入（终态决策：**不接入**，见 §十第 2/3 条）：`MultiFileDownloader` 各调用点
  保持直连 `NetManager`；绕过引擎直连 `URLSession` 的 `LoaderSupportProbe`/`Requests`
  属探测/请求工具，非下载引擎职责。
- `Core/Download/` 里**只有真实使用的类型**。2026-10 已删除仅存协议声明、
  零实现零调用的 `DownloadScheduler` / `DownloadSliceStore` / `DownloadMerger` / `DownloadTask`。
  教训：**不要提交"先定协议、实现待补"的文件** —— 它们会长期留在树里冒充架构。

已知坏味道：**无**（2026-10-02 已全部闭环：`NetDownloaderDownloadEngine.map(_:)` 的中文
文案反猜 → `NetDownloadError` 结构化 case；`syntheticTotalBytes = 1000` 假分母 →
`DownloadProgress.fractionOverride` 诚实轨道。闭环记录见
`docs/SLOP-AUDIT-2026-10-02-REV3-SOURCE.md` §5.1 与提交 `2af498f`）。

## 七、启动

历史上存在两套并行启动流程（`MinecraftInstance.launch()` 与 `slLaunchInternal()`）。
前者经全库零调用方核实后已于 2026-09 整段删除，现只剩 `slLaunchInternal()` 一条。

- `qwq/Features/Launch/`：`LaunchRequest`、`LaunchState`、`LaunchResult`、`LaunchError`、
  `LaunchPreflight`（client / library / asset / natives 四类校验拆分）、`LaunchArgumentBuilder`、
  `GameProcessController`、`GameSessionStore`、`LaunchService`
- `LaunchCoordinator` 只做"UI 意图 → 用例 → 状态映射"

遗留：`LaunchFix` 曾是"什么缺了都由我修"的上帝对象，已按四类校验拆分并完成接线
（P3-3 `c99c346` 拆分净行数 0；P2-1 `dee01ef` 接线：逻辑迁移到 `LaunchPreflight`
协议族默认实现，`LaunchFix.swift` 删除，跨层入口 `LaunchPreflightBridge`）。

## 八、测试与 CI

- 目录：`qwqTests/`，当前 **57 个测试文件**（用例数以 CI 结果为准）
- 跑法：`./scripts/verify-test.sh run`（真实 xcodebuild，编译 + 运行）
- 快速反馈：`./scripts/typecheck.sh`（`swiftc -typecheck` 两口径，比 xcodebuild 快一个数量级）
  - ⚠️ 它依赖 `/tmp/deps` 里由**上一次真实构建**产出的第三方 `.swiftmodule`；
    CI 是干净环境，故 CI 跑真实构建而非本脚本
- CI：`.github/workflows/test.yml`，push / PR 触发

**用例数不再手写进文档与提交信息**，以 CI 结果为准。

⚠️ 用例必须一律写成 `async`（同步用例里创建并释放 `@MainActor` 类实例会让宿主
abort，表现为"前几个测试类通过、之后无限重启"）。详见 `qwqTests/TESTING.md`。

## 九、工程纪律

### 重构的验收标准是减法

拆分文件**不是**重构成果。每个 `refactor` 提交的 `git diff --stat` 净行数应 ≤ 0。

反面教材（2026-09-21 `48ad4f4`）：提交标题为「NetDownloader 按职责拆分，889 行降至 166 行」，
但下载相关代码从 4663 行涨到 7886 行（+69%），旧路径仍在生效。
正确的成果指标是：**旧路径是否消失**、**净删多少行**、**调用方数量是否下降**。

### 不写描述目标结构的文档

文档只描述现状。`README-*.md` 若与实际不符，视为缺陷。

### 注释记录"为什么"

源码注释写约束与理由；考古过程（某个值历史上怎么丢的、哪个提交改的）写进 `docs/`。
单文件头部注释不宜超过 15 行。

## 十、遗留待办

**无**（2026-10-02 终态验收，六条全部处置完毕）：

1. `LaunchFix` 拆分 + 接线：**已完成**（P3-3 `c99c346` 净行数 0；P2-1 接线后
   `LaunchFix.swift` 删除，逻辑入 `DefaultLaunchPreflightImplementations.swift`）。
2. 下载双轨收口：**已决**——`NetManager` 保留为最终后端，批量路径不接入引擎
   （判据见 `MultiFileDownloader.start` 注释与 MIGRATION.md）。
3. `MultiFileDownloader` / 直连 `URLSession` 接入 `DownloadEngine`：**已否决**
   （同第 2 条；直连路径属探测/请求工具，非引擎职责）。
4. 账号伪实现：**已决（保留原样）**——`AnyAccount` 枚举形状保留为历史持久化数据
   解码兼容，运行期经 `unimplementedError` 显式告警 + 明确文案（SLOP-AUDIT REV3 C）；
   实现 OAuth 属新功能，超出收尾范畴。
5. 工程配置清理：**已完成**——`project.pbxproj` 已仅含 macOS 配置
   （`SDKROOT = macosx` + `SUPPORTED_PLATFORMS = macosx` 四处，无 iOS/visionOS 残留）。
6. UI 收口：**已完成**——`ContentView` 只保留窗口壳、导航、全局任务入口
   （163 行，只渲染只转发；业务决策全部外置到 NavigationState / DropInstallCoordinator /
   LaunchPanelState / DownloadDetailManager）。
