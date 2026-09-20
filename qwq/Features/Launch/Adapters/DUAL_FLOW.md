# 双流程并存说明与合并方案（DUAL_FLOW）

本文件回答四件事：

1. 现有两条启动流程逐步做了什么、哪里重复、哪里不一致；
2. 合并后 `LaunchService` 的完整流程，以及每一步对应**现在哪段代码**；
3. 合并的敏感点：哪些步骤顺序不能变、哪些回调时序不能动；
4. 分步合并计划（每步可编译、可回退）与验证责任人。

本阶段（当前提交）只新增适配器，**没有修改任何既有文件，没有切换任何调用方**：

| 新增文件 | 作用 |
|---|---|
| `Adapters/LaunchFixPreflight.swift` | `LaunchPreflight` 及 client / library / asset / natives 四类子协议的 LaunchFix 适配实现 |
| `Adapters/ProcessPoolGameProcessController.swift` | `GameProcessController` 的进程池适配实现 |
| `Adapters/MinecraftInstanceLaunchService.swift` | `LaunchService` 对现有 `pclLaunch` 的包装实现 |
| `Adapters/DUAL_FLOW.md` | 本文件 |

被包装对象一行未动：`PCLLaunchBridge.swift`、`LaunchFix.swift`、`MinecraftInstance.swift`、`LaunchCoordinator.swift`、`ProcessPool.swift`。

---

## 一、两条流程逐步对比

流程 A（PCL.Mac 原始）：入口 `MinecraftInstance.launch(_:)`
（`PCLCore/Minecraft/MinecraftInstance.swift:280-364`），调用方为 PCL.Mac 原有 UI。

流程 B（SL 桥接）：入口 `pclLaunch` → `pclLaunchInternal`
（`PCLCore/PCLLaunchBridge.swift:52-329`），调用方为 `Features/Launch/LaunchCoordinator.swift:48`。

| # | 步骤 | 流程 A（原始） | 流程 B（桥接） | 判定 |
|---|---|---|---|---|
| 1 | 入口形态 | `async` 方法，**无返回值**，退出码只在内部用于弹窗 | 回调式，`completion` 回传 `(MinecraftLauncher?, Result<Int32, Error>)` | 不一致：只有 B 能满足 `LaunchService` 契约 |
| 2 | 目录 / 实例 | 调用方已持有 `instance` | 自建 `MinecraftDirectory` + `MinecraftInstance.create`（`:105-113`） | 重复：实例创建两处实现 |
| 3 | 用户名校验 | `validateOfflineUsername(account.name)`，失败**只 log 后 return**（`:293-297`） | `validateOfflineUsername(safeUsername)`，失败 `completion(.failure)`（`:97-103`） | 重复且失败反馈不一致：A 静默、B 报错；UI 侧 `LaunchCoordinator:22-28` 还有第三处同名校验 |
| 4 | 账号与令牌 | 未实现账号告警 + `putAccessToken` + yggdrasil 时预置 authlib-injector（`:285-307`） | 只有 `OfflineAccount` + `putAccessToken`（`:116-120, 156`） | 不一致：B 缺少「未实现账号」告警与 yggdrasil 分支 |
| 5 | Java 选择 | **无独立步骤**，直接用 `config.javaURL`（由 `setup()` → `resolveAndApplyJava()` 决定，`:308`） | 缓存校验 → `JavaResolverBridge` → `findSuitableJava` → `JavaManager` 兜底三级回退，并含 3s 扫描等待（`:160-222`） | B 独有；与 A 的 `resolveAndApplyJava` 逻辑重复（都做「缓存沿用 + findSuitableJava」） |
| 6 | 启动前文件处理 | `!config.skipResourcesCheck && !options.skipResourceCheck` 时跑 `MinecraftInstaller.createCompleteTask` 全量安装任务（`:320-327`） | `skipResourceCheck` 恒为 true 跳过安装任务，改跑 `LaunchFix.perform` 只补缺失（`:121, 126-149`） | 两套引擎并存；且 B 路径**从不校验客户端 JAR**（见 D1） |
| 7 | 清单/架构适配 | `loadManifest()` + `ArtifactVersionMapper.map` + 写回 `isUsingRosetta`（`:310-318`） | `ArtifactVersionMapper.map`，但**不写 `isUsingRosetta`**（`:235-241`） | 不一致：B 路径下 `instance.isUsingRosetta` 恒为 false |
| 8 | JVM 参数过滤 | 无 | Java < 23 时过滤 `--sun-misc-unsafe-memory-access`（`:245-254`） | B 独有 |
| 9 | 参数组装 | `MinecraftLauncher.buildJvmArguments` / `buildClasspath` / `buildGameArguments` | 同一组函数 | 一致（都以 `MinecraftLauncher` 为唯一实现） |
| 10 | 进程与日志落盘 | `MinecraftLauncher.launch`：Pipe + `readabilityHandler` → `GameLogs/<uuid>.log` + `LogStore.raw()` | 同一函数；桥接**另外再读一次同一日志文件**做增量 tail（`:276-296`） | 重复：日志存在「落盘」与「读取」两条通道，读侧靠 `pendingLogs` 暂存补时序 |
| 11 | 窗口出现判定 | `MinecraftLauncher` 内部 Task 轮询，仅 `log("窗口已出现")`，不回调外部（`MinecraftLauncher.swift:104-120`） | 桥接自己的 `windowTask` 轮询（2s 间隔）→ `launchSuccess`（`:299-317`） | 重复实现，且两处间隔不同（1s / 2s） |
| 12 | 成功语义 | 无 | 「窗口出现」或「exitCode == 0」经一次性门控触发 `launchSuccess`（`:263-271, 325`） | B 独有 |
| 13 | 异常退出处理 | `exitCode != 0` → hint + 弹窗 + 可导出错误报告（`:331-362`） | 只把退出码交回 UI，由 `LaunchCoordinator:139-153` 弹 alert | 重复：两份异常退出处理 |
| 14 | 多开会话 | UI 直接持有 instance / process | `launcher.currentProcess` + `pendingLogs` 暂存 | B 独有补救（原始流程下 `instance.process` 会被同版本新启动覆盖） |

### 流程 B 中已发现的真实缺陷（非重构问题）

- **D1 客户端 JAR 无任何校验与补全**：`LaunchFix.perform` 只处理 libraries / assets / natives，桥接又把 `skipResourceCheck` 恒置为 true（`:121`），于是缺失或损坏的 `<版本>.jar` 会一路进到 `Process.arguments`（classpath 末项）后由 JVM 报 `ClassNotFoundException` 崩溃。流程 A 有 `createCompleteTask` 兜底，流程 B 没有。
- **D2 进程启动失败被伪装成异常退出**：`MinecraftLauncher.launch` 的 `catch` 分支走 `reportCompletion(Int32(1))`（`MinecraftLauncher.swift:145-158`），桥接的 `completion` 只看到 `.success(1)`，无法区分「进程没起来」与「游戏崩溃退出」，UI 一律显示「Minecraft 异常退出 (退出码: 1)」。
- **D3 正常退出时日志被删**：`MinecraftLauncher.swift:136-139` 在 `exitCode == 0` 时删除 `logURL` 文件，而桥接的日志 tail 任务与 UI 会话面板仍指向该文件；`LaunchResult.logURL` 因此可能指向一个已不存在的路径。
- **D4 日志尾部存在丢失窗口**：`MinecraftLauncher.launch` 在 `readabilityHandler = nil` 之后关闭句柄（`MinecraftLauncher.swift:134-135`），管道内尚未读取的数据会被丢弃；随后桥接的 tail 任务也可能读到不完整的文件末尾。
- **D5 Java 扫描等待是忙等**：桥接用「无人 signal 的 `DispatchSemaphore` 做 0.1s 睡眠」实现等待（`:164-168`），最坏空转 3s；同时扫描结果写回在主线程（`JavaManager.swift:41-45`），等待方在后台线程，时序正确但代价偏高。
- **D6 未实现账号缺少告警**：桥接只 `putAccessToken`，不检查 `account.unimplementedError`，用户使用微软账号时不会看到「尚未实现」提示（流程 A 有）。

---

## 二、合并方案：最终 `LaunchService` 的完整流程

目标形态是**一份** `LaunchService` 实现，桥接层退化为「参数转换 + 回调翻译」，`MinecraftInstance.launch(_:)` 的资源检查与崩溃弹窗下沉到用例层（或标注废弃）。

| 步骤 | 合并后由谁负责 | 对应现在的代码 |
|---|---|---|
| 1. 解析实例 | 服务层：`MinecraftDirectory` + `MinecraftInstance.create` | `PCLLaunchBridge.swift:105-113` |
| 2. 用户名校验 | 服务层入口校验（UI 侧只做输入提示） | `PCLStubs.swift:155` + `PCLLaunchBridge.swift:97-103` |
| 3. 账号与令牌 | 服务层：`OfflineAccount` + `putAccessToken` + 未实现账号告警 | `PCLLaunchBridge.swift:116-120, 156`、`MinecraftInstance.swift:285-307` |
| 4. 启动前补齐 | `LaunchFixPreflight`（本目录）→ 内部委托 `LaunchFix.perform` | `PCLLaunchBridge.swift:126-149` |
| 5. Java 解析 | 抽成独立解析器，两条流程共用（`JavaResolverBridge` + `findSuitableJava` + `JavaManager` 兜底） | `PCLLaunchBridge.swift:160-226`、`MinecraftInstance.resolveAndApplyJava()` |
| 6. 清单/架构适配 | 服务层：`ArtifactVersionMapper.map` + 参数过滤 | `PCLLaunchBridge.swift:235-254` |
| 7. 参数组装 | `MinecraftLauncher.buildJvmArguments` / `buildClasspath` / `buildGameArguments`（保留不动） | `MinecraftLauncher.swift:161-319` |
| 8. 拉起进程 | `ProcessPoolGameProcessController` + `ProcessPool` 新增长驻入口 | `MinecraftLauncher.swift:40-103` |
| 9. 日志 | 直写文件句柄（替代 Pipe + readabilityHandler + tail 双通道） | `MinecraftLauncher.swift:68-92`、`PCLLaunchBridge.swift:276-296` |
| 10. 成功判定 | 窗口检测下沉为服务的 `.running` 事件 | `PCLLaunchBridge.swift:299-317` |
| 11. 退出与结果 | `LaunchResult(exitCode:sessionID:logURL:duration:)` + 统一一份异常退出处理 | `PCLLaunchBridge.swift:320-328`、`MinecraftInstance.swift:331-362` |
| 12. 会话与终止 | `GameSessionStore` 登记 + 终止必须走 `MinecraftLauncher.terminate()` | `PCLLaunchBridge.swift:22-25`、`LaunchCoordinator.swift:211-231` |

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

## 三、合并的风险点

### R1 顺序不可变

1. **`LaunchFix` 内部顺序**：资源索引必须先于 objects 校验/补齐（`LaunchFix.swift:43-105`），否则新下载的索引无法参与对象比对。
2. **natives 必须在支持库之后**：`MinecraftInstaller.ensureNatives` 依赖 `libraries` 下的 native jar 已存在，提前解压会失败。
3. **`LaunchFix` 必须早于 Java 解析**：现状是「先补文件、再选 Java」（`:126-222`）。若调换，用户在缺库时会先看到 Java 相关报错，属行为变化。
4. **架构映射（`ArtifactVersionMapper.map`）必须早于参数组装**，且早于任何依赖 `instance.manifest` 库列表的操作（它会改写 manifest 的库与参数）。

### R2 回调时序敏感点

| 编号 | 敏感点 | 现象 | 合并时的处理 |
|---|---|---|---|
| T1 | `phaseHandler("launching")` 在 **Java 选择之前**发出（`:151`） | 该相位名与「正在拉起进程」不等价 | 保留原始相位语义，`LaunchState` 侧映射为 `.resolvingJava`（见 `MinecraftInstanceLaunchService.swift` 映射表） |
| T2 | `onLauncherReady` 在 `launcher.launch` **之前**触发（`:257` vs `:321`） | 此刻 `currentProcess` 仍为 nil，无法构造 `ManagedProcess` | 包装层轮询等待进程出现后再登记会话；合并时应让进程创建早于该回调 |
| T3 | `launchSuccess` 可能**永不触发**（游戏无窗口 / 秒退） | UI 停在「启动中」 | 必须保留「`exitCode == 0` 兜底触发」语义（`:325`） |
| T4 | 窗口检测与退出兜底**竞争** `successGate`（`:263-271`） | 重复复位 UI | 一次性门控不能省；`LaunchService` 侧同样只能发一次 `.running` |
| T5 | 日志 tail 任务在退出时被 cancel（`:322-323`） | 尾部日志可能丢 | 合并采用「直写文件句柄」后天然消除；沿用 Pipe 方案时必须「先 drain、再置 nil handler」 |
| T6 | `exitCode == 0` 时日志文件被删（`MinecraftLauncher.swift:138`） | 会话面板读不到日志 | 合并时取消删除，或把清理动作推迟到会话移除之后 |
| T7 | 进度回调频率（`LaunchFix` 按文件回调，资源可达数千项） | 逐条投递会创建数千个 Task | 包装层已按 1% 阈值合并；合并后应由状态机自身节流 |
| T8 | 状态投递是异步 `Task`，顺序不严格 | 可能出现进度回跳 | UI 侧保留「只前进」钳制；`.running` / `.finished` 等终态必须与 `observe` 订阅时序对齐 |
| T9 | `InMemoryGameSessionStore` 无状态重放（`GameSessionStore.swift:71-78`） | 晚订阅的 UI 看不到早期状态 | 合并阶段需给 store 加「最近一次状态缓存」或要求先订阅后启动 |

### R3 终态与终止

- **终止只能走 `MinecraftLauncher.terminate()`**（`PCLLaunchBridge.swift:22-25`），它会同时置 `isUserTerminated`；直接 `Process.terminate()` 会让 completion 把「用户主动关闭」判为异常退出并弹错误框。
- 因此 `GameSessionStore.terminate(sessionID:)`（内部只做 `ManagedProcess.terminate()`）不能作为游戏会话的终止路径，包装层 `terminate(sessionID:)` 绕开了它。**合并时要么给 `ManagedProcess` 增加 `onBeforeTerminate` 钩子，要么让 store 保存终止闭包而不是 `Process`。**

### R4 `skipResourceCheck` 语义歧义

`LaunchRequest.skipResourceCheck` 来源于 `LaunchOptions.skipResourceCheck`，而桥接把它恒置为 true（`:121`），本意是「跳过 `MinecraftInstance.launch` 内的 `createCompleteTask`」，与「是否执行 `LaunchFix`」无关。`DefaultLaunchPreflight` 却把它当作「跳过整个 preflight」的开关（`LaunchPreflight.swift:174`）。若照搬，桥接路径会完全跳过启动前补齐。**合并前必须改名或拆成两个字段**（例如 `skipInstallTaskCheck` / `skipPreflightRepair`）。

### R5 错误类型缺失

桥接的失败是 `MyLocalizedError(reason: "中文文案")`，没有类型化错误码，包装层只能按文案前缀映射（`MinecraftInstanceLaunchService.mapFailure`）。文案一改就静默退化为 `.unknown`。**合并时桥接/服务必须直接抛 `LaunchError`。**

### R6 客户端 JAR 校验会引入新的失败路径

`LaunchFixClientVerifier` 一旦接线，缺失 client JAR 的实例会从「启动后崩溃」（D1 现状）变成「启动前报错」。这是**行为变化**，需产品决策：要么同时补一个客户端 JAR 下载步骤（推荐），要么把该校验降级为告警。

### R7 `GameProcessController` 协议参数缺口

现有协议没有**工作目录**与**输出句柄**两个参数：

- 工作目录：现有实现设置 `process.currentDirectoryURL = instance.runningDirectory`（`MinecraftLauncher.swift:52`），游戏读取 `options.txt`、写 `crash-report` 都依赖它；
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

`preScanJavaAsync` 的结果写回在**主线程**（`JavaManager.swift:41-45`）。合并后如果 `LaunchService.launch` 在主线程同步等待扫描结果，会直接死锁。等待必须发生在非主线程，或改为 `await` 一个由扫描完成信号驱动的续体。

---

## 四、分步合并计划

每一步都可独立编译、可回退（回退 = 撤销该步的单个替换点），且任一步出问题时另一条流程仍可用。

### 第 0 步（本次已完成）：新增适配器，零接线

- 内容：三个适配器文件 + 本文件。
- 编译验证：`xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps $(find qwq -name "*.swift")` → exit 0、error 0、新增文件零告警。
- 回退：删除 `Adapters/` 目录。
- 真机验证：**不需要**（无调用方）。

### 第 1 步：桥接层改用 `LaunchFixPreflight`

- 改动：`pclLaunchInternal` 中 `LaunchFix.perform(instance:)` 一处替换为 `LaunchFixPreflight(...).prepare(request)`（含 600s 超时语义保留在调用处）。
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
- 回退：恢复 `pclLaunch` 六段回调接线。
- 验证人：**必须真机**验证：① 多开两个不同版本；② 日志面板实时刷新与暂存 flush（T5/T9）；③ 电源按钮终止全部；④ 启动过程中切换分类页再回来（回调不丢）；⑤ 用户名为空 / 含非法字符 / 超 16 字符三条校验分支提示正确。

### 第 5 步：删除桥接层

- 前置：第 4 步稳定运行一个版本周期，且确认 `pclLaunch` 无其它调用方。
- 改动：删除 `PCLLaunchBridge.swift`；`MinecraftInstance.launch(_:)` 的资源检查与崩溃弹窗下沉或标注废弃；`LaunchFix` 降级为转发壳后移除。
- 验证人：**必须真机**做一轮完整回归（安装新版本 → 补全 → 启动 → 进服 → 退出）。

### 必须真机、无法用编译/单测覆盖的项（汇总）

进程能否真正拉起、窗口出现检测（CGWindowList）、Rosetta 转译路径、Java 扫描等待时序、日志完整性与 flush 时序、进程退出与 completion 的先后、多开与终止时的 UI 复位。

---

## 五、当前状态

- 三个适配器**尚未加入 Xcode target**（`qwq.xcodeproj` 未修改），接线时需加入 `qwq` target 的 Compile Sources。
- 全部新增文件通过 typecheck（exit 0、error 0），且不产生新的编译告警。
- 未引用任务约束中列出的四个已删除文件（App 层窗口封装、旧 Java 环境 / 路径发现、旧启动预检）。
