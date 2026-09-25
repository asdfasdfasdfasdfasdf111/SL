# 更新日志

本文件记录 SL 启动器（qwq）的重要变更，按版本发布记录。

## 给 `DropInstallCoordinator` 补注入点，并补上「拖入模组 → 安装成功」这条最主线流程的用例（2026-09-25）

**背景**：`TESTING.md §4.5` 登记着一处覆盖缺口 ——「模组安装的**成功分支**没有任何用例」，
原因是 `beginModInstall` 里的版本检测（`ModVersionDetector`）与实例匹配（`ModDragInstaller`）
都是硬编码私有依赖，测试无法把实例指到一个受控目录上。

**缺口的实际后果**（这才是本轮真正要修的）：**「用户拖入一个模组 → 看到实例选择弹窗 → 点安装 →
文件落到游戏目录」这条最主线的流程，一行断言都没有**。三种结果文案同样不受保护：
「模组已安装到 N 个实例」／「部分实例安装失败」／「模组安装失败」——
而最后那条恰恰是前几轮刚修出来的（在那之前，全部失败也会显示「已安装到 0 个实例」）。

**改法（生产代码只有 1 个文件、逻辑净 +6 行）**：给 `DropInstallCoordinator` 加构造注入点，
两个**带默认值**的闭包：

```swift
init(detectVersion: @escaping @MainActor (URL) -> ModVersionDetector.ModVersionInfo? = { ModVersionDetector().detectVersion(from: $0) },
     findInstances: @escaping @MainActor (_ versionRange: String, _ savedRoot: String) -> [GameInstance] = { ModDragInstaller.findInstances(for: $0, savedRoot: $1) })
```

默认值即生产接线 ⇒ `ContentView` 里 `@StateObject private var dropInstall = DropInstallCoordinator()`
**一个字节都没改**。

- **只替换这两项、不替换 `ModDragInstaller.install`**：它把内容写到
  `instance.rootPath/versions/<版本>/mods`，实例指向临时目录时本身就完全受控；
  保留真实实现，才能让「文件真的写进了游戏会加载的那个目录」被真正验证，而不是由替身自证。
- **顺带把类显式标上 `@MainActor`**（口径二下语义不变，因为它本来就被推断为主 actor 隔离）：
  闭包参数标了 `@MainActor` 之后，只有显式隔离的调用方才被允许同步调它，否则「默认隔离」口径报
  `#ActorIsolatedCall`。显式标注的收益是把「从非主 actor 上下文调用」从**静默**变成**编译错误**。
- ⚠️ `@MainActor` 与 `@escaping` 要**分别标**：`@MainActor` 不改变逃逸性，漏 `@escaping` 会只被真实编译
  拦下（快速类型检查对此完全静默，是上一轮踩过的坑）。

**新增 6 条用例**（`DropInstallCoordinatorTests` 16 → 22 条，全量 **248 → 254**）：

| 用例 | 守的是什么 |
| --- | --- |
| `testJarWithDetectedVersionAndMatchedInstanceOpensModSheet` | 前置条件齐备时必须打开弹窗并暂存「待装文件 + 匹配结果」 |
| `testJarWithoutMatchedInstanceReportsErrorOnly` | 一个实例都不匹配时只提示错误、**不得打开空弹窗** |
| `testBatchOfJarsKeepsLastAsPendingTarget` | 一批多个 jar 后写覆盖暂存目标 —— 用**落盘文件**证明装的确实是暂存那个 |
| `testConfirmModInstallCopiesModToEveryInstanceAndReportsCount` | 文件真的落到**每个**实例的 `versions/<版本>/mods`（逐字节比对）+ 成功气泡 + 弹窗关闭 |
| `testConfirmModInstallPartialFailureWarnsAndCopiesOnlyReachableInstance` | 部分失败：可写实例照常装上、warning 横幅列出失败原因、**不得**只报成功数 |
| `testConfirmModInstallTotalFailureReportsErrorWithEveryReason` | 全部失败：error 横幅列出**每个**实例的原因、不得留下「已安装到 0 个实例」 |

**反向验证（各精确只红对应用例）**：摘掉 `!instances.isEmpty` 守卫 → 只红 1 条；
成功计数 `+1` → 只红 1 条；摘掉 `FileManager.copyItem` → 红 3 条，**全部是断言落盘的用例**
（不是串染）。还原后源码零残留（`grep 反向用例临时摘掉` = 0）。

**覆盖不了的部分（写清代价，不是「没测」）**：
- 真实的 `findInstances` 仍无用例 —— **不是因为没有注入点（现在有了），而是因为驱动它会写用户真实游戏目录**：
  它除「选定根目录」外会全盘扫描本机游戏目录，并对每个根目录调 `MinecraftVersionManager.getVersions`
  → 内部 `normalizeVersionFolderNames` **会重命名磁盘上的版本文件夹并改写其中的 json**。
  要覆盖它得先把「扫描」与「匹配」拆开。
- `confirmModpackInstall` 的成功分支**不可达**：`ModpackInstaller.install` 最后一步 `installLoader`
  无条件抛错（刻意为之：宁可真失败，也不假装装上加载器）⇒ `presentMessage("整合包安装完成")` 永远执行不到。

### 本轮验证里查清的一处**假警报**：套件会在 `LaunchCancellationTests` 偶发 abort（**与本轮改动无关**）

全量测试跑出过 `** TEST EXECUTE FAILED **`（退出码 65），崩在
`LaunchCancellationTests.testUncancelledTokenPassesEntryGate`，报告是
`malloc: pointer being freed was not allocated`。一上来很像是本轮改动把套件弄崩了，
于是做了对照实验 —— **结论是无关，且这道门本身就是概率性的**：

```text
只跑字母序相邻的两套（DropInstallCoordinatorTests + LaunchCancellationTests，共 26 条）各 4 次：
  当前工作区（含本轮改动）：  通过 通过 通过 崩
  HEAD（git archive 导出后单独构建、未含本轮改动）：  崩 通过 通过 通过
```

- 崩溃签名固定，且**早于本轮改动就存在**：`swift_task_deinitOnExecutorMainActorBackDeploy` →
  `TaskLocal::StopLookupScope::~StopLookupScope` 二次释放 → 宿主 abort。这就是 `TESTING.md §五`
  记录的那条工具链缺陷（上游 `swiftlang/swift#87422`）。本机今天 `02:14` / `02:16` 的两份崩溃报告
  是同一签名（当时受害对象是 `ClientManifest.Rule.OSRule`，本轮是
  `MinecraftDirectory` / `MinecraftInstance` —— 即「此刻恰好正在析构的那个主 actor 隔离类」，
  触发点在真实启动路径里，与本轮改的文件没有任何关系）。
- ⇒ **「全量测试 0 崩溃」这道门是概率性的（本次抽样 8 次里 2 次 abort，工作区与 HEAD 各 1 次），
  任一轮都可能随机踩到**，而且能被 26 条用例的最小集合复现。**不能用单次 abort 判定代码有问题**，
  要定性必须用「同一命令在 HEAD 上对照跑」。
- 排查中另有两个值得记住的坑：
  1. **进程 abort 之后派生目录会退化**：`qwq.app/Contents/PlugIns/qwqTests.xctest` 消失，
     此后连 `build-for-testing` 报「成功」也不会把它补回来（`test-without-building` 于是报
     `Failed to create a bundle instance`）⇒ **abort 之后换全新 `SL_DERIVED` 再跑**。
  2. **`test-without-building` 不会重新构建**：跑完「反向用例破坏版」之后若不先 `build-for-testing`，
     会拿**旧的坏二进制**跑出假失败 —— 本轮的相邻两套对照第一版就是这么翻车的（3 条假红）。

### 本轮的实测口径（可复核）

```text
Executed 254 tests, with 1 test skipped and 0 failures
** TEST EXECUTE SUCCEEDED **
类型检查：口径一 0 错/46 告警、口径二 0 错/24 告警（告警集合与 HEAD 逐条一致，零新增）
Date:   2026-09-25        Branch: refactor/modular
派生目录：全新（/tmp/SL-DD-<n>；abort 过的派生目录一律弃用）
⚠️ 该套件约 1/4 概率在 LaunchCancellationTests 处 abort（工具链缺陷，HEAD 同样会），
   故上面这次干净结果取自重试；abort 本身不作为代码有问题的判据。
```

改动面：3 个文件（生产 1 / 测试 1 / 文档 1），毛 +305 −31；
其中生产文件 `DropInstallCoordinator.swift` 毛 +45 −5、**逻辑代码净 +6 行**（其余是文档注释）。

## 给 `JavaResolverBridge` 补解析器注入点，并修掉一整批「假绿」用例（2026-09-25）

**背景**：`JavaResolverBridgeTests.swift` 的注释里自己写着一条缺口 ——「`JavaResolverBridge` 内部直接构造
`DefaultJavaResolver()`，没有 resolver 注入点，无法构造 `JavaResolutionError.scanFailed` /
`.noCompatibleVersion` 的确定性场景，只能覆盖『超时 → nil』」。本轮补上这个注入点，结果发现问题比注释写的更重。

**发现（比预想严重）**：那 8 条用例**并不能证明它们声称测的东西**。

`resolveSynchronously` 的第一条分支是 `if Thread.isMainThread { return nil }`（避免 8 秒信号量等待冻结 UI）；
而本工程测试 target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，`XCTestCase` 的 async 用例体就跑在主线程上。
两者相遇 ⇒ 用例里直接调用这个桥接，**被测行为会被早退分支整体短路**：

| 原用例 | 真实情况 |
| --- | --- |
| 6 条用 `timeout: 0` / 负数 / `0.001` 的 | 主线程早退先返回，`semaphore.wait` 从未执行 ⇒「超时保护」从未被验证；且 `timeout: 0` 本身就意味着内部任务还没被调度，即使不在主线程也测不到 |
| `testRepeatedTimeoutCallsReturnPromptly` | 5 次调用全走早退 ⇒「秒级返回」恒真，与超时是否生效无关 |
| `testNonNilResultIsAnExistingLocalFile` | 主线程调用结果**恒为 nil** ⇒ `if let url` 整段是**死代码**，是彻底的假绿 |
| `testConcurrentCallsReturnNilWithoutDeadlock` | `concurrentPerform` 有部分迭代确实跑到真实超时路径，但断言「都返回 nil」在 `timeout: 0` 下无区分力 |

**改法**（本轮的实质）：

1. **加注入点**：`resolveSynchronously(…, makeResolver: @escaping @MainActor @Sendable () -> any JavaResolver = { DefaultJavaResolver() })`。
   默认值即生产路径，行为零变化；测试注入替身即可确定性地构造「命中」与「未命中」。
   参数标 `@MainActor` 是因为 `DefaultJavaResolver` 在默认隔离下被推断为主 actor 隔离、只能在主 actor 上构造；
   标 `@escaping` 是因为它被逃逸的 `Task.detached` 闭包捕获。
2. **把「调用线程」变成必须显式选择的东西**，这是修掉假绿的关键：
   - `callOffMainThread(_:)` —— 在 `Task.detached` 里调用，走真实解析路径。**所有关于解析结果/超时的断言都必须用它。**
   - `callOnMainThread(_:)` —— 在 `MainActor.run` 里调用，用于断言「主线程早退」这条性质本身。
   两者配对（同一份「必定成功」的解析器，唯一变量是线程），才能做到「一条失败只指向一个性质」。
3. **把前提本身钉成断言**（`testThreadPremisesHold`）：确认 `MainActor.run` 内是主线程、`Task.detached` 内不是。
   若将来有人改掉调用方式，前提会立刻变红，而不是悄悄退回「所有断言都因为主线程返回 nil 而变绿」。
4. 用例 8 条 → 12 条：新增命中透传、`minimumMajor` 钳制与 `Int.max`/`mcVersion`/`remarks` 透传（这三条过去**根本无法断言**，
   只能退而断言「不崩溃」）、真实等待到超时（带 `≥ 0.25s` 下界，证明走的是超时路径而非别的原因提前返回）、
   三条解析未命中原因逐条吞掉、失败**立刻返回**而不是耗满 timeout、并发不串扰（断言每次拿到**自己的**结果）。

**为什么测试不跑一次「真实默认解析器」**：`DefaultJavaRepository.save` 会调
`JavaManager.shared.saveCachedJavaPath`，即**写入真实用户设置**。让测试驱动真实扫描等于在测试里改用户数据，
故一律用替身；代价（默认工厂那一行只在评审层面被守住）已写进测试文件的「覆盖率缺口」。

**反向验证**（两个破坏点，各自精确只红 1 条）：

| 破坏点 | 结果 |
| --- | --- |
| 摘掉主线程早退分支 | **恰好 1 条失败**：`testMainThreadCallReturnsNilWithoutTouchingResolver`，报「主线程调用耗时 10.001s，说明早退分支没生效」。顺带实测到一个副作用：主 actor 被信号量阻塞后，内部 `Task.detached` 的 `MainActor.run` 拿不到主 actor ⇒ 只能等满 timeout —— 这正是早退分支必须放在最前面的实证 |
| 摘掉 `max(0, minimumMajor)` 钳制 | **恰好 1 条失败**：`testMinimumMajorIsClampedBeforeReachingResolver`（同一条用例内 -5 与 `Int.min` 两个断言行） |

**验证**：typecheck 两口径 **0 错误**，且告警集合与 `HEAD` **逐条一致**（46 / 24，零新增零消失 —— 这条是必须做的，
因为「改动引入新告警」本身就是改动不成立的信号）；`verify-build.sh` **BUILD SUCCEEDED**；
`verify-test.sh run` **`Executed 248 tests, with 1 test skipped and 0 failures`**（244 → 248），
`pointer being freed` / `Restarting after unexpected exit` 两个计数均为 **0**。

**顺带记录一条工具链盲区**（本轮实际踩到）：`swiftc -typecheck` 对
`escaping closure captures non-escaping parameter` **完全静默**（5 行最小复现：给函数加闭包参数、
在 `Task.detached` 里调用它），两口径 0 错误、真实编译报 1 error。这与已知的「SILGen 阶段才报的初始化违规」
是**两个不同**的触发类；共同结论是：**加注入点这类改动必须跑真实编译**。

## 拆分 `SLCore/Stubs.swift`：按职责拆成 7 个文件（纯搬家，零行为变更，2026-09-25）

**背景**：`qwq/SLCore/Stubs.swift`（387 行）是一份历史遗留的「杂物袋」—— 文件名说它是桩，
里面却混着**真实现**（离线账号的 PCL2 兼容 UUID 算法、提示/弹窗通道、`DataManager` 的三个真实字段）。
后果是审查时容易把真代码当桩看，新增文件也没有明确的归属位置。

**做法**：**只按职责搬家**，一个类型都不改。判据是「纯搬家」的三条自我约束：

| 不做什么 | 为什么 |
| --- | --- |
| 不改类型名 / 不合并类型 | 改名会波及全部调用点，超出「拆分」的范围 |
| 不改 `Codable` 形状 | 落盘 JSON 与旧版本必须互通 |
| 不改 `UserDefaults` key | key 一改，用户既有设置全部丢失 |
| 不改任何行为 | 拆分不引入逻辑变更 |

**拆出的 7 个文件**：

| 新位置 | 内容 | 性质 |
| --- | --- | --- |
| `SLCore/Account/OfflineAccount.swift` | `Account` 协议、`OfflineAccount`（含 PCL2 兼容 UUID 算法）、`validateOfflineUsername` | **真实现** |
| `SLCore/Account/AnyAccount.swift` | `AccountError`、`AnyAccount` 枚举、`AccountManager` | 真实现 |
| `SLCore/Notices/Hint.swift` | `hint(_:_:)`、`HintType` | 真实现 |
| `SLCore/Notices/Popup.swift` | `PopupButton`/`PopupModel`/`PopupManager` 等 | 真实现（`showAsync` 无生产调用方，保留供崩溃上报用） |
| `SLCore/Storage/AppSettings.swift` | `DownloadSourceOption`、`AppSettings` | 真实现 |
| `SLCore/Storage/CodableAppStorage.swift` | `@propertyWrapper CodableAppStorage` | 基础设施 |
| `SLCore/DataManager.swift` | `DataManager` | 真实现 |

**「纯搬家」是怎么被证明的**（不是靠眼看 diff）：把 `HEAD:qwq/SLCore/Stubs.swift` 与 7 个新文件都做同一套归一化
（去 `//` 注释、去 `import`、去空行、折叠空白）后 `sort`，再比对：

```bash
# 判据 = 行数相等 且 diff 为空（多集逐行一致）
norm() { grep -v '^[[:space:]]*//' "$1" | grep -v '^[[:space:]]*import ' \
         | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' | grep -v '^$' | sort; }
```

实测 **旧 184 行 = 新 184 行，`diff` 输出为空** —— 即每个「非注释、非 import」行在新文件里**恰好出现一次**，
不多不少。文件总行数从 387 涨到 492（+105）**全部来自新文件头与 `///` 文档注释**
（工程规约要求新增 Swift 文件必须有文件头），代码行本身未变。

**同步更新的引用**：`README.md`、`qwqTests/TESTING.md`、`qwq/Features/Launch/Adapters/LAUNCH_FLOW.md`、
`qwq/SLCore/Minecraft/MinecraftCrashHandler.swift`（注释里的 `Stubs.swift:329`）、`qwq/SLCore/STUBS_AUDIT.md`
（加了「旧内容 → 新位置」对照表）。

**验证**：`typecheck.sh` 两口径 **0 错误**（46 / 24 告警，与拆分前逐项相同）；`verify-build.sh` **BUILD SUCCEEDED**；
`verify-test.sh run` **`Executed 244 tests, with 1 test skipped and 0 failures`**，
且 `pointer being freed` / `Restarting after unexpected exit` 两个计数均为 **0**。

## 给装配根补一道幂等门（复核第 7 条，2026-09-25）

**复核提出的问题**：`AppCompositionRoot.registerRuntimeServices()` 整体**不保证幂等** ——
别处若再调一次，可能重复装崩溃处理器、重复起目录预热任务。复核同时要求：
**先确认各成员的重复调用语义，再决定要不要改**。

**逐条读实现的结果**（不是预防性写法）：

| 成员 | 自带幂等守卫？ | 依据 |
| --- | --- | --- |
| `CrashReporter.install()` | ✅ 有 | `guard !installed else { return }` |
| `MemoryCacheReclaimer.register()` | ✅ 有 | `guard token == nil else { return }` |
| `LocalModCatalog.warmUp()` | ❌ **没有** | 它的守卫读的是「预加载是否已完成」标志，而该标志要等后台任务跑完才置位；**在它置位之前重复调用会再起一个后台预热任务**（重复读盘 + 重复发 `localCatalogReady` 通知） |

⟹ 三个成员并不一致，「入口幂等」不能在成员层面默认成立。修法是在**入口处**收口：

```swift
guard !didRegisterRuntimeServices else { return }
```

（比逐个去改成员更局部；`didRegisterRuntimeServices` 仍保留「置位放在最后」的语义。）

**为什么没有给它加用例**（已写进测试文件的「覆盖率缺口」第 6 条）：要断言「第二次调用无副作用」，
就必须把那个标志重置掉；而重置正好抹掉「装配根跑过」的**唯一证据**，会顺手破坏上一条性质。
在引入独立证据源（例如按调用次数计数）之前，这里只做代码级收口，**不假装有测试覆盖**。

**反向验证复测**：把 `AppCompositionRoot.registerRuntimeServices()` 从 `SLApp.init()` 摘掉，
仍然**恰好 1 条失败**（就是 `testCompositionRootRegistersReclaimerSubscription`）——
幂等门没有削弱那条用例的精度。

**验证**：typecheck 两口径 0 错误（46 / 24 告警，与上一轮逐项相同）；真实编译 BUILD SUCCEEDED；
`Executed 244 tests, with 1 test skipped and 0 failures`。

## 修正「装配根测试可能是假绿」：让装配动作可指名、让用例从确定状态出发（2026-09-25）

**外部复核指出的问题**：`testCompositionRootRegistersReclaimerSubscription` 断言的是
`MemoryPressureBroadcaster.shared.handlerCount >= 1` —— 一个**进程级绝对条数**。
它无法区分「应用装配根注册的」与「本文件其它用例自己 `register()` 注册的」，
而且 `MemoryCacheReclaimer.register()` 是幂等的（`guard token == nil`）、`token` 又是静态持久状态，
所以先前的反向验证可能只是「顺序刚好对了」。结论：**该用例需要修正才能宣称接线成立。**

**先量后改**（在改任何东西之前，用现有产物单跑与全量跑各测一遍）：

| 实验 | 结果 |
| --- | --- |
| 单跑该用例（`-only-testing:`，此前没有任何用例注册过） | **通过**，且 `handlerCount ≥ 1` |
| 全量跑（把 `MemoryCacheReclaimer.register()` 从 `SLApp.init()` 摘掉） | **恰好 1 条失败**，就是该用例 |
| 单跑（同上摘掉） | 同样**恰好 1 条失败** |

⟹ 复核的正确部分是**结构性**的：该用例当前有效**靠的是顺序巧合**（它在本类里按字母序排在
所有 `register()` 之前，且全仓只有这一个类会注册回收器、没有开随机顺序）。一旦顺序被随机化、
或将来别的类先注册，它就会**假绿**，而反向验证也会随之失效。所以断言必须换成不依赖顺序的形式。

**修法（不新增「测试专用分支」，只把装配动作变成可指名的入口）**：

1. **新增 `App/AppCompositionRoot.swift`** —— 装配根。原先写在 `SLApp.init()` 里的三条初始化
   （`CrashReporter.install` / `MemoryCacheReclaimer.register` / `LocalModCatalog.warmUp`）搬进
   `registerRuntimeServices()`，`SLApp.init()` 只留**一行调用**。
   ⚠️ 保留在 `init()` 里会导致 `Resource`/`AppContext` 的同步 IO 约束被绕过 —— 头部注释里
   逐条写明了「只允许装处理器与丢后台」这条约束的依据。
2. **新增单调标志 `AppCompositionRoot.didRegisterRuntimeServices`**：唯一置位点是
   `registerRuntimeServices()` 的**最后一行**（三条动作都执行过才置位）。
   它**不被任何人重置**，因此不受用例执行顺序影响 —— 用例改为断言它。
   它之所以能证明「应用装配根跑过」：测试 bundle 由 `qwq.app` 宿主（`TEST_HOST` 指向 app 二进制），
   `SLApp.init()` 先于任何用例执行。这条**承载性假设**已写进测试文件的「覆盖率缺口」一节。
3. **`MemoryCacheReclaimer.resetForTesting()`**（`#if DEBUG`）：把「已注册」这个静态状态归零，
   使用例可以从确定状态断言**差值**（`注册前条数 + 1`），而不是绝对条数。
4. **把幂等性用例拆成两条**：`testFirstRegisterAddsExactlyOneHandler`（第一次 +1）与
   `testRepeatedRegisterAddsNoHandler`（之后 +0）。合成一条时「摘掉 `guard`」会连带上一条一起红，
   拆开后失败信号各自精确。
5. `testReclaimerRegistrationClearsModrinthMemoryCache` 也改为先 `resetForTesting()` ——
   否则应用启动时那次注册会**顶替**本用例自己那次注册，用例在「注册失效」时照样通过。
6. 用例动过注册状态时，`defer` 里用 `restoreReclaimerRegistration()` 还原成进程启动态（已注册），
   避免把状态留给后面的用例（复核指出的「顺序污染」）。

**反向验证（都实测过，且「红得精确」）**：

| 破坏 | 变红的用例 | 条数 |
| --- | --- | --- |
| 从 `SLApp.init()` 摘掉 `AppCompositionRoot.registerRuntimeServices()` | `testCompositionRootRegistersReclaimerSubscription` | **恰好 1 条** |
| 摘掉 `MemoryCacheReclaimer.register()` 里的 `guard token == nil` | `testRepeatedRegisterAddsNoHandler` | **恰好 1 条** |

**顺带修正的一处验证工具问题**：`scripts/typecheck.sh` 用的是裸 `swiftc`，**默认不定义 `DEBUG`**，
于是工程里 `#if DEBUG` 的代码（如 `App/DebugAutoLaunch.swift`）从来没被这一层检查过；
本轮新增的 `resetForTesting()` 因此被误报成 4 处 `has no member`（真实编译 0 错误）。
已给脚本加上 `-D DEBUG`（实测：口径一 0 错误 / 46 告警，口径二 0 错误 / 24 告警，
口径二与加标志前**逐条一致**）。同时实测到：**编译一旦报错，后续文件的告警会被吞掉**
（同一份源码，带 4 处错误时 32 告警，修掉后 46 告警）—— 所以那个「32」本来就是被截断的假数，
脚本头里已补记这条。

**实测结果**：`Executed 244 tests, with 1 test skipped and 0 failures`（243 → 244，幂等用例拆分 +1）。

## 处置一条并发隔离跟进项：把「主线程 ⇒ 在 MainActor 上」从隐藏假设变成有测试守着的显式假设（2026-09-25）

**外部复核提出的问题**（明确标注不阻塞上一轮 P0）：`MemoryPressureBroadcaster.post` 用
`Thread.isMainThread` 判断「是否已经在主 actor 上」，再决定同步调用还是 hop；
而 Swift **并不保证**这两者等价 —— `MainActor.assumeIsolated` 校验的是**执行器**，不是线程。

**先实测再决定改不改**（独立探针，`/tmp/iso-probe/probe.swift`、`probe2.swift`）：

| 上下文 | 结果 |
| --- | --- |
| 与生产**同构**：`DispatchSource.makeTimerSource(queue: .main)` 的事件回调里调 `assumeIsolated` | **通过** |
| 同一份探针从后台线程调 | **被拒绝**（`SIGTRAP`，退出码 133）→ 该检查真会拒绝错的环境，不是恒真 |
| 「主线程但不在 MainActor 执行器上」能否构造出来 | 40000 个 `Task.detached` / 后台发起的非隔离任务里，落在主线程上的次数 **0** |

**结论：不改成「永远 hop」**，理由是对称的两条：

1. 保留同步送达换来一个**真实性质** —— 「裁 `CacheManager` + 清那 4 个缓存」落在同一个事件处理器里，
   不被主 actor 上的其它活儿插到中间；而改成永远 hop 只是去规避一个本工具链下构造不出来的上下文，
   代价与收益不成比例。
2. 这条检查在**真实风险方向上是保守的**：若哪天有人把 `AppContext` 里 source 的 `queue` 改掉
   （连 `queue: nil` 这种「官方未定义落到哪个队列」的写法也算），`Thread.isMainThread` 会变成 false
   → 自动走 hop 路径（**更安全**），不会误走同步路径。即最可能的未来改动只会让它退化，不会让它变危险。

于是改为**把假设写成显式契约并用测试钉住**：

- `post` 的文档里写明该假设、上面三条实测证据、以及「假设一旦不成立，守它的用例会当场 trap 而不是静默出错」；
- 文件头加指引，避免后人以为那是随手写的线程判断；
- 新增 `testPostFromMainQueueDispatchSourceIsDelivered`：用**同构的 `queue: .main` dispatch source 回调**
  复现生产发布点，钉住「在该上下文里发布同样送达」；
- 写明**不要**与 `NoticeCenter.post`「顺手统一」—— 那边同步投递是**承重**的（先 `post` 后 `presentAndWait`
  会顺序倒置 → 提示被当成"被顶替"直接应答，用户根本看不到），且已有专门的反证用例。

**生命周期三问的答复**（复核里要求「补一个生命周期测试或至少验证」）：

- `AppContext` 销毁后 source 是否取消：`deinit { memoryPressureSource?.cancel() }` 在；但
  `AppContext.shared` 是**进程级单例** ⇒ `deinit` 实际永不执行，属防御性写法。
- broadcaster 是否仍保留 handler：**是，且应当如此** —— 内存压力订阅是进程级的，不注销。
  但「注销后不得继续持有」这一半补了测试：`testRemovedHandlerReleasesItsCaptures`
  用哨兵对象 + `weak` 观察「注册期间被持有、注销后被释放」，作为闭包泄漏的回归守卫。
- 有无 handler 反向保活 `AppContext` 的强引用链：**无**。引用关系是
  `AppContext` →(强) `memoryPressureSource` →(强) 事件处理器 →(弱) `AppContext`（`[weak self]`），
  且处理器不直接捕获局部变量 `source`；`MemoryCacheReclaimer` 注册的闭包不捕获任何实例。

**顺带自查出并修掉的测试缺陷**：反向用例实测发现「摘掉同步分支」这一个原因会**连带打红 5 条用例** ——
`testPostPreservesLevel` / `testPostReachesEveryRegisteredHandler` /
`testReclaimerRegistrationClearsModrinthMemoryCache` / `testReclaimerRegistrationIsIdempotent` /
`testPostWithoutHandlersDoesNotCrash` 都在 `post` 之后**不 await 就断言**，隐式依赖了同步性。
已全部改成 `await` 送达后再断言，让「同步性」只由唯一一条具名用例守卫。另：
`testReclaimerRegistrationIsIdempotent` 原先「连注册三次后看缓存还是不是被清掉」，
**根本区分不出 1 个处理器和 3 个处理器**（等于没测幂等性），已改为比较
`handlerCount` 的调用前后差值。

**验证**：typecheck 两口径 **0 错误**（告警 46 / 24，口径二不变）；**BUILD SUCCEEDED**；
**TEST EXECUTE SUCCEEDED，243 用例 / 0 失败 / 1 跳过**。反向用例（每条都实测、无连带）：

| 破坏 | 变红用例 |
| --- | --- |
| 摘掉 `post` 的同步分支（改无条件 hop） | **精确 1 条**：`testPostOnMainThreadDeliversSynchronously` |
| 摘掉 `remove` 的实现 + 摘掉 `register` 的幂等守卫 | **精确 4 条**：两个 `testRemovedHandler*`、`testPostWithoutHandlersDoesNotCrash`、`testReclaimerRegistrationIsIdempotent` |

## 修掉一处基础设施→UI 的反向依赖：`AppContext` 不再认识具体视图（2026-09-25）

**问题**：`AppContext`（基础设施层）在系统内存压力事件里直接调 `DownloadCategoryView.clearStaticCaches()`
—— 一个 `View` 类型上的 `static func`。两重毛病：

1. **依赖方向倒置**（Infrastructure → UI）：删掉或改名那个视图会波及应用基础设施；
   后续任何页面想响应内存压力，都只能继续往 `AppContext` 里加具体 View 调用。
2. **命名空间错位**：被清掉的 4 个缓存（`ModrinthCategoryCache` / `SearchTranslator` /
   `GameVersionManifest` / `LoaderSupportChecker`）**没有一个属于那个视图** ——
   「清理各模块缓存」这件事碰巧挂在了 `DownloadCategoryView` 上。

**改法**（新增一层事件 + 装配期订阅，共 3 个新/改文件）：

- 新增 `Core/Events/MemoryPressure.swift`：`MemoryPressureLevel` + `MemoryPressureBroadcaster`。
  广播者 `nonisolated`、订阅表用 `NSLock` 串行化、处理器类型是 `@MainActor`（订阅方要碰主 actor 隔离的静态缓存）；
  主线程发布走 `MainActor.assumeIsolated` **同步**送达，后台线程 hop 到主 actor。
- 新增 `App/MemoryCacheReclaimer.swift`：装配层把「回收这 4 个缓存」登记为订阅者，`register()` 幂等。
- `AppContext`：只把系统内存压力翻译成应用内事件并发布，**不再出现任何 UI 类型**。
- `qwqApp.swift`（装配根）在 `SLApp.init()` 里登记订阅 ——「谁需要响应内存压力」这个知识只存在于装配层。
- 删除 `DownloadCategoryView.clearStaticCaches()`。

**行为不变**（刻意如此）：`warning` 与 `critical` 仍回收**同一批**缓存，不引入「critical 才清某个缓存」
这类新策略（那属行为变更，需单独评估）；等级仍原样透传，将来要分等级处理不必改注册方式。
4 个清理函数已逐个核对，**全部只动内存、不碰磁盘**。

**顺手修掉的一处隐患**：原代码是 `source.activate()` 在前、`memoryPressureSource = source` 在后。
事件处理器要读 `source.data` 才能判等级，而我改为经 `self.memoryPressureSource` **间接**取用、
**不直接捕获 `source`**（否则 source ↔ handler 互相强引用成环，`deinit` 里的 `cancel()` 永远等不到）
—— 因此 `memoryPressureSource` 必须**先赋值、后 activate**，否则「先激活后赋值」那段窗口里读到 nil，
等级会被误判成 `.warning`。

**验证**：

- 类型检查两口径 **0 错误**；口径二告警 **24（不变，无隔离回归）**；口径一 44 → 46，
  恰为 **+2 = 新增 1 个测试文件的 `@testable import` 产物**（脚本里已记录的固定口径，非回归）。
- 真实 xcodebuild **`BUILD SUCCEEDED`**；`** TEST EXECUTE SUCCEEDED **`，
  **241 用例（原 232）/ 0 失败 / 1 跳过**；崩溃计数 `pointer being freed` = 0、
  `Restarting after unexpected exit` = 0。
- 新增 `qwqTests/MemoryPressureTests.swift`（9 个 `async` 用例）：主线程同步送达 / 等级原样透传 /
  多订阅者各自收到 / 注销后不再被调用 / 后台线程发布仍送达 / **装配根确实注册过**（`handlerCount ≥ 1`）/
  端到端（`register()` 后一次事件真把 `ModrinthCategoryCache` 清空）/ 无订阅者不崩 / 注册幂等。
- **反向用例（两条都实测变红，六个无关用例保持绿）**：
  - RP1 摘掉 `MemoryCacheReclaimer` 处理器里的 `ModrinthCategoryCache.clearAll()`
    → `testReclaimerRegistrationClearsModrinthMemoryCache`（2 条断言）、`testReclaimerRegistrationIsIdempotent` 变红；
  - RP2 摘掉 `SLApp.init()` 里的 `MemoryCacheReclaimer.register()`
    → `testCompositionRootRegistersReclaimerSubscription` 变红（`("0") is less than ("1")`）。
  - 判据：**只保留「自己注册自己收」的用例是不够的** —— 装配根漏注册时它照样绿，而真实运行时
    内存压力不会清任何缓存。RP2 就是补这个盲区。

## 补回「被推翻那批」漏下的 3 处修复（2026-09-25）

**背景**：远端 `refactor/modular` 一直停在 `f4e7578`（2026-09-24 17:48 推上去的
「全项目 18 模块审查修复批次」，29 files / +363 / −218）。而本地在 28 分钟后判定该批
「改过头、可读性下降」并**推翻重做**（`5d0004a`），从此两条线分叉：远端 1 个提交，
本地 8 个提交（`git status` → `ahead 8, behind 1`）。逐条核对被废弃那批的修复后发现，
重做时**有 3 处真修复没有被带过来**（不是实现不同，是本地压根没有）。

**① 提示中心：主线程投递从「下一轮 runloop」改为同步**
`NoticeCenter.post` 原本一律 `Task { @MainActor in deliver(notice) }`，即使调用方已在主线程，
投递也要等下一轮 runloop。于是「先 `post` 后 `presentAndWait`」这类同线程调用会**顺序倒置**：
后发的 `presentAndWait`（其 `deliver` 是同步的）反而先落到 `current`，先 `post` 的那条被当成
「被顶替」立即按默认按钮应答，用户根本看不到它。
改为：`Thread.isMainThread` 时走 `MainActor.assumeIsolated { deliver }` 同步投递，后台线程保持原 hop 路径。
`assumeIsolated` 的可用性**实测过**（部署目标 macOS 13.0 下类型检查通过，非 14.0-only），未凭印象加守卫。

**② 版本按钮：不可取消的回弹闭包改为可取消的 `.task(id:)`**
`VersionButton` 用 `DispatchQueue.main.asyncAfter` 回写 `@State animationScale`，闭包**不可取消**；
视图在这 0.12s 内被销毁（连点其它版本、返回上一页、切换分类）时，闭包仍会写已释放的 State storage
—— 本工程多处 UAF 的成因。改为 `@State clickCount` + `.task(id: clickCount)`。
⚠️ 睡眠必须 `do/catch + return`，**不能写 `try?`**：取消时 `Task.sleep` 抛 `CancellationError`，
用 `try?` 吞掉会继续往下执行 `withAnimation { scale = 1 }`，等于「取消之后仍然回写 @State」，
正是本组件要根治的那个隐患。

**③ 下载：未知大小（无 Content-Length）的分片真正能续传**
`Slice.undone(of:)` 对 `fileSize == -1` 恒返回 -1，而 `tryBeginSlice` / `tickOnce` 的续传判定是
`undone > 0` —— 于是**未知大小文件的续传分支永不触发**：断流后旧片永远停在 `.failed`，
调度器 `needMore` 恒真，每个 tick 都为同一片再建一条「从同一偏移续传」的新片，
同一区间被并发重复下载，合并时按 start 拼接出**尾部重复的坏文件**。
改为在 `Slice` 上引入显式 `superseded` 标记：建续传片时标记旧片已被接管，
判定处跳过已接管的片；`fileSize <= 0`（-1 未知 / -2 未取得）时按 `failed.start + failed.done` 续传，
零进度仍回到「重建首线程」（保留原 -2 行为，不回退）。
本地此前只用 `waitForCompletion` 的 1800s 兜底把「挂死」降级成「超时失败」，**没修续传本身**。

⚠️ **本处没有专门的反证用例**：续传判定内联在 `tryBeginSlice`（NetManager 实例方法）里，
而它必然调用 `startSliceTask` 起真实下载任务；要钉住它得先把判定抽成纯函数（如同 `sliceBudget`），
属另一件事。本处目前靠**忠实移植 + 全流水线不回归**（含 `DownloadAdapterTests` /
`DownloadMergerTests` / `DownloadSliceBudgetTests` 等下载侧用例）交付，反证用例留待补。

## 一处只在提交信息里存在的缺陷：启动桥的隔离错配（2026-09-25）

`f4e7578` 的提交信息写着「`SLLaunchBridge.slLaunch` / `slLaunchInternal` 被推断 @MainActor，
却被 `DispatchQueue.global().async` 调用（编译器不报）→ 真实数据竞争。改为 nonisolated。」
但 `git show f4e7578 -- qwq/SLCore/SLLaunchBridge.swift | wc -l` = **0** —— **那个文件它一行没改**，
基线 `3ba8ce5` 与本地都是裸 `func`。也就是说这是个「**两个分支都没修、只在文档里修了**」的缺陷。

我按它描述的方式改了（两处都加 `nonisolated`）并实测，结论是**不能这么改**：
- 口径二（`-default-isolation MainActor`）裸计数告警 **24 → 210**，多出的 **93 条（带冒号口径）全在 `SLLaunchBridge.swift`**，
  是 `log()`、`DataManager.shared`、`.version`、`.manifest`、`javaVirtualMachines` 等
  **主 actor 隔离成员被非隔离上下文访问**；
- 口径一也多 2 条：`@Sendable` 闭包捕获非 Sendable 的 `MinecraftLauncher` / `LaunchOptions`。

即：启动链**本身就工作在主 actor 隔离状态上**，把它标成 `nonisolated` 只是把长期被
「默认推断掩盖」的隔离问题一次性掀开。真正的修法要让整条链贯通隔离语义（哪些必须留主 actor、
哪些要显式 hop），是**独立一轮的重构**，不是补一行。本处**已撤销**，保持 0 新增告警。

**验证**：`./scripts/typecheck.sh` 两口径 **0 错误**、告警 **44 / 24 与基线逐条一致**（新增 0）；
`./scripts/verify-build.sh` → **BUILD SUCCEEDED**；`./scripts/verify-test.sh` →
**TEST BUILD SUCCEEDED**；`./scripts/verify-test.sh run` → **232 用例 0 失败、1 跳过**（原 231 + 新增 1）。
新增用例 `NoticeCenterTests.testPostOnMainThreadIsSynchronous`：主线程 `post` 后**不 await 立即断言**，
只有同步投递才可能通过。

## 分片总超时不再一刀切：慢但健康的下载不再被判失败（2026-09-25）

**症状**：进度明明在走，某个分片 5 分钟后被判超时；反复几次之后，**已下好的临时分片被删掉**，
界面报下载失败。换个网络或重试才有机会成功 —— 看起来像「源不稳定」。

**根因**：`SLCore/Download/NetSliceFetcher.swift` 的分片总超时写死 300s，与分片大小、网速
**都无关**。而超时的后果不是「晚点到」而是「失败」，链条是：
每次超时给该源记一次 `sourceFails`（阈值 `maxFailPerSource = 3`，`NetDownloader.swift:38`）
→ 满 3 次该源被 `pickSource` 永久跳过 → 全部源满 3 次则 `isAllSourcesFailed` 把文件置为
failed 并 `cleanupTemps` **删掉已下好的分片临时文件**（进度归零）。

触发面并不窄，两条路都通：
- 分片是「切已下区间的尾部 40%」逐步裂开的（`NetSliceAllocation.swift:64`），
  分片池（`maxSlices = 16`）被占满时，大文件仍是一个大分片；
- github / gitcode 这类被 `NetSliceAllocation.swift:53` 判为「禁多线程」的源**从不分片**，
  整个文件就是一个分片 —— 300s 直接罩住全文件。

**改法**：预算改为 `clamp(剩余字节 / 最慢实测速度 × 2, 300s, 1200s)`。
- 速度取本分片**观测到的最慢值**（刻意保守：预算只增不减），避免开头一个速度尖峰把预算算小；
- **下界 300s 不动** → 快连接 / 小分片的判定与改动前逐秒一致，正常路径没有被顺手放宽；
- 上界 1200s → 病态涓流仍会被截断，只是从 5 分钟放宽到 20 分钟；
- 大小未知（`sliceUndone` 返回 -1，服务端无 Content-Length）时**无法估算，退回 300s** ——
  这是**有意保留**的旧口径，不是漏改（没有总长度，任何估算都是编的）；
- 「慢速优先于总超时抛出」的原有判定顺序未改（预算在判定**之后**用本窗口速度重算）。
公式抽成纯函数 `nonisolated static func sliceBudget(remainingBytes:bytesPerSecond:)`：
调用点藏在需要真实网络栈的字节循环里，不抽出来就没法钉住它。

**新增用例 `qwqTests/DownloadSliceBudgetTests.swift`（6 条）**：下界不许放松 / 慢而健康的连接
预算必须大于预计耗时（用例自带「这确实是旧口径受害者」的证明）/ 上界必须生效 /
剩余量不可知退回旧口径 / 速度不可用不许算出 NaN / 剩余越多预算不许变小。

**验证**：`./scripts/typecheck.sh` 两口径 **0 错误**（告警 44 / 24；口径一 +2 为新增测试文件的
统计口径产物，已记入脚本头部）；`./scripts/verify-build.sh` → **BUILD SUCCEEDED**；
`./scripts/verify-test.sh run` → **231 用例 0 失败、1 跳过**，`** TEST EXECUTE SUCCEEDED **`。

**反证（用例的「牙齿」实测）**：把 `sliceBudget` 还原成旧的固定 300s 后重跑该测试类，
**恰好是暴露本缺陷的那两条变红**，其余 4 条仍绿（它们在旧口径下本就成立，符合设计）：
```
testSlowButHealthyConnectionIsNoLongerKilled failed:
  XCTAssertGreaterThan failed: ("300.0") is not greater than ("341.3333333333333")
testPathologicalTrickleIsCappedAtCeiling failed:
  XCTAssertEqual failed: ("300.0") is not equal to ("1200.0")
```
`341.33s` 就是 100MB @ 300KB/s 的真实耗时 —— 旧口径比它短 41s，所以**必然**误杀。

## 「取消」变成真的取消：准备期不再偷偷把游戏拉起来（2026-09-25）

**症状（用户视角）**：下载/校验阶段点右下角电源键，界面确实复位了，但过了几十秒**游戏自己弹出来**。

**根因**：`GameSession.launcher.terminate()` 只能终止**已经起来**的进程。而从点「启动」到进程
`run()` 之间（皮肤资源包准备 → 启动前补全，最长 600s、可能下载数百 MB → Java 选择）
**根本还没有 launcher 对象**，`terminate()` 无从下手；原先的取消分支只做了 `resetProgress()`
与相位复位，后台准备链完全感知不到「用户已经不要了」，于是照常跑完并 `process.run()`。

- **新增准备阶段取消令牌 `SLCore/SLLaunchBridge.swift`（`LaunchCancellationToken`）**：
  与既有 `isUserTerminated` 的分工是**时段**而不是重复 —— 后者管「进程已起、要终止它」，
  本令牌管「进程还没起、别再起了」。显式 `nonisolated` + `NSLock`（创建在主线程、读取在准备线程）。
- **桥接层五处判定点**（`slLaunchInternal`）：① 函数入口 ② 进入启动前补全之前
  ③ 补全等待期间 ④ Java 选择之前 ⑤ 拉起进程之前。任一命中都以 `LaunchError.cancelled` 收口并 `return`。
  ①放在函数入口的额外收益：**「已取消 ⇒ 绝不启动」这条断言可以脱离游戏目录确定性地单测**
  （否则要造一整套实例夹具才走得到）。
- **补全等待改为可打断**：原实现是一次性 `wait(timeout: .now() + 600)`，用户在这 10 分钟内点取消，
  最早也要等补全整个跑完才可能被察觉（最多白等 10 分钟、白下载数百 MB）。
  改为 **200ms 分片轮询**（3000 × 0.2s，上限仍 600s，不用时钟所以不受系统时间调整影响），
  可感知等待从「最多 600s」降到「≤0.2s」。残余的在途下载无法立即停止（下载层无取消检查点），
  但它只写本地缓存目录、下次启动可直接复用，且本函数已 return，不再阻塞流程。
- **`Features/Launch/LaunchCoordinator.swift`**：
  - 每次启动新建令牌并挂到 `LaunchSessionManager.launchCancellationToken`（电源按钮只有
    `sessionManager` 一个入参，挂这里既不必新增全局可变状态，也不用把有状态的引用塞进
    `LaunchRequest` —— 后者是 `Equatable` 值类型，塞进去会破坏其等价语义）；
  - `handlePowerTap` 的取消分支置位令牌（原先只复位界面）；
  - 失败上报**按令牌判定为「用户主动取消」时不弹错误框** —— 判据读令牌本身而非错误文案，
    这样无论错误从 `.failed` 事件还是 `launch(_:)` 抛出回来都能识别；
  - 皮肤/语言后台准备期间就取消的，直接不再发起启动（省掉一次完整桥接流程）。
- **`MinecraftInstanceLaunchService.swift`**：新增 `launch(_:cancellation:)` 重载
  （协议入口 `launch(_:)` 不变，转调本重载并传 nil，行为与旧路径逐条一致）；
  `mapFailure` 对 `.cancelled` 原样透传，不再落进「按文案前缀匹配」的兜底分支退化成
  `.unknown("启动已取消")`。
- **残余窗口兜底**：判定点⑤与 `launch()` 之间仍有极短间隙（主线程取消可能恰好插进去）。
  `.launcherReady` 分支据此改为：令牌已置位时**不建会话**（否则界面会留下一个没有进程、
  也无法终止的幽灵日志卡）并直接 `terminate()` 刚拉起的进程。

**新增反向用例 `qwqTests/LaunchCancellationTests.swift`（4 条）**：已置位令牌 →
必然 `.cancelled` 且**绝不**触发 `onLauncherReady`/进度/相位/成功；未置位令牌 → 入口判定不误拦；
`launch(_:cancellation:)` 原样透传 `.cancelled`；令牌重复取消幂等。
按项目纪律，正向链路（`RealLaunchIntegrationTests`）证「该启动的能启动」，
本文件证「该拦住的真被拦住」，两边都要有。

**验证**：`./scripts/typecheck.sh` 两口径 **0 错误**（告警 42 / 24；口径一 +2 是新增测试文件
带来的 `@testable import` 统计口径产物，非回归，已记入脚本头部）；
`./scripts/verify-build.sh` → **BUILD SUCCEEDED**；`./scripts/verify-test.sh build` → **TEST BUILD SUCCEEDED**；
`./scripts/verify-test.sh run` → **225 用例 0 失败、1 跳过**，`** TEST EXECUTE SUCCEEDED **`
（崩溃标记 `pointer being freed` / `Restarting after unexpected exit` 均为 0）。

**反向用例的「牙齿」是实测出来的，不是声明出来的**：把入口判定临时注释掉后重跑，
两条用例立刻变红，且失败信息正好复现原缺陷机制 ——
`XCTAssertEqual failed: ("nil") is not equal to ("Optional(LaunchError.cancelled)") -
实际是 MyLocalizedError(reason: "无法创建实例: …")`，即**取消被完全忽略、流程一路走到创建实例**
（现实中就是一路走到 `process.run()` 把游戏拉起来）；另一条报
`instanceNotFound(...) is not equal to cancelled`，即取消没有被透传。
恢复判定后工作区干净、`git status` 无残留。

⚠️ 本批实测到一个**新的验证盲区**：`reportLaunchFailure` 闭包捕获了**后面才声明**的 `let cancellation`，
`./scripts/typecheck.sh` 报 **0 错误**、`./scripts/verify-build.sh` 报 **1 个 error**
（`closure captures 'cancellation' before it is declared`）。原因是该诊断属**明确初始化**类，
由 **SILGen 阶段**发出，而 `swiftc -typecheck` 只跑到类型检查就停，结构上看不到它。
即 typecheck 的失效模式不止「漏 import 成员」，还漏**整类初始化顺序错误** ——
凡改动涉及「闭包/局部函数捕获同作用域的 `let`」，必须补跑真实编译。

## 两处隐蔽缺陷修复：写盘崩溃路径 + 日志旁路无上限（2026-09-25）

**背景**：五个子系统交由并行只读侦察找线索，由主代理**逐条亲自核实**后修复。
本轮只收录已核实的两条；另有若干条属行为变更，列在文末待确认。

- **`SLCore/Download/NetSliceFetcher.swift`（:138 / :158）、`SLCore/Download/NetMerger.swift`（:97）：
  三处写盘改用 throwing API，消除「写失败即崩进程」**。
  原写法是无返回值、不可 `try` 的 `FileHandle.write(_:)`，它在写失败（磁盘满、IO 错误）时抛的是
  **ObjC 异常 `NSFileHandleOperationException`** —— Swift 的 `do/catch` 抓不到，进程直接崩。
  而磁盘空间预检**只覆盖 `size > 50MB` 的文件**（`NetSliceFetcher.swift:236`），
  小文件与合并阶段本就没有兜底。改为 `try handle.write(contentsOf:)` / `try out.write(contentsOf:)`
  （工程他处 `FileManagerExtension.swift`、`MinecraftLauncherLog.swift` 早已采用此写法）：分片侧的错误
  沿 `runSlice` 的 `throws` 进入 `sliceFailed`，走既有的断流续传 / 源判死路径；合并侧由外层既有
  `catch` 先删除被写截断的目标文件再重抛，避免残缺文件被后续 `.skip` 预检固化为「已存在可复用」。

- **`Features/Launch/LaunchCoordinator.swift`、`Features/Launch/LaunchSessionManager.swift`、
  `SLCore/SLLaunchBridge.swift`：日志缓冲不再无上限增长**。
  `pendingLogs` 的清理点原本**只有 `LaunchSessionManager.addSession` 一处**（仅在建立会话时执行一次）。
  用户关掉日志卡片（`removeSession`）后游戏仍在运行，`.log` 事件查不到会话 → 持续
  `l.pendingLogs.append(logLine)`，一直堆积到进程结束才随对象释放；Forge/NeoForge 刷屏级长会话下
  内存呈线性增长，且与 `GameSession` 已有的 20000 行上限**互不相干**（那是另一条路径）。
  判定依据由「**当前**有没有会话」改为「**是否建过会话**」：`SLLaunchBridge` 增补 ObjC 关联标志
  `hasEverHadSession`（与既有 `pendingLogs` / `isUserTerminated` 同一存储模式），`addSession` 中置位，
  `.log` 分支改为 `else if !l.hasEverHadSession` 才暂存，否则丢弃。
  注意：本改动只制止堆积，**不改变**「会话存在期间日志照常落地」的行为。

**判定暂不动（需先确认）**：上一节提到的「准备期点取消、游戏照常启动」一项已在本轮修复
（见文首「取消变成真的取消」）；「分片 5 分钟总超时不随速度缩放」也已在下一节修复。
**仍不动的只剩一条**：`NetDownloadState` 的 `sourcesOnce` 把「服务器忽略 Range、不支持断点续传」
等同于「该源已死」，会导致本可单线程下完的文件被判失败并删掉健康数据 ——
修它要把「判死」改成「降级为单线程整份下」，动的是下载调度状态机，**留给单独一轮**。

**验证**：`./scripts/typecheck.sh` 两口径 **0 错误**（告警 40 / 24，与基线一致，新增 0、消掉 0）；
`./scripts/verify-build.sh` → **BUILD SUCCEEDED**；`./scripts/verify-test.sh` →
**TEST BUILD SUCCEEDED**；`./scripts/verify-test.sh run` → **221 用例 0 失败、1 跳过**。

## 全流程运行审查后的六处修复（2026-09-24）

**背景**：按要求把程序「从头到尾跑一遍」，判据取工程内的两个 skill ——
`.opencode/skills/swiftui-expert-skill`（其 **Correctness Checklist** 原文写的是
「These are hard rules -- violations are always bugs」）与 `.opencode/skills/swift-style-skill`，
外加工程自己的注释政策（≥15 行的文件注释密度 ≥20%、文件头写职责/边界、每类型每属性 `///`）。
查出问题后本轮修掉六处；另有几处**经核对判定不动**，理由记在文末。

- **`Features/ModBrowser/LocalModCatalog.swift`：目录解析器换代，峰值常驻内存 249.6 MB → 174.4 MB**。
  原实现用 `JSONSerialization` 把 122477 条目录先展开成 Foundation 对象图（每行一个 `[String: Any]`）
  再手工搬进 `Item`。用同一份真实数据实测（两个独立可执行文件，指标取
  `mach_task_basic_info.resident_size_max`）：**对象图建完那一刻就占 210.5 MB**，全程峰值 249.6 MB；
  换成 `JSONDecoder` 直解后峰值 174.4 MB（**省 75 MB，约 30%**），耗时同为 0.4 s 量级，
  产物逐条一致（首/末条 title 比对相同）。改法：新增短键 wire 结构 `BundleEntry` / `BundleCatalog`
  （键名 `i/t/n/d/c/u/x` 由 `crawl_modrinth.py` 定死），字段**全部声明为可选**以保住旧实现的容错语义
  （旧代码逐条 `compactMap`，某行缺字段只丢那一行；若用非可选字段，一条坏数据会让整个 decode 抛错、目录全空）。
  另：`Item` 与两个新结构体显式标 `nonisolated` —— 工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
  未标注类型的 `Decodable` 一致性会被推断成主 actor 隔离，在 `nonisolated` 解码路径里使用会报
  `[#IsolatedConformances]`（Swift 6 下是错误）；用最小探针实测 `struct X: Decodable` 报警、
  `nonisolated struct X: Decodable` 不报
- **`Features/Launch/GameSession.swift`（+ `LaunchCoordinator` / `LaunchSessionManager` / `SessionLogCardView`）：日志不再无上限、也不再逐行广播**。
  `@Published var logs` 原先没有任何裁剪，且每追加一行就向全部订阅者广播一次 —— Forge / NeoForge
  启动期一秒能刷几十行，日志卡片被反复整表重算；会话又只在用户点 × 时移除，游戏退出后整份日志仍留在内存。
  现改为：① **合并窗口** —— 新行先进非 `@Published` 的缓冲，每 0.1 s 才写一次 `logs`（合并的是广播次数，
  行序与完整性不变）；② **摊还裁剪** —— 超过 20000 行时一次丢到 3/4 处（每 5000 行才搬一次数组，
  而不是每行一次）；③ `logs` 改 `private(set)`，**唯一写入口**收成 `appendLog(_:)` / `appendLogs(_:)`；
  ④ 卡片顶部在裁剪发生后显示一行「较早的 N 行已省略」，不假装日志是完整的
- **`App/qwqApp.swift`、`Features/Download/DownloadDetailView.swift`、`Features/Game/VersionSelectionSection.swift`：`ForEach` 身份改用稳定键**。
  Correctness Checklist 原文：`ForEach` 必须用稳定身份（**never `.indices`/`\.offset`**）。
  分类菜单改用 `\.element.id`（`Category` 是 `Identifiable` 且 `Category.all` 是 `static let`，UUID 稳定）；
  安装阶段表原先因为「元组不能做 `Identifiable`、键路径也取不到元组成员」才退化成下标，现收成
  `InstallStageRow`（身份 = 阶段本身）；版本网格的行身份由行下标改为「本行第一个版本的游戏版本号」
- **`App/ViewModels/LaunchPanelState.swift`：提示层不再被无关设置写入作废**。
  原先它转发 `LauncherSettings.objectWillChange` 的**全部**变化（该对象有 19 个 `@Published` 字段），
  于是「在输入框敲一个字符」这类与该面板无关的写入也会作废提示层全部订阅者。
  改为逐字段订阅它真正暴露的 4 个（`$showLaunchAlert` / `$showJavaPopup` / `$javaPopupMessage` / `$launchErrorMessage`）
- **补 5 个缺文件头的文件**：`App/ContentView.swift`、`App/qwqApp.swift`、`App/AppDelegate.swift`、
  `Features/Download/ModpackInstaller.swift`、`Features/ModBrowser/ModVersionDetector.swift`。
  说明：全库 240 个（≥15 行的）Swift 文件**注释密度无一低于 20% 门槛**（中位数 35.2%，最低 20.2%），
  即"注释不够密"不成立，真正的缺口是文件头 —— 加上这 5 个之后全库已无缺文件头的文件
- **新增回归守卫** `qwqTests/GameLogRetentionTests.swift`（3 个用例：未超上限不丢 / 超限后上限不被突破且裁剪是摊还的 / 上限必须大到让 1/4 摊还量非 0）。
  为让上限这条不变量可测，`GameSession` 把裁剪判定抽成 `nonisolated static func dropCount(forCount:)` 纯函数 ——
  端到端不测是刻意的：`GameSession` 需要真实 `MinecraftLauncher`，而它的 init 会往用户 Application Support
  写日志并修剪历史日志，单测不该动这些真实数据

**经核对判定不动的三处**：
① 六个分类页在 `ContentView.categoryCanvas` 里是 `HStack`（非惰性容器）→ 各页 `onAppear` 冷启动即全部触发。
这是"首屏即有数据"的**刻意设计**（代码注释已写明），且各页重活本就在后台队列，改惰性容器会变成"切页才加载"的行为变更；
另需注意 `LazyHStack` 只在 `ScrollView` 内才真正惰性，脱离滚动容器未必有效；
② 离线用户名输入框直绑全局 `LauncherSettings` → 每敲一个字符全窗失效。可修（局部草稿 + 防抖回写），
但该字段正处于 `LauncherSettings → AppSettingsStore` 迁移中（`AppSettingsStore` 里已有同名的第二份声明），
此刻改绑定会引入第三份状态，留待迁移收口时一并处理；
③ `AppDelegate` 里把应用图标缩放到 0.7 倍：纯外观且 Dock 本就会按需缩放，属可删的冗余，但无功能影响。

- **验证**：`./scripts/typecheck.sh` 两口径 **0 错误**（告警 40 / 24；口径一 +2 是新增第 19 个测试文件的固定产物，
  `typecheck.sh` 头注释已记录）；告警集合已用 `git archive HEAD` 导出基线逐条 `comm` 比对，**新增 0 条、消掉 0 条**；
  `./scripts/verify-test.sh` → **TEST BUILD SUCCEEDED**；`./scripts/verify-build.sh` → **BUILD SUCCEEDED**；
  `./scripts/verify-test.sh run` → **221 用例 0 失败、1 跳过、无 abort**（218 → 221 即本次新增的 3 条）

## 崩溃日志信号安全 + 慢盘扫描不再丢结果（2026-09-24）

**背景**：对照上游 PCL2 原版（`Meloong-Git/PCL`，VB.NET/WPF）逐项核过之后的两处落实 —— 一处是本地自造的崩溃捕获在**信号路径里做堆分配**，另一处是本地自造的 **10 秒扫描超时会把迟到结果整条丢掉**。逐项对照与「哪些其实不是本地改坏」记在 `../SL-原版PCL2对照.md`。

- **`App/CrashReporter.swift`：信号路径改为真·零分配**。上一轮（`8dfebf8`）只去掉了字符串插值与 `ctime`，**没去干净**，信号路径里还剩 4 处堆分配：`open(logPath, …)` 的 String→C 串桥接、`[CChar](repeating: 0, count: 24)`（itoa 缓冲）、`[CChar](repeating: 0, count: 19)`（时间缓冲）、`[UnsafeMutableRawPointer?](repeating: nil, count: 128)`（取栈缓冲，约 1 KiB）。现改为：日志路径在安装期 `strdup` 一次，三个缓冲全部走 `withUnsafeTemporaryAllocation`（栈上），并补上 `errno` 保存/恢复。另 `strsignal` **不在** macOS 的 async-signal-safe 清单里（`man 2 sigaction` 的 Base / Realtime / ANSI C / Extension 四段均无），换成静态字面量表 —— 顺带消掉旧日志里 `signal: 11 (Segmentation fault: 11)` 的重复编号。**实测**（`malloc` 拦截器 + 真实 SIGSEGV）：信号路径内分配次数 **23 → 8**，而这 8 次在「纯 C 处理器只做 `signal`+`raise`」的对照里**一模一样**，即本文件自身的分配已为 **0**
- **`Features/Game/GameCategoryView.swift` + `ViewModels/GameCategoryViewModel.swift`：扫描超时不再丢结果**。原判据 `guard !viewModel.scanTimedOut else { return }` 会在 10 秒超时后把**迟到但有效**的扫描结果整条丢弃 → 慢盘（机械盘/外接盘/同时在下解压）上界面永久停在「未找到游戏版本」，必须手动点一次全盘查找才恢复。改为**扫描代际号**：`resetScanState()` 递增并返回，视图对「超时回调」与「结果回调」都先核代际，**只丢已被新一代扫描取代的回调**。超时本身只负责提前把界面从「检索中」放出来，不再作废结果（超时退化仍只做一次）。这同时修掉一个同源缺陷：上一代的超时闭包会把刚开始的新扫描判成「已超时」
- **新增回归守卫** `qwqTests/GameScanGenerationTests.swift`（3 个用例：代际递增并返回 / 超时后当前代际仍有效 / 迟到结果落地后展示状态翻回），用例一律写成 `async`（遵循 `qwqTests/TESTING.md` §五）
- **核对后判定「不是本地改坏」的两处**：①「选 Java 时先等扫描、找不到就触发扫描再选」是 PCL2 原版行为（`ModJava.vb` 的 `SelectOrDownloadJava`，`WaitIfRunning()` + `Start()` + 重选）；② Java 需求判定「按版本号优先、只有非标准版本才退回发布时间」也是原版口径（`ModJava.vb` 的 `GetJavaRequirement`），本地上批已改到同一方向，无需再动
- **本次未动（理由已核）**：`SLLaunchBridge` 的线程模型（原版同样把重活放后台线程、碰 UI 时显式 `Dispatcher.Invoke`；本地补这层等于把 60–70 行搬回 UI 层，属大范围，且该桥已列为待删除的过渡层）、`NetSliceAllocation` 未知文件大小时的挂起、`SkinPatchCoordinator` 跨版本装载

- **验证**：`./scripts/typecheck.sh` 两口径 **0 错误**（告警 38 / 24；口径一 +2 是新增第 17 个测试文件的固定产物，`typecheck.sh` 头注释已记录）；`./scripts/verify-test.sh` → **TEST BUILD SUCCEEDED**；`./scripts/verify-build.sh` → **BUILD SUCCEEDED**。用例运行需在 Terminal 执行 `./scripts/verify-test.sh run`

## 文档与代码对齐（2026-09-23）

**背景**：模块化重构（拆巨型文件、删死代码、全库去 PCL 品牌命名）已全部落地，但部分文档仍停留在重构前或自相矛盾。本轮只改文档（除 `qwqTests/JavaResolverTests.swift` 一处过期头注释外不碰任何 Swift 代码），逐条核对后对齐：

- **`qwqTests/TESTING.md`**：原「一、添加 XCTest target」整节已过期（工程早已存在 `qwqTests` unit-test target，并借 `PBXFileSystemSynchronizedRootGroup` 自动同步整个 `qwqTests/` 目录，`qwq.xcscheme` 的 TestAction 已挂 `qwqTests.xctest`）。改为「已完成」现状说明；统一测试文件数（14）与用例数（181），补全被漏掉的文件表行（`RealLaunchIntegrationTests.swift`）
- **告警基线统一为 44 / 56**：`scripts/typecheck.sh` 头注释已明确「以 44 / 56 为准」（有 `git archive HEAD` 逐条 diff 复核），`REFACTOR_PLAN.md` / `README-Game.md` 中残留的「口径二 58」一并改为 56；判定标准保持「告警集合与基线一致，不是只看数量」
- **行数统计去漂移**：`docs/MODULE-INVENTORY.md`、`ARCHITECTURE.md`、`README-Minecraft.md`、`README-Game.md`、`README-Skin.md` 中随拆分而失真的「N 行」表述改为职责描述，并在 `MODULE-INVENTORY.md` 顶部加统计日期；`REFACTOR_PLAN.md` 中「最大文件 889 → 487 行」改为职责描述
- **`README.md` 目录树**：补 `qwq/Core/`、`Features/` 下的 `Theme`、根目录的 `qwqTests/`、`docs/`
- **`README-Minecraft.md`**：`MinecraftInstance` 的「构造与启动（`launch`）保持不变」与代码相反——`launch(_:)` 已于 2026-09 删除，启动统一走 `SLLaunchBridge.slLaunch`，已更正
- **品牌残留核对**：全库仅剩 1 处漏改品牌命名（`scripts/slice_merge.swift`，由另一任务处理）；`README.md` / `CHANGELOG.md` 中的 PCL/PCL2 提及均属「算法出处引用」正当保留，无该改未改之处
- **`qwqTests/JavaResolverTests.swift` 头注释**：原称 `JavaModule` 依赖的 `SLModule`/`ModuleContext`/`ModuleCapabilityKey` 未落地、无法编译——实际 `Core/Module/SLModule.swift` 与 `ModuleRegistry.swift` 均已就位，改为说明不覆盖 `JavaModule.register` 的真实原因（内部硬编码 `DefaultJavaRepository()` → `JavaManager.shared`，无注入点）

- **验证**：本轮仅文档与一处注释，无编译影响；告警基线口径以 `scripts/typecheck.sh` 为准（44 / 56）

## 死代码清理 + 命名统一（2026-09-23）

**背景**：工程源自上游两个开源项目，历史上累积了一批「类型上存在、运行期不可达」的假功能与兼容层遗留。本轮在**只删可证明不可达的代码**这一前提下集中清理，并把全库命名统一为自有命名。

- **删除旧启动流程（`MinecraftInstance.launch(_:)`）**：工程长期并存两套启动流程（旧流程与新桥接流程）。经全库核实，旧流程**零调用方**——`grep -rn "\.launch(" qwq qwqTests` 的全部命中都是 `MinecraftLauncher.launch` / `LaunchService.launch` / `MinecraftInstanceLaunchService.launch(_:)`，无一是它，运行期永不可达。整段删除（`MinecraftInstance.swift` 235 → 118 行）。删后失去唯一调用方的三个符号（`MinecraftCrashHandler.exportErrorReport`、`MinecraftInstaller.createCompleteTask`、`PopupManager.showAsync`）**保留在工程内**——它们是补齐启动能力的现成参考实现，对应能力缺口记入 `Features/Launch/Adapters/LAUNCH_FLOW.md`
- **兼容层死符号全部删除**（`STUBS_AUDIT.md` 第二轮标注的 9 项）：`URL.parent()` 与 `URL.init(fileURLWithUserPath:)`、`ColorSchemeOption`、`AccountError.networkUnavailable` / `.popupNotAvailable`、`AnyAccount.isFullyImplemented`、`PopupManager.isAvailable`、`Theme`、`AppRouter` 类整体（含 `Route` 三个 case / `getLast` / `removeLast` / `append`）。`URL.parent()` 的 14 处调用点全部改为系统原生 `deletingLastPathComponent()`
- **删除依赖 `AppRouter` 的不可达分支**：`InstallTask` 中 `if case .installing(_) = DataManager.shared.router.getLast()`——全库无任何 `append` 调用点，路由栈恒空、`getLast()` 恒返回 `.other`，该条件运行期**永不成立**，其 `removeLast()` 从未执行。删除后控制流与原来「条件不成立」那条路**完全等价**（已逐行核对 diff）。真实页面切换由 `DownloadDetailManager` 承担，未受影响
- **其它零调用方死代码**：`MinecraftLauncher.isCancelled`（no-op 桩：读恒 false、写被静默丢弃）、`resolveGameDirURL()`、`NoasyncBridge.swift`（`LockCompat.swift` 拆分后只剩一个零调用方空壳函数）、`LoaderSupportState.supportedLoaders(for:)` 及其读侧缓存 API（同文件写侧由探测层调用，已保留）
- **命名统一**：`qwq/PCLCore/` → `qwq/SLCore/`、`PCLStubs.swift` → `Stubs.swift`、`PCLLaunchBridge.swift` → `SLLaunchBridge.swift`、`PCLNetFile` → `SLNetFile`、`pclLaunch` → `slLaunch`、`pclLaunchInternal` → `slLaunchInternal`、`pclLegacyUuidHex` → `legacyUuidHex`、实例配置文件名 `.PCL_Mac.json` → `.SL.json`、DispatchQueue 标签、83 处文件头模板。工程用文件夹同步组，`project.pbxproj` 内既无 `.swift` 条目也无 `PCL`，故**无需改动工程文件**；git 全部识别为 rename，历史未丢
- **用户可见字符串去上游品牌**：启动参数 `launcher_name`、下载请求 `User-Agent`、崩溃日志与导出文件名 → `SL启动器`。**注释中的「算法出处引用」按引用例外保留**（形如「移植自上游 PCL2 的 `ModLaunch.vb` / `McLoginLegacyUuid`」）——删掉会丢失「这段算法从哪来、为什么这么写」的信息，性质是引文而非品牌
- **修正注释失真**：`Stubs.swift` 等文件中大面积的「`文件:行号`」引用标注改为「文件 + 符号」形式。行号会随任何一次编辑漂移，经前两轮改动后其中大量标注已指向错误位置、甚至指向已删除代码；符号名不漂移
- **验证**：`./scripts/typecheck.sh` 两口径 **0 错误**、告警**集合逐条等于基线**（口径一 44 / 口径二 56，用 `git archive HEAD` 导出基线单独实测后 diff 得出）；`./scripts/verify-build.sh` 真实 `xcodebuild` **编译通过，0 错误**

## 配置回退遗留残留清理（2026-09-22）

**背景**：`17cca21`「部署目标回退至 macOS 13.0」只改了 `project.pbxproj` 的 4 行（2 增 2 删），**没有清理**此前为 macOS 12.0 目标（`e62d7f3`）增补的兼容代码——这些代码从此成为死状态。按既定决定（macOS 12 支持单独隔离处理、主目标锁定 13.0）予以清理。

- **并发**：删除 `SLCore/Utils/LockCompat.swift`
  - `withUnfairLock`（`os_unfair_lock` 作值类型属性 + `&lock` 取地址）→ `ModrinthSearchCache` 改用 `OSAllocatedUnfairLock`（macOS 13.0+）。Apple 文档明确警告前者的不安全之处：「it's unsafe to use `os_unfair_lock` from Swift because it's a value type… Instead, use `OSAllocatedUnfairLock`, which avoids that pitfall」。同时把 `cached` / `inFlight` **并入锁所保护的状态**，此后无任何路径能在不持锁时访问这两个字典。因泛型 `Value` 无约束、而 `withLock` 要求 `R: Sendable` 且闭包 `@Sendable`，故使用官方等价变体 `withLockUnchecked`（加锁语义完全相同，仅不做 Sendable 检查）
  - `NSLock.withLockCompat`（冗余：`NSLock.withLock` 在 SDK 中声明为 `macOS 10.10+` 并经 `@_alwaysEmitIntoClient` 回部署，本项目 13.0 目标本就直接可用）→ Translation 模块 5 处改用原生 `withLock`；两处闭包单表达式的返回值非 Void，补 `_ =` 承接原 `@discardableResult` 的「显式丢弃」语义
  - `semaphoreWait` **保留**（它是 Swift 书认可的 `noasync` 正规规避方式），迁至 `SLCore/Utils/NoasyncBridge.swift` 并订正注释
- **SwiftUI**：删除 `UI/CompatModifiers.swift`——其立论前提「项目最低部署目标为 macOS 12」与工程实际（四处均为 `MACOSX_DEPLOYMENT_TARGET = 13.0`，无 xcconfig 覆盖）不符，且 `defaultFocusCompat` 全库零调用方 → `ContentCard.swift` 改用原生 `.contentTransition(.opacity)`
- **验证**：`./scripts/typecheck.sh` 两口径 **0 错误**，告警**集合逐条等于基线**（口径一 44 / 口径二 56，用 `git archive HEAD` 导出基线单独实测后 diff 得出）；`./scripts/verify-build.sh` 真实 `xcodebuild` **编译通过，0 错误**
- **顺带发现（未改，待确认）**：**默认窗口尺寸 900×660 现已无任何生效声明**。`e62d7f3` 删掉了 `qwqApp.swift` 的 `.defaultSize(width: 900, height: 660)`，改用 `AppDelegate` 中 `if #unavailable(macOS 13.0)` 的兜底；`17cca21` 把部署目标回退到 13.0 后该分支永不执行，兜底实际从未生效；而 `e624d33` 那次窗口尺寸审计只覆盖了 **minSize**，未发现 defaultSize 已丢失。修法一行：在 `.windowStyle` 后恢复 `.defaultSize(width: 900, height: 660)`——属用户可见的行为改动，本次仅订正注释并记录，未实施

## 皮肤资源包兼容 26.2 + 启动体验（2026-08-20）

- **皮肤资源包修复（26.2+ 兼容）**：新版（25w31a+）资源包格式改用必填 `min_format`/`max_format`（resource pack ≥ 65 时旧字段 `pack_format`/`supported_formats` 会被判定 "no longer compatible" 并剔除）——现在从版本 jar 内 `version.json` 动态读取 `pack_version.resource_major/minor`，≥ 65 写新格式、老版本回落 `pack_format`；同时修复资源包临时目录未创建导致打包失败的问题。真机验证 26.2-Fabric 正常加载（`Reloading ResourceManager: vanilla, file/SL 皮肤.zip`）
- 游戏启动强制中文：每次启动前将目标版本 options.txt 的 `lang` 写为 `zh_cn`
- 版本选择列表支持横向滑动（版本多时左右拖动查看，避免超出卡片高度被裁）

## 编译警告清零（2026-08-17）

- 全项目编译警告 34 → **0**（macOS 12 目标、Swift 5 语言模式全量构建验证）
- 并发：新增 `SLCore/Utils/LockCompat.swift`，`withUnfairLock` / `NSLock.withLockCompat` / `semaphoreWait` 同步中转函数（Apple 建议的 `OSAllocatedUnfairLock` 需 macOS 13，本方案 12 可用且加锁语义与原 lock/unlock 配对完全一致）；`ModpackDownloader`、`ModDownloader`、`SearchTranslator`、`TranslationService` 中 async 上下文内的裸锁调用全部改为作用域锁，去重逻辑保持「检查+登记」原子性
- Sendable：`CardTranslationModel` weak self 捕获改为进 `MainActor.run` 前拷成强引用常量（写回仍受 `isActive` 守卫）；`ModFileDownloadStarter` 捕获 var 改常量拷贝、移除未使用捕获
- 机械项：删除无意义 `try?`（2 处）、`withAnimation` 结果丢弃（1 处）、多余的 `nonisolated(unsafe)`（2 处）

## 最低系统要求降至 macOS 12.0（2026-08-17）

- 部署目标由 macOS 13.0 降至 macOS 12.0（README 系统要求同步更新）
- 全量替换 macOS 13 专属 API 为 12 可用等价物（行为不变）：
  - `URL.appending(path:directoryHint:)` / `appending(component:)` → `appendingPathComponent(_:)`（101 处，脚本批量替换 + 人工核对）
  - `Task.sleep(for: .seconds/.milliseconds)` → `Task.sleep(nanoseconds:)`
  - `URL.applicationSupportDirectory` 静态属性 → `FileManager.default.urls(for:in:)[0]`
  - `String.replacing(_:with:)` → `replacingOccurrences(of:with:)`
  - `URL.path(percentEncoded:)` / `path()` → `path`
- SwiftUI：新增 `UI/CompatModifiers.swift`，`defaultFocus`、`contentTransition(.opacity)` 以 `#available` 包装修饰符（`defaultFocusCompat` / `contentTransitionOpacityCompat`）；`Scene.defaultSize` 因 SceneBuilder 在 macOS 12 目标下不支持条件语句，改由 `AppDelegate` 在 `applicationDidFinishLaunching` 中统一设置默认窗口尺寸（900×660 居中）
- 依赖无影响：SwiftyJSON / ZIPFoundation 的最低平台要求均低于 macOS 12
- 全量编译验证通过（swift build，macOS 12 目标，0 错误）

## 仓库规范整理（2026-08-17）

- 新增 `README.md`（项目介绍、功能状态清单、构建说明、PCL2/PCLMac 致谢与引用说明）与 `LICENSE`（GPL-3.0），修复公开仓库无许可证即默认保留所有权利的问题
- 修复 Bundle ID：`-23.qwq`（横杠开头，不合法）→ `io.github.asdfasdfasdfasdfasdf111.SL`（按 GitHub 用户名反向域名约定）
- 源码目录重组：`qwq/` 下 88 个平铺的 Swift 文件按功能归入 `App/`、`Features/`（Launch / Game / Download / ModBrowser / Translation / Skin / Java / Settings）、`Services/`、`UI/`，与既有的 `SLCore/`、`Models/` 结构统一；纯磁盘移动，未改动任何代码
- 根目录清理：删除空的 `build_and_run.sh`；`crawl_modrinth.py`、`slice_merge.swift`、`test_catalog.swift` 移入 `scripts/`
- `.gitignore`：本地构建目录合并为 `/build_*/` 通配

## Beta 0.1.10 版本发布 🚀（2026-08-14）

新增全项目深度扫描校准（覆盖 40+ 文件：启动/下载/安装/资源/皮肤/Java/目录扫描全部核心模块；模式：外部数据强解包崩溃、无锁共享状态、任务归属）：客户端清单缺 assetIndex 字段（1.5.2 及以下旧版本无独立资源索引）不再强解包崩溃，改为置空 objects 跳过散列资源阶段；ArtifactVersionMapper 用第三方清单拼出的 URL 含空格等非法字符时回退保留原 path；LocalModCatalog 解压 bundle 目录资源为空 Data 时提前返回；Util.mavenCoordinate 解析/主类读取/目录替换、JavaVM 损坏 release 文件、CacheStorage 空 index.json、MinecraftInstance 配置与清单读取、VersionManifest 异常日期、ClientManifest 库坐标越界、DownloadSourceManager 测速节流 Date 数据竞争等全部回退兜底或加锁

新增相邻版本预加载：详情页切换版本时静默预取相邻版本加载器状态（in-flight 合并防重复联网），切版本最常看相邻版本，先转圈后秒开
新增加载器支持检测逐加载器流式状态：检测结果按「版本 × 单个加载器」拆分，每个加载器检测完成立即更新对应卡片（checking 转圈 → 支持/不支持/重试），不再等全部加载器结束才一次性出列表；首帧先用缓存已定论项 + 未定论项转圈初始化，未缓存版本从「白等 8~32 秒」变为「最快 0.5~2 秒先看到部分结果」
新增按加载器粒度缓存：缓存由整版本一份列表拆为每加载器一条定论（supported 14 天 / notSupported 7 天，快照与 1.21+ 最新大版本 24 小时，unavailable 永不缓存），部分加载器网络失败不再拖累整版无法缓存——下次只重查未定论的那几个，其余秒开；兼容旧版整列表缓存格式自动迁移
新增检测响应数据复用：加载器支持检测请求到的版本数组（Fabric/Quilt loader 数组、Forge/NeoForge 版本数组）存入内存缓存，下载时 LoaderVersionResolver 直接复用解析加载器最新版本号，检测与下载解析不再各请求一次同一端点

优化 build_audit/（303MB ASan 审计构建产物目录）加入 .gitignore 忽略，与 build_asan/、build_asan2/、build_asan3/ 等同系列构建目录统一不再入库
优化游戏日志管道解码：readabilityHandler 的 availableData 边界不是 UTF-8 字符/日志行边界，逐块解码会让多字节中文/emoji 跨块变乱码、长行被拆成两行；改为跨回调保留尾部字节的缓冲区，仅在遇到换行符才解码整行（与 SLLaunchBridge 增量日志读取同款方案），非法 UTF-8 行丢弃、不再产生替换乱码
优化导航栏分类切换动画：从 Downloads 中旧版同名工程直接移回原始分类画布实现——所有分类页完整横向 HStack 排布，点击导航使用旧版 spring（response 0.6 / damping 0.65 / blend 0.15）连续滑动，从第 1 项跳到第 5 项会真实经过中间页面；恢复 DragGesture.onChanged 实时跟手与松手 25% 阈值切页/原位回弹。替换当前版「仅当前页+起点页完整、其余轻量占位」方案，同时保留下载详情覆盖层及其导航栏常驻逻辑
优化加载器检测请求：每加载器从「每端点 2 次重试 × 8s 超时」收敛为单请求 4s 请求 / 6s 资源超时（列表展示无需下载级等待），最坏等待从 16~32 秒降至 4 秒级；双源加载器（Fabric/Quilt）改为主源立即请求 + 700ms 后并行备用源的延迟并发，不再等主源完整超时才兜底
优化同版本请求合并：同一 MC 版本的并发检测（详情页重复进入 / 切回 / 预加载与前台同时触发）复用同一个 in-flight 检测任务，绝不重复向四个加载器端点发请求
优化启动按钮下载阶段文案：该阶段实际在执行游戏文件/资源完整性检查（含 Java 运行时按需获取），旧文案「Java 下载中」易让玩家误以为卡在 Java 安装；改为「正在检查游戏完整性」更贴合真实行为，安装阶段文案「Java 安装中」保持不变

修复游戏进程退出回调竞态（GPT 交叉复核采纳）：完成回调虽经一次性门控只落一次 UI，但不保证「回调先于进程引用清理」——回调内快速重启游戏时，旧 launch 线程晚到执行 `instance.process = nil` 会清掉新启动进程的引用；现正常退出与启动失败两条清理路径均做进程身份归属校验（`instance.process === process` / `currentProcess === process` 才置 nil），沿用崩溃 #4 归属保护规则
修复游戏进程退出回调竞态：正常退出（terminationHandler）与 1 秒轮询兜底都可能回调 UI，旧实现在进程「退出但 handler 尚未触发」时两条路径先后触发，导致启动状态被重复复位（重复重置进度/相位）；现两条路径与 run() 抛错共用一次性门控，只回调一次，另在启动失败时补发非零退出码回调并清理进程引用，UI 不再可能卡在「启动中」。日志管道解码改为失败兜底（原强制解包会在 Java/模组输出非法 UTF-8 时直接崩溃启动器）；窗口检测与退出兜底的成功通知加一次性门控，避免 UI 复位逻辑执行两次
修复下载调度器停止竞态：调度循环判断「无任务」到清空 tickTask 引用之间，若新下载入队会因看到旧引用而跳过启动；现清空后原子重检有活动任务则立即重新拉起调度，新任务不再可能永久停在等待态不下载
修复缓存索引保存时机错误：缓存库注册 add() 在把条目追加进内存索引之前就落盘 index.json，磁盘索引永远缺少刚注册的库，重启后按索引查不到该库、且命中文件已存在时直接 return 也不补内存索引；现改为先 append 再 save，dest 已存在时也补齐内存索引，索引与磁盘始终一致
修复启动卡片高度改为随内容区动态：上一版把卡片高度钳制在固定 380–410pt，窗口偏矮时卡片反而比内容区高、偏高时又缩在中间不协调；现改为 `max(0, 内容区高度 - 40)`，上下各留 20pt 空隙、底部不贴边但始终延伸到底部附近，任何窗口尺寸下卡片与右侧内容区同步伸缩
修复下载详情页圆按钮仍显过低：详情页底部存在外层裁剪，上一版把按钮底部间距提至 36pt 仍偶发偏低；现再上移 8pt（36→44），按钮完整落入窗口可视区、不再被圆角裁掉，滚动内容底部安全空间不变
修复启动页左侧卡片高度被拉满：`GeometryReader` 中左卡片内部的两个 `Spacer` 会在可伸缩容器里把背景矩形撑到整个内容区底部，形成截图中的过长竖向矩形。现给启动卡片增加 380–410pt 的内容高度约束，保留内部布局与启动逻辑，仅限制背景卡片尺寸；不引入墓碑机制，不改下载后端
修复下载详情页布局偏移：版本号与返回箭头距离左侧内容边界过近，和下方加载器卡片没有对齐；将详情内容层左内边距从 28pt 调整为 56pt，标题、返回箭头、版本选择区块统一起点。下载按钮原底部间距仅 12pt，在窗口底部裁剪区域容易贴底/被截断；调整为 36pt，按钮整体上移并保留详情页滚动内容底部 90pt 安全空间。仅修改 ModDetailView UI，不引入墓碑后台机制，不改下载后端
修复镜像源空结果误判：备用镜像返回 404/空数组不再等同「该版本不支持」，仅官方权威源的 404/410/空数组可下定论；镜像空结果按「结果未知」处理走其他源，避免镜像端点未实现导致 Fabric/Quilt 被误报不支持
修复逐加载器流式实际仍等待全部完成：旧 streamLoaderStates 内部先 await 聚合字典再逐项 yield，导致未缓存项仍一次性出现；现为 TaskGroup 每完成一项立即向全部订阅者广播，同时最终快照兜底覆盖「读缓存→订阅」窗口，逐项渲染真正生效
修复 HTTP 4xx 误缓存为“不支持”：旧实现把 401/403/408/429 等鉴权、超时、限流错误也视为权威不支持并缓存；现严格仅 404/410 下定论，其余统一 unavailable、不写缓存
修复 in-flight 合并竞态：查询/创建/登记改为同一锁区间原子完成，避免两个调用同时创建两组请求；每条任务新增 UUID ownerID，完成清理和流订阅解绑均校验归属，旧任务迟到不会清掉新任务；清缓存先摘除全部条目再 cancel 旧任务，沿用崩溃 #4 归属保护规则
修复当前版本缓存全命中时不预加载相邻版本：相邻版本预取移到提前返回之前，缓存秒开的空闲窗口也会预热下一次最可能切换的版本
修复旧版资源索引跳过逻辑顺序错误：上一版虽然为缺少 assetIndex 的旧版本增加判空，但判空位于下载 URL 构造之后，官方源与镜像源会先返回空 URL 数组并抛错，导致跳过分支永远无法执行；现将 assetIndex 判空前移到所有下载源调用之前，1.5.2 及以下无独立资源索引的版本会真正置空 objects 并继续安装，同时清理 DownloadSourceManager 的行尾空格使差异检查恢复通过

## Beta 0.1.9 版本发布 🚀（2026-08-14）

优化异步任务归属校验（崩溃 #4 教训通用化）：游戏分类页 fetchItems 引入请求令牌（fetchToken），每次加载/刷新/切换分类递增，网络任务与本地目录任务写回前校验令牌一致才更新列表；仅靠 cancel()+isCancelled 存在竞态窗口（旧任务已通过取消检查、新任务已启动时旧结果仍可能覆盖新列表），令牌校验保证迟到的旧结果一律丢弃、也不再触发无效翻译预取。加载器检测（上一版）、列表加载统一走「取消 + 归属校验」双保险

优化缓存统一（缓存治理第一步）：游戏根目录列表缓存由 UserDefaults.stringArray 迁入统一 CacheManager（内存 LRU 32MB + 磁盘按 key 分文件、两层散列目录），避免 UserDefaults 存大数组膨胀；迁移期自动回退读取 UserDefaults 旧缓存一次后写入新缓存并清除旧值，老用户无感切换。读取链路（锁内查内存 → 锁外读盘 → 回写内存）与翻译/版本清单缓存同构，缓存命中不再触发 UserDefaults 全量 plist 编解码

## Beta 0.1.8 版本发布 🚀（2026-08-14）

修复启动器打开时名称框自动聚焦并全选：`.defaultFocus(false)` 只约束 SwiftUI 的默认焦点，AppKit 仍会把窗口第一个可聚焦控件（用户名 TextField）自动置为 firstResponder，表现为打开即进入编辑态并全选。现启动页挂载一个 0×0 占位 NSView，在页面加入窗口、布局完成后再主动 `makeFirstResponder(nil)` 清空焦点（双次派发确保在 AppKit 自动聚焦完成后执行），用户主动点击或按 Tab 才聚焦
修复启动页头像延迟约 0.x 秒才出现：原实现在 SwiftUI body 内同步读 skinImageURL 且依赖 onAppear 异步加载两个图层裁剪，首帧头像为空、等 JAR 提取/磁盘写入完成才显示。现保留双层渲染（头 + 帽层叠加），但皮肤数据在视图创建时从本地预载（持久化皮肤原图 → 离线 UUID 皮肤磁盘缓存 → 内置 Steve，均为毫秒级小文件）供首帧直接裁剪显示；后续换版/JAR 提取结果经 onChange 后台刷新数据缓存，body 内不再每次重绘重复读盘
修复头像改动引发的第二层（帽）图层丢失：初版方案改为直接展示预裁剪头像 avatarImageURL，但未选装自定义皮肤时该路径回退到内置 Steve 头部（无帽层），导致头像只剩头层；已回退为既有双层 SkinLayerView 渲染，仅预载数据提速
修复启动首帧名称框仍被选中：上一版 FirstResponderReset 用双次派发清焦点，但执行时窗口可能尚未成为 key、AppKit 的自动聚焦在其之后才发生，表现为「先全选、约 1 秒内恢复」。现改为可接收焦点的占位 FocusSinkView 抢占窗口 initialFirstResponder，并监听 didBecomeKeyNotification 在窗口成为 key（AppKit 完成自动聚焦）后再抢一次，仅启动头 2 秒生效、不干扰后续手动聚焦
修复启动首帧头像仍空白约 0.x 秒：皮肤数据虽已预载，但 SkinLayerView 内部仍在 onAppear 异步裁剪（首帧渲染 Color.clear 透明占位）。现改为在 init 同步裁剪 8×8 区域（毫秒级）作为 @State 初始值，body 直接渲染成品；双层视图按数据加 .id(data)，皮肤数据变更时强制重建重新裁剪，消除「先空白后出现」的闪烁

## Beta 0.1.7 版本发布 🚀（2026-08-14）

优化下载吞吐：直连会话每主机连接数由 8 提至 16，与全局分片池上限（16）对齐——此前 16 个分片只有 8 条连接可用，等效最多 8 路并发；同时启用 HTTP/1.1 管线化减少同主机往返等待。分片写缓冲由 64KB 提至 256KB，落盘次数降为 1/4。分片最小分割粒度由 256KB 提至 1MB，且仅大于 4MB 的大文件才允许多分片：MC 安装的依赖库数以千计且普遍只有几十 KB~几 MB，小文件多分片只会争抢分片池，把并发让给真正的大文件后整体吞吐更高
优化加载器版本解析双源兜底：Forge 主源（BMCLAPI）网络失败时回退官方 files.minecraftforge.net 索引（promos 取 recommended/latest），NeoForge 回退官方 Maven metadata.xml（按「1.20.1→20.1、1.21→21.0」前缀过滤取最新）；请求成功但结果为空视为「明确不支持」立即报错，不重复请求，仅网络故障才切官方源
优化加载器支持检测网络层：改用全局共享直连会话（8s 请求/15s 资源超时、禁系统代理、4 并发、管线化），不再每次检测新建 URLSession 浪费 TCP/TLS 握手；Fabric/Quilt 检测补齐 BMCLAPI 镜像兜底，与下载解析双源统一，避免「列表显示支持、下载解析失败」；NeoForge 按版本过滤，仅 1.20.1+ 发起请求

修复加载器列表「鬼畜」误判：网络失败 / 5xx / 超时被当作「空数组 → 没有加载器」，且切换版本时旧检测任务迟到的结果会覆盖新版本结果。现检测结果三态化（supported / notSupported / unavailable）：明确不支持（404/410/空数组）才显示「暂无可用的加载器」，网络失败显示「暂时无法获取 + 重试」绝不误报；结果未知不写缓存（避免覆盖旧缓存），过期磁盘缓存兜底；检测任务增加取消与归属校验（切换版本或销毁视图后旧结果不再写 UI）；快照版本（24w14a）不做「明确不支持」缓存
修复加载器检测两处残留问题：① 部分加载器已定论 + 部分网络故障时，不再把残缺列表写入 7 天缓存（此前会缓存残缺列表，超时的那几个加载器在 UI 上长期「消失」），改为只临时展示已确认列表、下次进入重新检测；② 切换版本开始检测时立即清空上一版本的加载器列表（加载中 / 网络失败态下，底部下载按钮的 loaderSupported 判定不再误用旧版本数据，避免把旧版本支持的加载器错误安装到新版本上）


新增已装版本列表加载器后缀显示：游戏分类版本列表直接读 versions/ 文件夹名，扫描时自动把「文件夹名是纯版本号、但实际装了加载器」的历史遗留版本目录重命名为「版本-加载器」（如 1.6.1 → 1.6.1-Forge），并同步改写 version.json 的 id 字段与 json 文件名；检测依据为 version.json 的 libraries 依赖（net.minecraftforge:forge / net.fabricmc:fabric-loader / net.neoforged / org.quiltmc）或 inheritsFrom 名称，无 json / 已带后缀 / 目标重名一律幂等跳过，绝不覆盖。新下载流程本已产出带后缀目录（GameVersionDownloadStarter 拼 name），本机制兜底历史遗留与第三方启动器装的版本；游戏分类与模组详情页本地版本列表统一生效

## Beta 0.1.5 版本发布 🚀（2026-08-14）

修复下载报 SSL 错误：系统代理（如 Clash 127.0.0.1:12002）对 bmclapi2 / mojang 域名的 TLS 转发失败时，URLSession 报「An SSL error has occurred and a secure connection to the server cannot be made.」（同一 URL 用 curl 直连正常），Forge 安装器、原版 jar、依赖库等下载全部失败且每源重试 3 次共耗时约 45 秒；现启动器网络层统一禁用系统代理直连（connectionProxyDictionary = [:]），API 请求、分片下载、加载器支持检测、Java 运行时下载全部改走直连，官方源被墙时按既有双源机制自动切镜像，不再依赖用户代理软件出口
修复下载切源耗时过长：连接层错误（SSL 握手失败 / 无法连接 / DNS 失败 / 连接中断 / 超时）下同源重试无意义，旧实现每源重试 3 次才切换；现遇连接层错误直接将失败计数拉满，pickSource 立即跳过该源换下一个，失败反馈从约 45 秒降至秒级
修复选择下载版本时第一个卡片放大被裁剪：加载器选择横滚列表 HStack 缺水平 padding，第一个卡片放大 1.08 时向左溢出被 ScrollView 裁切；补齐水平 padding（与版本卡片列表一致，预留放大动画空间）
修复启动器打开时名称框自动被选中：macOS 上绑定了 .focused 的 TextField 是窗口中第一个可聚焦控件时，AppKit 会在窗口成为 key window 时自动将其置为 firstResponder；现显式声明默认焦点为 false，用户主动点击或按 Tab 才聚焦

## Beta 0.1.4 版本发布 🚀（2026-08-13）

修复模组版本降级匹配过宽：Beta 0.1.3 的最后两级降级（放弃加载器过滤 → 完全放弃过滤取最新）会把实际不兼容的文件（错误加载器、错误游戏版本）下载进游戏目录，例如 Forge 环境装到 fabric 版、1.18 装到 1.20 版；现删除这两级，保留 PCL2 语义的「API 精确 → 精确版本+加载器 → 主版本前缀+加载器」三级，全部失败明确报「未找到兼容的模组版本」，绝不静默装错文件
修复分类切换动画起点内容闪没：切换瞬间旧分类页立即被轻量占位替换，视觉上「内容闪没 + 空占位滑出」，动画起点丢失原页内容；现动画期间保留旧分类完整页一起滑出，spring 动画播放结束后再释放为占位（带归属校验的延时清理，快速连切不互相干扰）
修复手动单源设置被悄悄跨源兜底：用户选择「仅官方/仅镜像」时，单文件下载与 DownloadItem 仍无条件追加互补源 URL，实际请求了用户明确排除的另一方域名（仅官方也会请求镜像站），破坏设置语义；现仅「自动切换」模式才追加互补源，单源模式只使用所选源、失败即明确报错

## Beta 0.1.3 版本发布 🚀（2026-08-13）

新增分类切换画布平移动画：从分类 1 切到 5 时动画真实经过 2/3/4 中间页（快速、非线性），中间页只渲染「图标+名称」轻量占位（零数据加载、零网络请求），后台不同时实例化 5 个完整页面，整页滑过的动画感与性能两者兼得
新增模组版本多级降级匹配：精确过滤失败后自动按「精确版本 → 主版本前缀（1.20 ↔ 1.20.x）→ 放弃加载器过滤 → 最新版本」逐级放宽，不再因版本号细微差异（如 1.20 与 1.20.1、快照版）直接报「未找到兼容的模组版本」

优化单文件下载多源化：原版 json / 资源索引 / 原版 jar 全部改为「主源+镜像源」双 URL 顺序下载（SLNetFile 多源失败切换），原版 jar 下载失败不再卡死在官方源
优化下载源测速切换：测速下载失败即时切换镜像源（测速失败本身就是官方源不可用的强信号），且不再在每次测速时把已切到镜像的源重置回官方（旧实现切换是一次性的）
优化下载源状态线程安全：源状态加 NSLock 保护，消除后台测速 Task 写入与读取方之间的数据竞争

修复原版 jar / 散列资源 / 依赖库下载失败不自动切换下载源：DownloadItem 备用源由硬编码官方源改为「与主源互补的源」（官方↔镜像任意方向失败互切）；散列资源旧实现硬编码官方 CDN（resources.download.minecraft.net），官方不可用时全部失败，现走 BMCLAPI 镜像（PCL2 同款 assets 规则）
修复下载失败不终止任务、不报错：MinecraftInstallTask 失败路径不再只清全局引用，改为记录失败原因并调用 complete() 触发完成回调——下载详情页正常关闭并弹出「下载失败」提示（旧实现详情页永远挂着、既不终止也不报错）
修复加载器（Fabric/Forge/NeoForge）安装失败被误报成功：失败时抛错中断整条安装链、状态置为 failed（旧实现吞掉错误后继续走后续步骤，最终弹「下载完成」）
修复 Modrinth 版本过滤多加载器参数编码错误：["fabric,forge"] 改为 ["fabric","forge"]（多值数组逐个引号包裹），否则被 API 当成单个不存在的加载器名，永远查不到结果
修复分类切换动画缺失：详情页单页替换 transition 期间卡片入场动画不可见即播完，改为画布 HStack 横向排布 + offset 平移（.id 强制重建当前页），中间页轻量占位掠过

## Beta 0.1.2 版本发布 🚀（2026-08-13）

新增游戏版本一键下载安装，支持 Fabric/Forge/NeoForge 加载器自动串联（对标 PCL.Mac DownloadPage）
新增毛玻璃下载详情页与全局圆形下载按钮，移植 PCL 的 InstallTask 任务模型（总进度 / 实时速度 / 逐任务阶段渲染）
新增崩溃自捕获（CrashReporter），崩溃时把堆栈写入 ~/Library/Logs/qwq_crash.log
新增下载 SHA-1 校验（客户端 jar / 依赖库 / 原生库）
新增 JVM 启动参数动态补齐与调优（-XstartOnFirstThread / G1GC / -Xms 等，查重后追加）
新增离线用户名输入实时提示（PCL2 HintChinese 语义）
新增游戏安装并发下载：原版 jar 与散列资源、依赖库与 natives 分波并行（PCL2 风格，全局 16 分片统一限流），加载器只等待 jar、散列资源后台继续
新增下载阶段独立进度：InstallTask 并行阶段状态机（beginParallelStage/finishParallelStage），详情页各阶段进度互不覆盖
新增版本列表缓存优先：磁盘缓存供首帧立即可展示（cachedMerged），联网刷新转后台执行，弱网/离线时列表不再长时间空白
本地 Modrinth 全量目录更新至 122,477 条目

优化加载器支持检测：三级缓存策略（内存 → 磁盘 7 天 TTL → 联网失败回退旧缓存），4xx 视为明确不支持，首次等待由数秒降至约 1 秒
优化实时翻译：按需翻译 + 并发上限 24 + 内存上限 2000 条，滚动浏览不再卡顿
优化空闲静默后台：计速器惰性启动、游戏日志增量读取、窗口轮询降频，空闲时几乎零 CPU 与内存占用
优化在线列表缓存优先：离线 / 弱网也能秒开上次内容
优化下载详情页密度：左侧统计面板、任务卡片间距与全局下载按钮缩小，顶部标题与分类导航永久保留，仅替换导航下方内容区，切换分类自动收起详情
优化 Java 查找：7 类来源全量扫描，release 文件一次读取探测主版本
代码极致模块化：全工程巨型文件按「一个文件一个顶层声明」拆分为 30+ 个单一职责模块（累计 39 批收官）
优化build_asan3/ ASan 构建产物目录加入 .gitignore 忽略，与 build_asan/、build_asan2/ 同理不再入库

修复下载页选中未列出版本后立即崩溃：下载页合并清单与旧安装器 DataManager 清单不同步，旧代码查不到版本仍强制解包触发 assertionFailure；现先查旧清单、未命中再查合并清单 URL 索引，最终缺失时返回 nil 进入可恢复错误提示，彻底移除该路径断言
修复下载页游戏版本列表空白：官方 + 未列出两个清单源全部失败且无缓存时返回空数组；现增加 BMCLAPI 镜像自动回退（主源失败自动切换，不依赖设置二选一）+ CacheManager 磁盘缓存兜底（联网失败回退上次内容，弱网/被阻断时列表不再空白）
修复游戏版本下载首个 await 返回时的 EXC_BAD_ACCESS：Swift 6.2 在 Swift 5 + Approachable Concurrency + 默认 MainActor 组合下会误编译存储 async 闭包的 ABI（swiftlang/swift#86332），现将闭包属性与初始化参数显式统一为 @MainActor，杜绝隐式 actor 参数错位与损坏地址跳转
修复下载任务完成竞态导致的 UAF 风险：complete/dismiss 增加幂等与归属校验，杜绝旧任务迟到回调清掉新任务引用
修复 EXC_BAD_ACCESS 崩溃根因：全工程 17 文件 26 处视图生命周期回调同步状态写清零（Modifying state during view update）
修复下载链路 UAF：下载闭包零 self 捕获、动画改可取消 Task，视图销毁后不再写已释放的 State storage
修复启动参数规则匹配误删库（移植 PCL2 顺序叠加语义 Rule.check）
修复 JVM 参数动态补齐三处偏差（-Xmx 查重 / Log4Shell 防御 / natives 路径兜底）
修复 Java 查找链路五处功能失效（进程死锁 / 版本正则 / 并发覆盖 / 残留 JVM / stub 矛盾）
修复创建世界 / 进入世界 EncoderException（离线用户名超 16 字符，完整移植 PCL2 离线登录）
修复离线自定义皮肤无效（PCL2 皮肤资源包方案，全版本生效）
修复游戏关闭 / 手动关闭进程检测不到（terminationHandler 前置 + 超时轮询兜底）
修复下载详情页交互：圆按钮 toggle 开关、导航下方内容互斥替换、退出后滚动位置恢复
修复首次下载原版 JSON 失败：NetManager 未创建 Swim111Launcher/Temp 目录导致分片临时文件无法落盘；现初始化及每次下载前双重确保目录存在
修复全部文件命中缓存时下载进度重复扣减：跳过分支已逐项计数，批次收尾只更新总体进度
修复光影详情页返回后侧栏高亮不跳回
修复加载器选择页显示与所点版本不一致、1.10 等版本仍显示 4 张卡片
修复解压 ZIP 的路径穿越（ZIP Slip）漏洞
修复缓存读写并发死锁（NSLock → NSRecursiveLock）、崩溃日志误删共享目录、下载句柄未清理
修复下载进度负数、下载卡片无动画、Java 刷新按钮动画不同步
修复版本清单拉取失败缓存空结果、翻译缓存未全量应用等列表展示问题
修复并发下载进度不准：详情页按 stage 取独立进度、MultiFileDownloader 批次进度重复归一化（downloadAll 的 p 已是 0...1 不再除以文件数）、getProgress 除零/越界与 completeOneFile 完成计数下限保护

## Beta 0.1.1 版本发布 🚀（2026-08-07）

SL 启动器基线：游戏版本下载 / 安装 / 启动、账户与游戏目录管理
Modrinth 全量目录爬虫（crawl_modrinth.py）与本地全量列表 / 搜索 / 实时翻译
加载器检测缓存与重试、26.x 版本分类、详情页、版本卡片放大裁剪与图标映射
