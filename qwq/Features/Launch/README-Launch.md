# 启动用例层（Launch Use Case Layer）

本目录新增的一组文件是**启动流程的唯一用例层**。当前阶段只做「建立结构」：
**没有修改、删除任何既有文件，没有接线，行为零变化**。

## 一、为什么要建这一层

工程里现在有**两套并存且互相复制的启动流程**：

| | 原始 PCL.Mac 流程 | SL 新桥接流程 |
|---|---|---|
| 入口 | `MinecraftInstance.launch(_:)`（`SLCore/Minecraft/MinecraftInstance.swift`） | `slLaunch(...)` → `slLaunchInternal(...)`（`SLCore/SLLaunchBridge.swift`） |
| 调用方 | PCL.Mac 原有 UI | `LaunchCoordinator.start`（`Features/Launch/LaunchCoordinator.swift`） |
| 用户名校验 | `validateOfflineUsername` | `validateOfflineUsername`（重复实现） |
| 目录建实例 | 调用方持有 instance | 自己用 `MinecraftDirectory` + `MinecraftInstance.create` |
| 资源检查 | `MinecraftInstaller.createCompleteTask` | `LaunchFix.perform` |
| Java 选择 | `findSuitableJava` / `resolveAndApplyJava` | 自己等扫描 + 三级回退选 Java |
| 参数处理 | `MinecraftLauncher.buildJvmArguments` | 自己过滤 `--sun-misc-unsafe-memory-access` 等 |
| 进程与日志 | `MinecraftLauncher.launch` | 自己起 `Task` 轮询日志 / CGWindowList |

桥接层等于第二套启动实现，任何一处策略调整都要改两遍（历史上已经出现「改了旧流程没改桥接」的偏差）。
此外 `SLCore/Minecraft/Launch/LaunchFix.swift` 是「什么缺了都由我修」的上帝对象，
一个函数同时做 client / library / asset / natives 四类校验与安装，无法单独测试或替换其中一类。

## 二、本层的文件与职责

| 文件 | 内容 | 说明 |
|---|---|---|
| `LaunchRequest.swift` | `LaunchRequest`、`LaunchWindowSize` | 一次启动的完整入参，字段全部对齐现有真实入参（见文件头注释的来源对照） |
| `LaunchState.swift` | `LaunchState`、`LaunchProgressHandler` | 生命周期状态机，含文件校验 / Java 解析 / 进程结果 |
| `LaunchResult.swift` | `LaunchResult` | 退出码、会话 ID、日志路径、时长 |
| `LaunchError.swift` | `LaunchError` | 用例层失败原因（与 UI 侧 `LauncherError` 职责分开） |
| `LaunchPreflight.swift` | `ClientFileVerifier` / `LibraryFileVerifier` / `AssetFileVerifier` / `NativeInstaller` / `LaunchPreflight` / `DefaultLaunchPreflight` | 把 `LaunchFix.perform` 的四类职责拆成可替换实现 |
| `LaunchArgumentBuilder.swift` | `LaunchArgumentBuilder` | 参数组装，classpath 取 `[URL]`（对应 `MinecraftLauncher.buildClasspath()` 的中间形态） |
| `GameProcessController.swift` | `GameProcessController`、`ManagedProcess` | 进程拉起与终止观察的协议与最小封装 |
| `GameSessionStore.swift` | `GameSessionRecord` / `GameSessionStore` / `InMemoryGameSessionStore` | 运行中会话的登记、状态订阅、终止 |
| `LaunchService.swift` | `LaunchService` | 对外唯一入口 |

设计约束：

- 全部为值类型或 `Sendable` 协议 + 最小实现，可跨任务传递，不引入 SwiftUI / AppKit 依赖。
- 不引用 `SLModule`，不引用已被删除的 `CustomWindow.swift` / `JavaEnvironment.swift` / `JavaPathFinder.swift` / `LaunchPrecheck.swift`。
- 上下文类型（`LaunchPreflightContext` 等）刻意不直接持有 `MinecraftInstance`（非 `Sendable` 引用类型），
  由接线层从 instance / manifest 抽取为值类型快照后传入，校验器才能独立测试。

### 关于 ProcessPool

`Features/Launch/ProcessPool.swift` 已有进程池（并发上限、超时、命令白名单），
但它面向「短命令 + 收集 stdout」场景（`execute` / `executeForData` 同步返回），
而游戏进程是长驻进程、输出走日志文件、需要 termination 观察，形态不同。
因此 `GameProcessController` **只声明协议不造轮子**；
未来实现应在 ProcessPool 的并发上限与超时策略之上扩展（或让 ProcessPool 暴露
「长驻进程 + 输出句柄」的入口），而不是再起一套进程管理。

## 三、迁移步骤（后续执行，当前未做任何改动）

迁移分三步，每步都可独立验证、可回退，任一步出问题都不会影响另一套流程仍在跑。

### 第 1 步：让桥接层只做参数转换

- `SLLaunchBridge.swift` 中 `slLaunchInternal` 的职责收缩为：
  把 `version / username / gameDir` 等入参转换成一个 `LaunchRequest`，交给 `LaunchService.launch(_:)`，
  再把 `LaunchState` 流转回六段回调（progress / phase / log / success / ready / completion），供现有 UI 继续使用。
- 桥接层**不再**自己做用户名校验、建目录、建实例、选 Java、改 JVM 参数、监听日志；
  这些分别由用例层的 preflight、Java 选择、argument builder、session store 承担。
- 验收：UI 观感与退出码行为与现状一致（含「窗口出现即成功」「exitCode==0 兜底成功」的一次性门控语义）。
- 此时 `MinecraftInstance.launch(_:)` 仍保留，供 PCL.Mac 原有调用方使用。

### 第 2 步：让 LaunchCoordinator 只做 UI 意图转发

- `LaunchCoordinator.start` 不再直接调 `slLaunch`，而是构造 `LaunchRequest`
  （version / gameRoot / offlineUsername / javaExecutable / memoryMB …），调用 `LaunchService.launch(_:)`，
  并订阅 `GameSessionStore.observe(sessionID:)` 的 `AsyncStream<LaunchState>` 驱动 UI。
- `LaunchSessionManager`（`ObservableObject`）退化为适配器：订阅状态流 → 写 `@Published`，
  不再持有启动流程知识；`LaunchPhase` 由 `LaunchState` 派生。
- 用户名校验（`validateOfflineUsername`）、非法字符提示、皮肤/语言注入仍留在 UI 层，
  但只作为「发请求前的确认」，不再与启动流程耦合。
- 验收：多会话并存、日志 flush、关闭会话、电源按钮终止的行为与现状一致。

### 第 3 步：删除桥接层

- 确认无任何调用方后删除 `slLaunch` / `slLaunchInternal` 及 `SLLaunchBridge.swift` 中的兼容扩展
  （`isCancelled`、`isUserTerminated`、`terminate()`、`pendingLogs` 等 objc 关联对象实现）。
- `MinecraftInstance.launch(_:)` 中与新用例层重复的分支（资源检查、崩溃弹窗）下沉到用例层，
  或保留为 PCL.Mac 兼容性入口并标注废弃。
- `LaunchFix.perform` 的四段逻辑按 `LaunchPreflight.swift` 的四个协议拆分实现后，
  `LaunchFix` 降级为旧入口的转发壳，最终移除。

## 四、当前状态与注意事项

- 本目录文件**尚未加入 Xcode target**（`qwq.xcodeproj` 未被修改）。
  接线阶段需把上述 `.swift` 文件加入 target `qwq` 的 Compile Sources。

  > 更正：工程使用 `fileSystemSynchronizedGroups`（`qwq` 为同步文件夹），`qwq/` 下新增 `.swift`
  > 会自动进入 target，无需手工添加。

- 所有新文件均通过 `xcrun swiftc -typecheck -target arm64-apple-macosx13.0` 校验，无警告。
- 本层目前没有任何调用方，纯粹是结构准备；未改动任何既有行为。

  > 更新：**已完成「UI 启动入口改走 `LaunchService`」与「用户名校验上移到服务层」**。
  > 实际落地范围、逐条等价性论证、判断为「不做」的项与原因、新发现的缺陷、typecheck 结果、
  > 待真机验证清单，统一记录在 `Adapters/DUAL_FLOW.md` 第六节，本文件不再重复。
  >
  > 与上文第 2 步描述的差异：UI 侧暂**不**订阅 `AsyncStream<LaunchState>`，而是经由
  > `LaunchEvent` 兼容通道接收与旧 `slLaunch` 回调等时序的事件；
  > 原因见 DUAL_FLOW.md 第 6.1 节列出的风险点 T1 / T2 / T8 / T9。
