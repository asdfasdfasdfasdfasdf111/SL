# SL 架构与重构路线

## 一、目标

把项目从"功能堆叠 + 全局单例 + 兼容桩"的状态，收敛成**职责边界清晰、可独立维护、可测试**的模块化结构。

一句话：**每个模块只负责一类能力，对外只有稳定接口，内部允许自由修改。**

## 二、方向：编译期模块化

明确**不做**以下事情（至少当前阶段不做）：

- 动态 `.bundle` 加载
- `NSClassFromString` 运行时扫描
- XPC / 独立进程插件
- 插件市场、`Plugin.json` 清单机制
- Objective-C runtime 黑魔法

动态插件会带来代码签名、沙盒权限、Swift ABI 兼容、崩溃隔离等一整套成本，在工程边界尚未稳定时引入只会加剧混乱。

**做法**：Swift 模块 + 稳定协议 + 能力注册。

分层：

```
View → ViewModel → UseCase → Service → Infrastructure
```

跨模块只依赖协议与值类型，禁止直接访问其他模块的内部单例。

## 三、模块内核

- `qwq/Core/Module/SLModule.swift`
  - `SLModule`：模块注册入口
  - `ModuleCapabilityKey<Value>`：能力的类型化键
  - `ModuleContext`：**引用类型**。若改为值类型，模块内注册的能力只会写进副本，注册不生效
- `qwq/Core/Module/ModuleRegistry.swift`
  - `ModuleRegistry`：持有唯一 `ModuleContext`，登记模块
  - `AppModuleBootstrap`：模块装配清单，新增模块在此登记

新增模块的步骤：实现 `SLModule` → 在 `AppModuleBootstrap.makeRegistry()` 里加入列表 → 从 `ModuleContext` 解析使用。

## 四、设置层收口

- `qwq/Features/Settings/AppSettingsStore.swift`：设置数据的**唯一存储点**
  - 只负责设置数据的持有与持久化
  - 不持有 Java、下载、启动等业务状态
  - 复用项目既有的 `UDK` 键名，保证与旧数据兼容
- `ThemeManager` / `LauncherSettings`：暂时保留为**兼容层**，不再新增字段，逐步收窄后移除

## 五、Java 模块

问题：Java 数据源此前分裂成四套（`DataManager.javaVirtualMachines`、`LauncherSettings.availableJavaList`、`JavaManager`、`MinecraftInstance.findSuitableJava`），`SLLaunchBridge` 里还有一条四级降级链。

新增（`qwq/Features/Java/`）：

- `JavaInstallation`：统一的 Java 安装模型，可从 `JavaInfo` / `JavaVirtualMachine` 转换
- `JavaRequirement`：版本需求，含 MC 版本 → Java 版本推导规则
- `JavaRepository`：扫描与持久化（当前复用既有 `JavaManager` 扫描逻辑，仅做收口）
- `JavaResolver`：唯一选择入口 `resolve(_:)`
- `JavaModule`：模块注册

目标：启动器只调用 `JavaResolver`，不再有多级 fallback。

## 六、下载模块

问题：`NetDownloader.swift` 单文件 889 行，同时承担预检、多源、分片、重试、黑名单、测速、临时文件、合并、校验、调度、进度、取消清理。

新增（`qwq/Core/Download/`）：按职责拆分为 `DownloadRequest`、`DownloadProgress`、`DownloadState`、`DownloadError`、`DownloadTask`、`DownloadSourceResolver`、`DownloadSliceStore`、`DownloadMerger`、`DownloadVerifier`、`DownloadScheduler`、`DownloadEngine`。

原则：**本阶段不改下载算法，只拆职责、定边界**，让测试能挂上去。

## 七、启动模块

问题：历史上存在两套并行的启动流程（`MinecraftInstance.launch()` 与 `slLaunchInternal()`）。前者经全库零调用方核实后已于 2026-09 整段删除（属「运行期不可达」的死代码），现只剩 `slLaunchInternal()` 一条。`LaunchFix` 仍是"什么缺了都由我修"的上帝对象（待拆）。

新增（`qwq/Features/Launch/`）：`LaunchRequest`、`LaunchState`、`LaunchResult`、`LaunchError`、`LaunchPreflight`（含 client / library / asset / natives 四类校验的拆分）、`LaunchArgumentBuilder`、`GameProcessController`、`GameSessionStore`、`LaunchService`。

目标：`LaunchCoordinator` 只做"UI 意图 → 用例 → 状态映射"。原「合并两条流程」的目标已随旧流程删除而失去对象；真正遗留的是把 `LaunchFix` 按四类校验拆分。

## 八、测试

- 目录：`qwqTests/`
- 现有用例：Java 需求推导与选择策略、下载校验（SHA-1/SHA-256、大小、8MiB 流式）、分片合并、进度边界、状态与错误
- 加入 target 的步骤见 `qwqTests/TESTING.md`

## 九、迁移顺序

1. 冻结功能面（不新增主题、微软登录 UI、多目录、新动画）
2. 模块内核与设置收口 —— **已完成**
3. Java 模块 —— **结构已完成，待接线**
4. 下载模块 —— **结构已完成，待接线**
5. 启动模块 —— **结构已完成，待接线**
6. 账号与伪实现治理（`Stubs` 中 `AnyAccount.microsoft` / `.yggdrasil` 实为 `OfflineAccount`，需改为明确报错）
7. ModBrowser / Minecraft / Skin / Theme 模块化
8. UI 收口（`ContentView` 只保留窗口壳、导航、全局任务入口）
9. 工程配置清理（移除 `project.pbxproj` 中的 iOS / visionOS 配置，统一部署目标）

## 十、接线前的前置条件

新模块目前是"只新增、未接线"状态：既有代码行为完全未变。接线需要满足：

- 能对整个工程执行编译验证（当前受 Swift Package 依赖解析限制）
- `SLLaunchBridge` 的 Java 选择段是同步上下文（内部用 `DispatchSemaphore` 忙等扫描），改成 async resolver 需要同步改造整个桥接函数

因此接线按模块逐步进行，每接一处跑一次编译验证。
