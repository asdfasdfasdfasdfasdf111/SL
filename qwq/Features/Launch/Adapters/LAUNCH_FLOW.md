# 启动流程现状与遗留缺口（LAUNCH_FLOW）

> **2026-09 变更**：原「流程 A」`MinecraftInstance.launch(_:)`（位于 `SLCore/Minecraft/MinecraftInstance.swift`）
> 经三次独立核实**零调用方**（全库 `.launch(` 的命中分别属于 `MinecraftLauncher.launch`、
> `LaunchService.launch`、`MinecraftInstanceLaunchService.launch(_:)`），**已整段删除**。
> 「双流程并存」的状态不复存在，故本文件由原名 `DUAL_FLOW.md` 更名为 `LAUNCH_FLOW.md`，
> 内容从「合并计划」改为「现状 + 遗留缺口」。
>
> **阅读须知**：下文凡标注「流程 A」的列与行号，都是**删除前的历史信息**，
> 不可按当前代码寻址；它们的作用是记录「曾经存在哪些能力、现在缺哪些」。
> 同理，文中指向 `SLLaunchBridge.swift` / `MinecraftLauncher.swift` / `LaunchFix.swift`
> 等文件的 `:行号` 也是**撰写当时的编号**——删除旧流程与兼容层死符号后，这些行号已整体漂移。
> 需要精确定位时请按**符号名**检索（例如 `options.skipResourceCheck = true`），不要按行号。

本文件回答四件事：

1. 当前唯一启动流程逐步做了什么；
2. 已删除的旧流程与之逐项对比（历史依据）；
3. **已删除流程独有的能力 —— 现在都成了没有实现的缺口**（当前最重要的一节）；
4. 当前流程的已知缺陷（D 系列）与风险点（R 系列）、补齐计划。

---

## 一、当前唯一流程

入口 `slLaunch` → `slLaunchInternal`（`SLCore/SLLaunchBridge.swift`），
调用方 `Features/Launch/LaunchCoordinator.swift`（经 `Adapters/MinecraftInstanceLaunchService.swift`
包装成 `LaunchService` 用例层）。

### 当前流程的逐步说明

| # | 步骤 | 当前实现 |
|---|---|---|
| 1 | 入口形态 | 回调式，`completion` 回传 `(MinecraftLauncher?, Result<Int32, Error>)` |
| 2 | 目录 / 实例 | 自建 `MinecraftDirectory` + `MinecraftInstance.create` |
| 3 | 用户名校验 | 已上移到服务层 `validatedUsername`；UI 侧 `LaunchCoordinator` 另有输入提示 |
| 4 | 账号与令牌 | `OfflineAccount` + `putAccessToken`（未实现账号的告警见 D6） |
| 5 | Java 选择 | 缓存校验 → `JavaResolverBridge` → `findSuitableJava` → `JavaManager` 兜底三级回退，含 3s 扫描等待 |
| 6 | 启动前文件处理 | `skipResourceCheck` 恒为 true 跳过安装任务，跑 `LaunchFix.perform` 只补缺失；另有客户端 JAR 存在性判定（D1 修复） |
| 7 | 清单/架构适配 | `ArtifactVersionMapper.map`，但**不写 `isUsingRosetta`** |
| 8 | JVM 参数过滤 | Java < 23 时过滤 `--sun-misc-unsafe-memory-access` |
| 9 | 参数组装 | `MinecraftLauncher.buildJvmArguments` / `buildClasspath` / `buildGameArguments` |
| 10 | 进程与日志落盘 | `MinecraftLauncher.launch`：Pipe + `readabilityHandler` → `GameLogs/<uuid>.log`；桥接**另外再读一次同一日志文件**做增量 tail |
| 11 | 窗口出现判定 | 桥接自己的 `windowTask` 轮询（2s 间隔）→ `launchSuccess` |
| 12 | 成功语义 | 「窗口出现」或「exitCode == 0」经一次性门控触发 `launchSuccess` |
| 13 | 异常退出处理 | 只把退出码交回 UI，由 `LaunchCoordinator` 弹 alert |
| 14 | 多开会话 | `launcher.currentProcess` + `pendingLogs` 暂存 |

---

## 二、与已删除的旧流程逐项对比（历史依据）

> 下表「流程 A」列的行号均为**删除前**的行号。保留本表是为了让后续读者知道
> 当前流程相对旧流程少做了什么、以及为什么某些能力现在缺失。

流程 A（已删除）：入口 `MinecraftInstance.launch(_:)`，调用方为旧 UI。

| # | 步骤 | 流程 A（已删除） | 流程 B（当前唯一） | 判定 |
|---|---|---|---|---|
| 1 | 入口形态 | `async` 方法，**无返回值**，退出码只在内部用于弹窗 | 回调式，`completion` 回传 `(MinecraftLauncher?, Result<Int32, Error>)` | 不一致：只有 B 能满足 `LaunchService` 契约 |
| 2 | 目录 / 实例 | 调用方已持有 `instance` | 自建 `MinecraftDirectory` + `MinecraftInstance.create` | 重复：实例创建曾两处实现 |
| 3 | 用户名校验 | `validateOfflineUsername(account.name)`，失败**只 log 后 return** | `validateOfflineUsername(safeUsername)`，失败 `completion(.failure)` | 重复且失败反馈不一致：A 静默、B 报错；UI 侧另有第三处同名校验 |
| 4 | 账号与令牌 | 未实现账号告警 + `putAccessToken` + yggdrasil 时预置 authlib-injector | 只有 `OfflineAccount` + `putAccessToken` | ⚠️ **能力缺口**：B 缺少「未实现账号」告警与 yggdrasil 分支（见 D6） |
| 5 | Java 选择 | **无独立步骤**，直接用 `config.javaURL`（由 `setup()` → `resolveAndApplyJava()` 决定） | 三级回退 + 3s 扫描等待 | B 独有；与 A 的 `resolveAndApplyJava` 逻辑重复 |
| 6 | 启动前文件处理 | 跑 `MinecraftInstaller.createCompleteTask` 全量安装任务 | `skipResourceCheck` 恒为 true 跳过安装任务，改跑 `LaunchFix.perform` 只补缺失 | ⚠️ **能力缺口**：A 有全量安装兜底，B 没有（见第三节） |
| 7 | 清单/架构适配 | `loadManifest()` + `ArtifactVersionMapper.map` + **写回 `isUsingRosetta`** | `ArtifactVersionMapper.map`，但**不写 `isUsingRosetta`** | ⚠️ **能力缺口**：B 路径下 `instance.isUsingRosetta` 恒为 false |
| 8 | JVM 参数过滤 | 无 | Java < 23 时过滤 `--sun-misc-unsafe-memory-access` | B 独有（改进） |
| 9 | 参数组装 | `MinecraftLauncher.buildJvmArguments` / `buildClasspath` / `buildGameArguments` | 同一组函数 | 一致（都以 `MinecraftLauncher` 为唯一实现） |
| 10 | 进程与日志落盘 | `MinecraftLauncher.launch`：Pipe + `readabilityHandler` → `GameLogs/<uuid>.log` | 同一函数；桥接**另外再读一次同一日志文件**做增量 tail | 重复：日志存在「落盘」与「读取」两条通道，读侧靠 `pendingLogs` 暂存补时序 |
| 11 | 窗口出现判定 | `MinecraftLauncher` 内部 Task 轮询，仅 `log("窗口已出现")`，不回调外部 | 桥接自己的 `windowTask` 轮询（2s 间隔）→ `launchSuccess` | 重复实现，且两处间隔不同（1s / 2s） |
| 12 | 成功语义 | 无 | 「窗口出现」或「exitCode == 0」经一次性门控触发 `launchSuccess` | B 独有 |
| 13 | 异常退出处理 | `exitCode != 0` → hint + 弹窗 + **可导出错误报告** | 只把退出码交回 UI，由 `LaunchCoordinator` 弹 alert | ⚠️ **能力缺口**：错误报告导出随 A 删除而失去唯一调用方 |
| 14 | 多开会话 | UI 直接持有 instance / process | `launcher.currentProcess` + `pendingLogs` 暂存 | B 独有补救（旧流程下 `instance.process` 会被同版本新启动覆盖） |

---

## 三、已删除流程独有的能力（现在是缺口，且没有实现作为参考）

删除流程 A 时，以下三项能力的**唯一调用点**都在 A 内部，因此它们现在**没有调用方**
（代码本身保留在工程里，作为后续补齐时的参考实现）：

| 能力 | 保留的符号 | 所在文件 | 现状 |
|---|---|---|---|
| 全量资源完整性检查 | `MinecraftInstaller.createCompleteTask` | `SLCore/Minecraft/Download/MinecraftInstaller.swift` | 无调用方；当前只有 `LaunchFix.perform` 的「只补缺失」 |
| 崩溃错误报告导出（zip：环境信息 + 启动命令 + 日志） | `MinecraftCrashHandler.exportErrorReport` | `SLCore/Minecraft/MinecraftCrashHandler.swift` | 无调用方；`MinecraftCrashHandler.lastLaunchCommand` 仍由 `MinecraftLauncher` 写入，链路是活的 |
| 崩溃弹窗（含「导出错误报告」按钮） | `PopupManager.showAsync` | `SLCore/Notices/Popup.swift` | 无调用方；底层 `NoticeCenter.presentAndWait` 随之失去唯一使用者 |

**重要**：这三项**不是「已修复」**。流程 A 从来没有被执行过，所以它提供的「兜底」本来就没生效；
删除它只是移除了**参考实现**，缺口照旧存在。

---

## 四、当前唯一流程的已知缺陷（D 系列）

- **D1 客户端 JAR 无任何校验与补全**：`LaunchFix.perform` 只处理 libraries / assets / natives，桥接又把 `skipResourceCheck` 恒置为 true（`SLLaunchBridge.swift` 的 `slLaunchInternal` 内 `options.skipResourceCheck = true`），于是缺失或损坏的 `<版本>.jar` 会一路进到 `Process.arguments`（classpath 末项）后由 JVM 报 `ClassNotFoundException` 崩溃。流程 A 有 `createCompleteTask` 兜底，流程 B 没有。
  - **已修复（桥接层）**：`slLaunchInternal` 在资源补全之后、`phaseHandler("launching")` 之前新增客户端 JAR 判定，路径取 `instance.runningDirectory/<instance.name>.jar`（与 `buildClasspath` 末项、`MinecraftInstaller.downloadClientJar` 落盘目标同一构造式），失败经 `LaunchError.fileVerificationFailed` 明确报错。判定口径为「存在且非空」，**不做 sha1 比对**（理由见风险点 R6）。仍然**没有**客户端 JAR 的自动补全步骤，缺失即失败。
- **D2 进程启动失败被伪装成异常退出**：`MinecraftLauncher.launch` 的 `catch` 分支走 `reportCompletion(Int32(1))`（`MinecraftLauncher.swift`），桥接的 `completion` 只看到 `.success(1)`，无法区分「进程没起来」与「游戏崩溃退出」，UI 一律显示「Minecraft 异常退出 (退出码: 1)」。
- **D3 正常退出时日志被删**：`MinecraftLauncher.swift` 在 `exitCode == 0` 时删除 `logURL` 文件，而桥接的日志 tail 任务与 UI 会话面板仍指向该文件；`LaunchResult.logURL` 因此可能指向一个已不存在的路径。
- **D4 日志尾部存在丢失窗口**：`MinecraftLauncher.launch` 在 `readabilityHandler = nil` 之后关闭句柄（`MinecraftLauncher.swift`），管道内尚未读取的数据会被丢弃；随后桥接的 tail 任务也可能读到不完整的文件末尾。
- **D5 Java 扫描等待是忙等**：桥接用「无人 signal 的 `DispatchSemaphore` 做 0.1s 睡眠」实现等待（`JavaManager.swift`），最坏空转 3s；同时扫描结果写回在主线程（`JavaManager.swift`），等待方在后台线程，时序正确但代价偏高。
- **D6 未实现账号缺少告警**：桥接只 `putAccessToken`，不检查 `account.unimplementedError`，用户使用微软账号时不会看到「尚未实现」提示（流程 A 有）。

---

## 五、补齐缺口的方案（原「合并方案」）

> 原方案的目标是「把两条流程合并成一份」。流程 A 已删除，**合并这件事不再存在**；
> 本节保留下来，作用变为**补齐第三节所列能力缺口的目标形态**——
> 即「这些能力将来应该由谁承担」。

目标形态是**一份** `LaunchService` 实现，桥接层退化为「参数转换 + 回调翻译」；
原属流程 A 的资源检查与崩溃弹窗，需要重新落到用例层（其参考实现仍在工程内，见第三节）。

| 步骤 | 目标由谁负责 | 对应现在的代码 |
|---|---|---|
| 1. 解析实例 | 服务层：`MinecraftDirectory` + `MinecraftInstance.create` | `SLLaunchBridge.swift` |
| 2. 用户名校验 | 服务层入口校验（UI 侧只做输入提示） | `SLCore/Account/OfflineAccount.swift` + `SLLaunchBridge.swift` |
| 3. 账号与令牌 | 服务层：`OfflineAccount` + `putAccessToken` + **未实现账号告警**（当前缺失，见 D6） | `SLLaunchBridge.swift`、原 `MinecraftInstance.swift`（已删） |
| 4. 启动前补齐 | `LaunchFixPreflight`（本目录）→ 内部委托 `LaunchFix.perform` | `SLLaunchBridge.swift` |
| 5. Java 解析 | 抽成独立解析器（`JavaResolverBridge` + `findSuitableJava` + `JavaManager` 兜底） | `SLLaunchBridge.swift`、`MinecraftInstance.resolveAndApplyJava()` |
| 6. 清单/架构适配 | 服务层：`ArtifactVersionMapper.map` + 参数过滤 + **`isUsingRosetta` 写回**（当前缺失） | `SLLaunchBridge.swift` |
| 7. 参数组装 | `MinecraftLauncher.buildJvmArguments` / `buildClasspath` / `buildGameArguments`（保留不动） | `MinecraftLauncher.swift` |
| 8. 拉起进程 | `ProcessPoolGameProcessController` + `ProcessPool` 新增长驻入口 | `MinecraftLauncher.swift` |
| 9. 日志 | 直写文件句柄（替代 Pipe + readabilityHandler + tail 双通道） | `MinecraftLauncher.swift`、`SLLaunchBridge.swift` |
| 10. 成功判定 | 窗口检测下沉为服务的 `.running` 事件 | `SLLaunchBridge.swift` |
| 11. 退出与结果 | `LaunchResult(exitCode:sessionID:logURL:duration:)` + 统一一份异常退出处理 | `SLLaunchBridge.swift`、`MinecraftInstance.swift` |
| 12. 会话与终止 | `GameSessionStore` 登记 + 终止必须走 `MinecraftLauncher.terminate()` | `SLLaunchBridge.swift`、`LaunchCoordinator.swift` |

最终 `LaunchService.launch(_:)` 的步骤顺序（与现状一致，不得重排）：

```
解析实例
  → 用户名校验（失败：LaunchError.unknown / 专用 case）
  → 账号令牌
  → LaunchFixPreflight.prepare()          // client → libraries → assets → natives
  → Java 解析（含扫描等待）
  → 清单加载 + 架构映射 + JVM 参数过滤
  → 参数组装
  → 进程拉起（ProcessPool）
  → 窗口检测 → .running
  → 等待退出 → LaunchResult（或启动失败抛错）
```

---

## 六、风险点（R 系列）

### R1 顺序不可变

1. **`LaunchFix` 内部顺序**：资源索引必须先于 objects 校验/补齐（`LaunchFix.swift`），否则新下载的索引无法参与对象比对。
2. **natives 必须在支持库之后**：`MinecraftInstaller.ensureNatives` 依赖 `libraries` 下的 native jar 已存在，提前解压会失败。
3. **`LaunchFix` 必须早于 Java 解析**：现状是「先补文件、再选 Java」（`LaunchFix.swift`）。若调换，用户在缺库时会先看到 Java 相关报错，属行为变化。
4. **架构映射（`ArtifactVersionMapper.map`）必须早于参数组装**，且早于任何依赖 `instance.manifest` 库列表的操作（它会改写 manifest 的库与参数）。

### R2 回调时序敏感点

| 编号 | 敏感点 | 现象 | 合并时的处理 |
|---|---|---|---|
| T1 | `phaseHandler("launching")` 在 **Java 选择之前**发出（`SLLaunchBridge.swift`） | 该相位名与「正在拉起进程」不等价 | 保留原始相位语义，`LaunchState` 侧映射为 `.resolvingJava`（见 `MinecraftInstanceLaunchService.swift` 映射表） |
| T2 | `onLauncherReady` 在 `launcher.launch` **之前**触发（`SLLaunchBridge.swift` vs `MinecraftLauncher.swift`） | 此刻 `currentProcess` 仍为 nil，无法构造 `ManagedProcess` | 包装层轮询等待进程出现后再登记会话；合并时应让进程创建早于该回调 |
| T3 | `launchSuccess` 可能**永不触发**（游戏无窗口 / 秒退） | UI 停在「启动中」 | 必须保留「`exitCode == 0` 兜底触发」语义（`MinecraftLauncher.swift`） |
| T4 | 窗口检测与退出兜底**竞争** `successGate`（`MinecraftLauncher.swift`） | 重复复位 UI | 一次性门控不能省；`LaunchService` 侧同样只能发一次 `.running` |
| T5 | 日志 tail 任务在退出时被 cancel（`MinecraftLauncher.swift`） | 尾部日志可能丢 | 合并采用「直写文件句柄」后天然消除；沿用 Pipe 方案时必须「先 drain、再置 nil handler」 |
| T6 | `exitCode == 0` 时日志文件被删（`MinecraftLauncher.swift`） | 会话面板读不到日志 | 合并时取消删除，或把清理动作推迟到会话移除之后 |
| T7 | 进度回调频率（`LaunchFix` 按文件回调，资源可达数千项） | 逐条投递会创建数千个 Task | 包装层已按 1% 阈值合并；合并后应由状态机自身节流 |
| T8 | 状态投递是异步 `Task`，顺序不严格 | 可能出现进度回跳 | UI 侧保留「只前进」钳制；`.running` / `.finished` 等终态必须与 `observe` 订阅时序对齐 |
| T9 | `InMemoryGameSessionStore` 无状态重放（`GameSessionStore.swift`） | 晚订阅的 UI 看不到早期状态 | 合并阶段需给 store 加「最近一次状态缓存」或要求先订阅后启动 |

### R3 终态与终止

- **终止只能走 `MinecraftLauncher.terminate()`**（`SLLaunchBridge.swift`），它会同时置 `isUserTerminated`；直接 `Process.terminate()` 会让 completion 把「用户主动关闭」判为异常退出并弹错误框。
- 因此 `GameSessionStore.terminate(sessionID:)`（内部只做 `ManagedProcess.terminate()`）不能作为游戏会话的终止路径，包装层 `terminate(sessionID:)` 绕开了它。**合并时要么给 `ManagedProcess` 增加 `onBeforeTerminate` 钩子，要么让 store 保存终止闭包而不是 `Process`。**

### R4 `skipResourceCheck` 语义歧义

`LaunchRequest.skipResourceCheck` 来源于 `LaunchOptions.skipResourceCheck`，而桥接把它恒置为 true（`SLLaunchBridge.swift`），本意是「跳过 `MinecraftInstance.launch` 内的 `createCompleteTask`」，与「是否执行 `LaunchFix`」无关。`DefaultLaunchPreflight` 却把它当作「跳过整个 preflight」的开关（`LaunchPreflight.swift`）。若照搬，桥接路径会完全跳过启动前补齐。**合并前必须改名或拆成两个字段**（例如 `skipInstallTaskCheck` / `skipPreflightRepair`）。

### R5 错误类型缺失

桥接的失败是 `MyLocalizedError(reason: "中文文案")`，没有类型化错误码，包装层只能按文案前缀映射（`MinecraftInstanceLaunchService.mapFailure`）。文案一改就静默退化为 `.unknown`。**合并时桥接/服务必须直接抛 `LaunchError`。**

### R6 客户端 JAR 校验会引入新的失败路径

`LaunchFixClientVerifier` 一旦接线，缺失 client JAR 的实例会从「启动后崩溃」（D1 现状）变成「启动前报错」。这是**行为变化**，需产品决策：要么同时补一个客户端 JAR 下载步骤（推荐），要么把该校验降级为告警。
当前落地口径（桥接层 D1 修复）：缺文件即**启动前失败**（未降级为告警，也尚未补下载步骤），且判定不采用 sha1——加载器实例的版本目录 JAR 会被安装器就地改写，其哈希与合并清单继承来的父级 `clientDownload.sha1` 不同，按 sha1 判定会误伤可正常启动的 Forge 等实例。因此 `LaunchFixClientVerifier` 的 sha1 校验仍**不得**直接接到加载器路径上。

### R7 `GameProcessController` 协议参数缺口

现有协议没有**工作目录**与**输出句柄**两个参数：

- 工作目录：现有实现设置 `process.currentDirectoryURL = instance.runningDirectory`（`MinecraftLauncher.swift`），游戏读取 `options.txt`、写 `crash-report` 都依赖它；
- 输出句柄：若不接管道且无人读取，64KB 管道缓冲写满后**游戏会阻塞**；本适配器改为直写日志文件句柄以规避。

合并前需扩展协议签名，否则 `ProcessPoolGameProcessController` 无法等价替代 `MinecraftLauncher.launch`。

### R8 `ProcessPool` 缺少长驻进程入口

`ProcessPool` 的 `execute` / `executeForData` 都是「同步短命令 + 收集输出」，且内部 `semaphore.wait()` 会占用并发额度；承载策略的三个成员（`maxConcurrent` / `semaphore` / `allowedCommands`）均为 private，外部无法在不修改 `ProcessPool` 的前提下把长驻游戏进程纳入池。建议入口：

```swift
func launchLongRunning(_ executable: URL, args: [String],
                       environment: [String: String],
                       stdout: FileHandle?) throws -> Process
```

### R9 Java 扫描等待的线程约束

`preScanJavaAsync` 的结果写回在**主线程**（`JavaManager.swift`）。合并后如果 `LaunchService.launch` 在主线程同步等待扫描结果，会直接死锁。等待必须发生在非主线程，或改为 `await` 一个由扫描完成信号驱动的续体。

---

## 七、分步补齐计划

每一步都可独立编译、可回退（回退 = 撤销该步的单个替换点），且任一步出问题时另一条流程仍可用。

### 第 0 步（本次已完成）：新增适配器，零接线

- 内容：三个适配器文件 + 本文件。
- 编译验证：`xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps $(find qwq -name "*.swift")` → exit 0、error 0、新增文件零告警。
- 回退：删除 `Adapters/` 目录。
- 真机验证：**不需要**（无调用方）。

### 第 1 步：桥接层改用 `LaunchFixPreflight`

- 改动：`slLaunchInternal` 中 `LaunchFix.perform(instance:)` 一处替换为 `LaunchFixPreflight(...).prepare(request)`（含 600s 超时语义保留在调用处）。
- 回退：还原这一处替换。
- 验证人：开发者先跑 typecheck；**必须真机**验证四类场景：① 文件完整的版本正常启动；② 手工删除一个 libraries 文件后启动（应自动补齐）；③ 手工删除 `assets/indexes/<id>.json` 后启动（应先补索引再补资源）；④ 手工清空 `natives/` 后启动（应重新解压）。
- 注意：第 1 步**不要**同时启用 `LaunchFixClientVerifier`（R6 需先决策）。

### 第 2 步：`ProcessPoolGameProcessController` 替代进程创建

- 前置：给 `ProcessPool` 增加长驻入口（R8）、给 `GameProcessController` 补工作目录与输出句柄参数（R7）。
- 回退：`MinecraftLauncher.launch` 内的 `Process()` 创建段还原。
- 验证人：**必须真机**验证：① 游戏能拉起并正常进入主菜单；② 日志文件内容完整（对比退出前后行数，重点看最后 20 行是否有 D4 类丢失）；③ 关闭会话按钮能终止进程且**不弹**「异常退出」；④ 强制杀掉 java 后 UI 能复位。

### 第 3 步：Java 解析统一

- 改动：把桥接的三级回退与 `resolveAndApplyJava` 合并为一个解析器，两条流程共用。
- 回退：桥接侧恢复原三级回退。
- 验证人：**必须真机**覆盖：① 仅装 Java 8 的 1.20 版本（应报「未找到满足版本要求」）；② 同时装 Java 8/17/21（应选 21 且满足最低要求）；③ x86_64 Java 在 Apple Silicon 上（应走 Rosetta 分支）；④ 首次启动且 `DataManager.javaVirtualMachines` 为空（扫描等待时序，对应 R9）。

### 第 4 步：`LaunchCoordinator` 改为调用 `LaunchService`

- 改动：UI 只构造 `LaunchRequest` 并订阅 `GameSessionStore.observe(sessionID:)`；`LaunchSessionManager` 退化为 `@Published` 适配器。
- 回退：恢复 `slLaunch` 六段回调接线。
- 验证人：**必须真机**验证：① 多开两个不同版本；② 日志面板实时刷新与暂存 flush（T5/T9）；③ 电源按钮终止全部；④ 启动过程中切换分类页再回来（回调不丢）；⑤ 用户名为空 / 含非法字符 / 超 16 字符三条校验分支提示正确。

### 第 5 步：删除桥接层

- 前置：第 4 步稳定运行一个版本周期，且确认 `slLaunch` 无其它调用方。
- 改动：删除 `SLLaunchBridge.swift`；`LaunchFix` 降级为转发壳后移除。
- ~~`MinecraftInstance.launch(_:)` 的资源检查与崩溃弹窗下沉或标注废弃~~
  **→ 已于 2026-09 完成（该方法是死代码，直接整段删除）。** 注意：
  随它一起失去调用方的三项能力（见第三节）**尚未**补进当前流程，属未完成项。
- 验证人：**必须真机**做一轮完整回归（安装新版本 → 补全 → 启动 → 进服 → 退出）。

### 必须真机、无法用编译/单测覆盖的项（汇总）

进程能否真正拉起、窗口出现检测（CGWindowList）、Rosetta 转译路径、Java 扫描等待时序、日志完整性与 flush 时序、进程退出与 completion 的先后、多开与终止时的 UI 复位。

---

## 八、当前状态

- `qwq.xcodeproj/project.pbxproj` 使用 `fileSystemSynchronizedGroups`（`qwq` 为同步文件夹），
  `qwq/` 下的 `.swift` 自动进入 target，**无需**手工添加 Compile Sources。
  （本节曾记录「三个适配器尚未加入 Xcode target」，该判断已被证实有误，已删除。）
- 全部文件通过双口径 typecheck（0 错误，告警数与基线逐条一致）。
- 未引用任务约束中列出的四个已删除文件（App 层窗口封装、旧 Java 环境 / 路径发现、旧启动预检）。

---

## 九、接线落地记录（第 4 步的子集 + 第 0 步已完成的适配层）

### 9.1 已完成的改动

| 改动 | 文件 | 内容 | 等价性结论 |
|---|---|---|---|
| UI 启动入口改走用例层 | `Features/Launch/LaunchCoordinator.swift` | `start` 不再调用 `slLaunch`，改为构造 `LaunchRequest` + `MinecraftInstanceLaunchService(events:)` + `Task { await service.launch(request) }` | **等价**：事件处理逐条照搬原六段回调（同一 `DispatchQueue.main.async` 包裹、同一动画参数、同一文案、同一 `boundLauncher` 同步绑定语义）；皮肤包 / options.txt 写入、用户名提示对话框、非法字符确认框均未改动 |
| 事件兼容通道 | `Features/Launch/Adapters/MinecraftInstanceLaunchService.swift` | 新增 `LaunchEvent` / `LaunchEventHandler`，在 `slLaunch` 各回调**原调用点同步投递** | **等价**：投递点与线程同旧回调；`.failed` 携带桥接层原始 `Error`，故 UI 文案不变（不经过 `LaunchError` 的文案归一化） |
| 用户名校验上移 | `SLLaunchBridge.swift`、`MinecraftInstanceLaunchService.swift` | 桥接层首段的 trim / `"Player"` 兜底 / `validateOfflineUsername` 判定整体上移到服务层 `validatedUsername` | **等价**：判定函数与兜底逐条一致，仍在实例解析之前执行（失败时机不变）；失败时 launcher 尚未建立，旧路径与新路径 UI 均不提示。唯一差异是错误载体由 `MyLocalizedError` 变为 `LaunchError`（不改变 UI 可见行为，且是风险点 R5 的整改方向） |

`LaunchEvent` 之所以不是 `LaunchState`：T1（`phaseHandler("launching")` 早于 Java 选择，若由 `.resolvingJava` 驱动 UI，UI 的「launching」相位会推迟到 `onLauncherReady` 之后）、T2（UI 需要 `MinecraftLauncher` 引用做会话绑定与终止，而 `LaunchState` 不携带引用）、T8 / T9（状态由松散 `Task` 投递且无重放）。这四点未解决前，直接改状态驱动会引入用户可感知的时序变化。

### 9.2 判断为「本次不做」的项与原因

| 项 | 结论 | 原因 |
|---|---|---|
| 目录准备（`MinecraftDirectory` + `MinecraftInstance.create`）上移到服务层 | **保留在桥接层** | `MinecraftInstance.create` → `setup()` 含多次文件读写、`loadManifest()`（含 `inheritsFrom` 合并）、`resolveAndApplyJava()` 与 `saveConfig()`（写盘）。桥接层把这些放在 GCD 线程；服务层 `launch` 的执行上下文不在 `LaunchService` 契约中（工程设置 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 下与调用方同属主 actor），上移会把同步 I/O 落到调用方线程，最坏情况是主线程。**无法在不引入线程行为变化的前提下确认等价，故保留。** 安全的上移方式：先让桥接层接受「已解析实例」（`slLaunch(instance:…)`）并给服务层一个显式的后台执行上下文，再迁移 |
| Java 扫描等待（`preScanJavaAsync` + 3s 等待）上移 | **保留在桥接层** | ① R9：扫描结果在**主线程**回写（`JavaManager.swift`），服务层若在主 actor 上做同步等待会直接死锁；② 时序变化：现状是「先补文件、再等扫描」，上移后等待发生在补全之前，用户会在启动初期先停顿最多 3s，属可感知变化 |
| 双份失败处理 / 日志双通道 / 重复窗口检测（表中第 10、11、13 行） | **本次不做** | 需要改 `MinecraftLauncher.swift`、`MinecraftInstance.swift`，不在本次允许修改的范围内 |

### 9.3 本次发现的真实缺陷

- **D7 会话「运行中」标志恒为 false（已修复）**：`GameSession.isProcessRunning` 初始化 `false`（`GameSession.swift`），全代码库**没有任何位置将其置为 `true`**。后果：
  - `LaunchCoordinator.closeSession`（`LaunchCoordinator.swift`）的 `if session.isProcessRunning` 恒不成立 → 点日志卡关闭按钮**不会终止游戏进程**，只移除卡片；
  - `LaunchCoordinator.handlePowerTap`（`LaunchCoordinator.swift`）过滤 `isProcessRunning` 恒为空 → 电源按钮走「取消启动并复位」分支，**不会终止全部游戏**；
  - `SessionLogCardView.swift` 的提示恒为「移除此日志」；`LaunchSessionManager.hasRunningSessions` 恒 false。

  **修复（LaunchCoordinator.swift `.running` 分支）**：进程确认拉起（窗口出现，或退出码 0 兜底）时置 `isProcessRunning = (launcher.currentProcess?.isRunning ?? false)`。取值读 launcher 自身 `currentProcess` 的实时状态，故退出码 0 兜底触发的「已退出」不会被误置为运行中；终止路径仍走 `MinecraftLauncher.terminate()`（`SLLaunchBridge.swift`，内部 `currentProcess?.terminate()` + 置 `isUserTerminated`），**不是** `instance.process`，因此多开时各会话只终止自己的进程。标志的写入口已在 `GameSession.swift` 注释中固定为 `LaunchCoordinator` 单一归属。
  - 未覆盖的边界（属 T3 既有风险，不在本次范围）：窗口始终未被 `CGWindowList` 检测到的进程不会有 `.running`，该会话仍不可终止；「启动中取消」原依赖的 `MinecraftLauncher.isCancelled` no-op 桩**已在重构中删除**（当前代码库已无此属性，仅存 `Task.isCancelled`），故该路径不再存在；启动中取消现由 Swift `Task` 取消语义承载。
- **D8 早期失败静默（已修复）**：`launcher` 尚未建立时的失败（用户名 / 实例 / Java / 文件补全 / 客户端 JAR）经 `completion(nil, .failure)` 回传，而 UI 的处理全部位于 `if let launcher` 内 → 既不弹提示也不复位进度条，界面停在「启动中」。
  **修复（LaunchCoordinator.swift）**：新增 `reportLaunchFailure`（复用既有 `LaunchPanelState.presentError`，与 launcher 已建立时的失败同一呈现通道，故不改动任何文案），`.failed` 事件不再以 `boundLauncher` / 会话存在为前置条件；`Task { try? await … }` 改为 `do/catch`，把用例层在进入桥接之前抛出的失败（离线用户名非法）也纳入同一通道；两条通道共用一次性门控 `LaunchFailureNoticeGate`，避免同一次启动弹两次提示。进度经 `resetProgress()` + `launchPhase = .idle` 复位。文案仍是桥接层原始描述，与 D2 的「启动失败 vs 异常退出」区分口径一致。
  - 未改动的部分：桥接层各失败分支的文案（已含下一步指引，如 Java 未命中的「请先在「Java 管理」中扫描或下载 Java」、客户端 JAR 缺失的「请在「下载」页重新安装该版本」）。

### 9.4 本次验证

- 类型检查（不跑 `xcodebuild`，避免与测试 target 的验证互相干扰）：
  - 任务给定配置：`exit 0`、`error 0`、告警 **44**（与改动前逐条一致）；
  - 工程真实并发设置（`-swift-version 5 -default-isolation MainActor`）：`exit 0`、`error 0`、告警 **88**（与改动前逐条一致）。
- 仍未接入：`GameSessionStore`（UI 尚未订阅状态流），故本次服务实例以 `sessionStore: nil` 构造，状态流通道为空转。
- 终止路径未变：UI 仍调 `session.launcher.terminate()`；`LaunchService.terminate(sessionID:)` 尚未被 UI 使用（R3 未解决前不能换）。

### 9.5 需要真机验证的项（本次改动相关）

1. 正常启动：日志面板逐行刷新时序与暂停 / 恢复（旧路径的 `pendingLogs` 暂存 flush 是否仍无丢行）；
2. 退出：`exitCode == 0` 自动清卡片、非 0 弹「Minecraft 异常退出 (退出码: N)」文案与旧版一字不差；
3. 进程未拉起（如把 Java 路径改成不可执行文件）：应弹「启动失败：…」而非「异常退出」；
4. Java 未安装（D8）：应弹「未找到满足版本要求 (Java N+) 的 Java 安装，请先在「Java 管理」中扫描或下载 Java。」，且启动按钮与进度条**回到初始态**（不再停在「启动中」）；确认同一次启动只弹一次提示；
5. 客户端 JAR 缺失（D8）：应弹「启动前文件校验失败：客户端 JAR 缺失或损坏：…」同上复位；
6. 正常运行中的终止（D7）：① 日志卡关闭按钮 xmark → 进程被 `SIGTERM` 终止、卡片消失、**不弹**「异常退出」；② 电源按钮 → 全部游戏被终止、日志面板收起；③ 悬浮提示在运行阶段为「关闭此游戏进程 / 关闭所有游戏」，启动阶段仍为「移除此日志 / 取消启动」；
7. 多开两个不同版本（D7）：两条启动互不串台，分别点关闭时**只终止被点的那一个**进程（其余会话与日志不受影响），电源按钮才终止全部；
8. 游戏自行退出后（D7）：`isProcessRunning` 回落到 false，电源按钮在无会话时不再显示；
9. 启动过程中切换分类页再回来：回调不丢（事件处理零视图捕获）；
10. 用户名三条校验分支（空 / 含 `"` / 超 16 字符）与非法字符确认框；
11. 游戏根目录为空（未配置目录）时点击启动：确认行为与改动前一致（本次 `gameRoot` 由 `URL(fileURLWithPath:)` 承接路径字符串，空串会退化为工作目录，此边界不可达但需在真机确认无副作用）。
