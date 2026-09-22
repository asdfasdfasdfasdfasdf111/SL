# Swift 语言特性核对手册（Swim111Launcher）

> 用途：在 `xcodebuild` 被沙箱拦截、无法真正编译的前提下，用 `swiftc -typecheck` + 官方文档语义核对项目的并发/内存/值语义写法，供后续写代码时逐条查证。
>
> 范围：**只核对语言层面**（Swift 并发、内存与并发原语、值语义/引用语义）。不评价业务逻辑、架构、性能。
>
> 约束：本手册**只读**项目源码，未修改 `qwq/` 下任何文件。所有结论均给出官方文档链接；凡查不到官方依据的，明确标注「未找到官方依据，标记存疑」。

---

## 0. 环境与核验方法（可复现）

| 项 | 值 | 来源 |
|---|---|---|
| Swift 编译器 | Apple Swift 6.2.3 (swiftlang-6.2.3.3.21) | `swift --version` |
| SDK | MacOSX.sdk（Xcode 26） | `xcrun --show-sdk-path` |
| `SWIFT_VERSION` | `5.0` | `qwq.xcodeproj/project.pbxproj` |
| `MACOSX_DEPLOYMENT_TARGET` | `13.0` | 同上 |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `MainActor` | 同上（**关键**，下称「默认 MainActor 隔离」） |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `YES` | 同上 |
| `SWIFT_STRICT_CONCURRENCY` | 未设置（Swift 5 语言模式默认 `minimal`） | 同上 |

核验命令（已实跑，结果见 §5）：

```bash
# 全量类型检查（等价工程设置）
swiftc -typecheck -swift-version 5 -default-isolation MainActor \
  -target arm64-apple-macos13.0 -sdk "$(xcrun --show-sdk-path)" \
  -I <依赖模块路径> @<文件清单>
```

依赖 `SwiftyJSON 5.0.2`、`ZIPFoundation 0.9.20`（见 `Package.resolved`）需先编出 `.swiftmodule` 才能全量检查。

### 0.1 全量检查结果

| 配置 | error | warning | 备注 |
|---|---|---|---|
| 工程现状（`-swift-version 5 -default-isolation MainActor`） | **0** | **86** | 编译通过 |
| 同上，**去掉** `-default-isolation MainActor` | 0 | **20** | 对照：默认隔离设置额外引入 66 条告警 |
| `-swift-version 5 -strict-concurrency=complete -default-isolation MainActor` | 0 | **208** | 迁移预演；分 78 `SendableClosureCaptures` / 42 `ActorIsolatedCall` / 5 `ConformanceIsolation` |
| `-swift-version 6 -default-isolation MainActor` | **≥1**（编译提前终止） | 20 | 首个硬错误见 §2.4 |

结论：**当前工程在 Swift 5 语言模式下编译无错**；但 86 条告警中多数被编译器标注为「this is an error in the Swift 6 language mode」，迁移到 Swift 6 时会成批变红。下面的「重点标红」节按严重度列出。

---

## 1. 逐条核对表

### 1.1 async / await 与任务

官方来源：
- Swift 书《Concurrency》 <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/>
- `Task` <https://developer.apple.com/documentation/swift/task>

| # | 语法点 | 官方规则要点（原文关键句） | 项目对应位置 | 结论 |
|---|---|---|---|---|
| A1 | `async` / `await` 与挂起点 | “Inside an asynchronous method, the flow of execution can be suspended **only** when you call another asynchronous method — suspension is never implicit or preemptive — which means every possible suspension point is marked with `await`.” | 全局 | **写法正确**：项目未出现「隐式挂起」假设 |
| A2 | 同步代码中无法安全等待异步结果 | “In contrast, there's no safe way to wrap asynchronous code so you can call it from synchronous code and wait for the result. The Swift standard library intentionally omits this unsafe functionality — trying to implement it yourself can lead to problems like subtle races, threading issues, and deadlocks.” | `qwq/Features/Java/JavaResolverBridge.swift:19-50` | **写法错误（官方明文禁止的手写形态）**：该文件正是「自己实现从同步代码等待异步结果」。详见 §2.2 |
| A3 | `Task {}` 继承当前上下文 | “The new task defaults to running with the same actor isolation, priority, and task-local state as the current task.” | `qwq/UI/Notices/NoticeCenter.swift:138`（`Task { @MainActor in … }`） | **写法正确**；显式 `@MainActor` 与继承语义一致，冗余但不致错 |
| A4 | `Task.detached` 不继承任何上下文 | “The new task defaults to running **without any actor isolation** and doesn't inherit the current task's priority or task-local state.” | `NetDownloaderDownloadEngine.swift:91`、`AppContext.swift:71`、`JavaResolverBridge.swift:34`、`SLLaunchBridge.swift:290,313`、`CardTranslationModel.swift:48,83,102` | **部分有风险**：`Task.detached` 内访问被默认隔离到 `@MainActor` 的成员会被告警（见 §2.4~§2.8）；本身用 `detached` 的动机（脱离主线程）成立 |
| A5 | `Task.detached` 的 `operation` 当前是 `sending` 而非 `@Sendable` | SDK 签名实测：`static func detached(name:priority:operation: sending @escaping @isolated(any) () async -> Success)`；SE-0430：“When a call passes an argument to a `sending` parameter, the caller cannot use the argument value again after the callee returns.” | `JavaResolverBridge.swift:32,34,49` | **写法错误（竞态）**：编译器**不会**给出诊断（实测见 §5.4），故只能靠人工发现 |
| A6 | 取消是协作式的 | “it's the responsibility of the code running as part of the task to check for cancellation whenever stopping is appropriate… call the `Task.checkCancellation()` function” | `NetDownloaderDownloadEngine.swift:124-128`、`SLLaunchBridge.swift:294,315`、`MinecraftLauncher.swift:189-195` | **写法正确**：均通过 `Task.isCancelled` / 取消承载 Task 表达 |
| A7 | 任务闭包生命周期 | “Retaining a task object doesn't indefinitely retain the closure… Consequently, tasks rarely need to capture weak references to values.” | `NetDownloaderDownloadEngine.swift:90-93`（强引用 `self`）、`CardTranslationModel.swift:48`（`[weak self]`） | **写法正确**（两者都成立）：强引用在任务终结后释放；`[weak self]` 属保守写法，非错 |
| A8 | `TaskGroup` 结构化并发 | “In a parent task, you can't forget to wait for its child tasks to complete… When a parent task is canceled, each of its child tasks is also automatically canceled.” <https://developer.apple.com/documentation/swift/taskgroup> | `LoaderSupportChecker.swift:488,560`、`TranslationSourceFetcher.swift:16` | **写法正确**：`withTaskGroup` 离开作用域自动取消未完成子任务，注释亦如此声明 |
| A9 | `async let` 并行 | “Call asynchronous functions with `async`-`let` when you don't need the result until later in your code. This creates work that can be carried out in parallel.” | `MinecraftInstaller.swift:446-447,462-463`、`GameVersionManifest.swift:60-62` | **写法正确** |

### 1.2 actor 与隔离

官方来源：
- `Actor` <https://developer.apple.com/documentation/swift/actor>
- `MainActor` <https://developer.apple.com/documentation/swift/mainactor>
- SE-0306 Actors <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md>
- SE-0316 Global Actors <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0316-global-actors.md>

| # | 语法点 | 官方规则要点（原文关键句） | 项目对应位置 | 结论 |
|---|---|---|---|---|
| B1 | `actor` 串行化与跨 actor 需 `await` | “actors allow only one task to access their mutable state at a time”；“When you access a property or method of an actor, you use `await` to mark the potential suspension point.” | `SpeedMeter.swift:59-71`（`actor CounterActor`）+ `SpeedMeter.swift:31,44,50` | **写法正确**：`await self.counter.takeInterval()` / `await counter.add(1)` 均带 `await`，且非隔离 `init` 不触碰 actor 状态 |
| B2 | actor 可重入（reentrancy） | SE-0306：“When an actor-isolated function suspends, reentrancy allows other work to execute on the actor before the original actor-isolated function resumes… it means that actor-isolated state can change across an `await`”；“synchronous code in an actor provides a critical section, whereas an `await` interrupts a critical section.” | `SpeedMeter.swift:24-40`（ticker 循环内 `await` 后继续用 `self`） | **有风险（低）**：`ensureTicker` 在 `await self.counter.takeInterval()` 之后写 `self.tickerTask = nil`，跨 `await` 的两次检查非原子；当前无竞争来源，但迁到 Swift 6 时需复查 |
| B3 | `@MainActor` 类型：成员隐式隔离、跨入需 `await` | SE-0316：“A type declared with a global actor attribute propagates the attribute to all methods, properties, subscripts, and extensions of the type by default.”；“all of the normal actor-isolation restrictions come into play: the declaration can only be synchronously accessed from another declaration on the same global actor, but can be asynchronously accessed from elsewhere.” | `NavigationState.swift:15-16`、`NoticeCenter.swift:113`、`DownloadDetailManager.swift:13`、`CardTranslationModel.swift:12`、`SpeedMeter.swift:11` | **写法正确** |
| B4 | `@MainActor` 类型实例隐式 `Sendable` | SE-0316：“A non-protocol type that is annotated with a global actor implicitly conforms to `Sendable`. Instances of such types are safe to share across concurrency domains because access to their state is guarded by the global actor.” | `NavigationState.swift:15-16`（`@MainActor final class … ObservableObject`） | **写法正确**：无需再写 `Sendable` |
| B5 | **项目启用了默认 MainActor 隔离** | `-default-isolation MainActor`：未显式标注隔离的声明被推断为 `@MainActor`。实测（§5.1）：`final class PlainClass`、`enum` 的 `static func`、`Sendable` 枚举的计算属性**全部**变成 `@MainActor` 隔离 | 全项目；具体受害点见 §2.5~§2.8、§2.10 | **有风险（高，系统性）**：大量「看起来是纯函数/纯数据结构」的声明实际带 MainActor 隔离，任何后台线程/非隔离闭包访问都会告警→Swift 6 下报错 |
| B6 | `nonisolated(unsafe)` 用于关闭静态检查 | SE-0412：“The attribute `nonisolated(unsafe)` can be used to annotate the global variable (or any form of storage). Though this will disable static checking of data isolation for the global variable, note that without correct implementation of a synchronization mechanism to achieve data isolation, dynamic run-time analysis from exclusivity enforcement or tools such as Thread Sanitizer could still identify failures.” <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md> | `SpeedMeter.swift:18`（`nonisolated(unsafe) var tickerTask`） | **写法可接受**：访问点均在 MainActor 上下文（`ensureTicker`、`deinit`）。注意 `deinit` 非隔离，SE-0412 说明必须自行保证同步；此处 `tickerTask` 在 `deinit` 时已无并发写者，判定成立但脆弱 |
| B7 | `nonisolated` 显式退出隔离 | 同上（SE-0316 示例：`nonisolated private func gatherContents(url:)`） | `NoticeCenter.swift:116,132,137`、`NetDownloader.swift:34,69,79,83,87`、`LoaderSupportChecker.swift:518` | **写法正确**：`NoticeCenter.post` 是 `nonisolated` + 内部 `Task { @MainActor in … }` hop，符合「任意线程可调用」的声明 |
| B8 | MainActor 隔离的静态成员从非隔离上下文访问 | “Global and static variables can be annotated with a global actor. Such variables can only be accessed from the same global actor or asynchronously.”（SE-0316） | `LoaderSupportChecker.swift:271`、`NetDownloader.swift:245,563,605,608`、`LocalModCatalog.swift:93-99,113,127,174` | **有风险**：实测告警 `[#ActorIsolatedCall]`；详见 §2.6 |
| B9 | MainActor 隔离的**计算属性**从非隔离上下文访问 | 同上；实测（§5.2）：`Sendable` 枚举的计算属性在默认隔离下变 `@MainActor`，非隔离读取 → Swift 5 告警 / Swift 6 报错 | `GameSessionStore.swift:60`（`launchState.isTerminal`，定义于 `LaunchState.swift:42-47`） | **有风险**：告警 `main actor-isolated property 'isTerminal' can not be referenced from a Sendable closure`；详见 §2.9 |

### 1.3 Sendable

官方来源：
- `Sendable` <https://developer.apple.com/documentation/swift/sendable>
- SE-0302 <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md>
- SE-0430 <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md>

| # | 语法点 | 官方规则要点（原文关键句） | 项目对应位置 | 结论 |
|---|---|---|---|---|
| C1 | `Sendable` 的三类合法形态 | “The type is a value type, and its mutable state is made up of other sendable data…; The type doesn't have any mutable state…; The type has code that ensures the safety of its mutable state, like a class that's marked `@MainActor` or a class that serializes access to its properties on a particular thread or queue.” | `DownloadState.swift:16`、`LaunchState.swift:17`、`DownloadRequest.swift:27`、`MinecraftInstanceInfo.swift:93` 等 | **写法正确**：均为只含 `Sendable` 成员的枚举/结构体 |
| C2 | `@unchecked Sendable` 的责任归属 | “To declare conformance to `Sendable` without any compiler enforcement, write `@unchecked Sendable`. **You are responsible for the correctness** of unchecked sendable types, for example, by protecting all access to its state with a lock or a queue.”；“Classes that don't meet the requirements above can be marked as `@unchecked Sendable`… after you manually verify that they satisfy the `Sendable` protocol's semantic requirements.” | `NetDownloaderDownloadEngine.swift:18`、`GameSessionStore.swift:39`、`MinecraftInstanceLaunchService.swift:64,68,252,267`、`ProcessPoolGameProcessController.swift:54`、`LaunchFixPreflight.swift:124,140,168,211,234`、`MinecraftLauncher.swift:13,44` | **写法正确（需持续维护）**：每处都配了 `NSLock` / `OSAllocatedUnfairLock` 或「状态只在构造时写入」的说明。`LaunchFixPreflight.swift` 的 5 个 case 用 `@unchecked Sendable` 标注在**结构体**上是官方明确允许的形态 |
| C3 | `@Sendable` 闭包的捕获规则 | SE-0302：“Closures that have `@Sendable` function type can only use by-value captures. Captures of immutable values introduced by `let` are implicitly by-value; **any other capture must be specified via a capture list**”；“The types of all captured values must conform to `Sendable`.” | `SLLaunchBridge.swift:66-78`（`DispatchQueue.global().async { … }` 捕获 6 个闭包参数） | **有风险**：实测 6 条 `[#SendableClosureCaptures]` 告警（`progressHandler`/`phaseHandler`/`logHandler`/`launchSuccess`/`onLauncherReady`/`completion` 均为非 Sendable 函数类型）。Swift 5 为告警、Swift 6 为错误；详见 §2.11 |
| C4 | 显式 `@Sendable` 闭包内改捕获 var | 实测（§5.3）：`let g: @Sendable () -> Void = { x = 1 }` → **error: mutation of captured var 'x' in concurrently-executing code** | 项目未使用该形态（项目里的同类问题走 `Task`，见 A5） | **写法正确**：未踩此形态 |
| C5 | `DispatchQueue.async` 闭包内改捕获 var | 实测（§5.3）：`DispatchQueue.global().async { x = 1 }` → **warning: mutation of captured var 'x' in concurrently-executing code [#SendableClosureCaptures]** | `ProcessPool.swift:75,125`（`DispatchQueue.global().async { stdoutData = … }`） | **有风险（低）**：`stdoutData` 由后台写、主流程随后读，`sem.wait` 之前无人读取；实际存在竞态窗口但被 `terminationHandler` 时序掩盖。未产生告警（编译器仅对显式 `@Sendable`/`DispatchQueue.async` 形态报） |
| C6 | `sending` 与游离区域 | SE-0430：“A `sending` function parameter requires that the argument value be in a disconnected region. At the point of the call, the disconnected region is no longer in the caller's isolation domain…”；“In the Swift 5 language mode, `sending` diagnostics are suppressed under minimal concurrency checking, and diagnosed as warnings under strict concurrency checking.” | `JavaResolverBridge.swift:32,34,49`（正是「实参未游离、调用后又被使用」的反例） | **写法错误**：违反 `sending` 契约；且实测在 `minimal`/`complete`/Swift 6 三档下**均无诊断**（§5.4），属编译器盲区 |

### 1.4 AsyncStream

官方来源：
- `AsyncStream` <https://developer.apple.com/documentation/swift/asyncstream>
- `init(_:bufferingPolicy:_:)` <https://developer.apple.com/documentation/swift/asyncstream/init(_:bufferingpolicy:_:)>
- `Continuation` <https://developer.apple.com/documentation/swift/asyncstream/continuation>
- `BufferingPolicy` <https://developer.apple.com/documentation/swift/asyncstream/continuation/bufferingpolicy>
- `finish()` <https://developer.apple.com/documentation/swift/asyncstream/continuation/finish()>
- `onTermination` <https://developer.apple.com/documentation/swift/asyncstream/continuation/ontermination>

| # | 语法点 | 官方规则要点（原文关键句） | 项目对应位置 | 结论 |
|---|---|---|---|---|
| D1 | 回调 → AsyncStream 的正确桥接 | “AsyncStream… is well-suited to adapt callback- or delegation-based APIs to participate with `async`-`await`.`”；“Produce elements in this closure, then provide them to the stream by calling the continuation's `yield(_:)` method.” | `NetDownloaderDownloadEngine.swift:101-122,174-197` | **写法正确**：`observe(taskID:)` 返回流、`publish` 内 `continuation.yield(state)`；回调 `(Double) -> Void` 经 `publish` 转成流元素 |
| D2 | `for await` 消费 | “Because the stream is an `AsyncSequence`, the call point can use the `for`-`await`-`in` syntax to process each `Quake` instance as the stream produces it.” | 项目内消费点分散在 ViewModel/View（未逐个列出） | **写法正确**（未发现错误用法） |
| D3 | `finish()` 终结语义 | “When there are no further elements to produce, call the continuation's `finish()` method. This causes the sequence iterator to produce a `nil`, which terminates the sequence.”；`finish()` 文档：“Resume the task awaiting the next iteration point by having it return nil, which signifies the end of the iteration.” | `NetDownloaderDownloadEngine.swift:219`、`GameSessionStore.swift`（未显式 finish，靠 `AsyncStream` 建流闭包结束时终结） | **写法正确**：终态时对全部订阅者 `finish()` |
| D4 | 缓冲策略与背压 | `unbounded`：“Continue to add to the buffer, without imposing a limit on the number of buffered elements.”；`bufferingOldest(Int)`：“When the buffer is full, discard the newly received element.”；`bufferingNewest(Int)`：“When the buffer is full, discard the oldest element in the buffer.”；默认 `.unbounded`。**注意官方原文未出现 “back pressure” 一词**，只有「缓冲上限 + 丢弃策略」的描述 | `NetDownloaderDownloadEngine.swift:107`（`.unbounded`，注释理由：旧引擎已节流到 ~200ms，用有界策略反而可能丢终态） | **有风险（低）**：选 `.unbounded` 的依据（上游节流）成立，但**该保证来自项目注释而非官方契约**；旧引擎若改成高频回调，缓冲将无界增长。若要严格化，改为 `.bufferingNewest(N)` 并保证终态单独走 `finish()` |
| D5 | `Continuation` 是 `Sendable`、可跨上下文 `yield` | “The continuation conforms to `Sendable`, which permits calling it from concurrent contexts external to the iteration of the `AsyncStream`.”；`init` 文档补充：“It is thread safe to send and finish; all calls to the continuation are serialized. However, calling this from multiple concurrent contexts could result in out-of-order delivery.” | `NetDownloaderDownloadEngine.swift:217-220` | **写法正确**：`yield`/`finish` 在锁外调用，但仍然串行（由发布路径保证）。注意官方提示的「多并发上下文可能乱序」——本项目通过单一 `publish` 出口避免 |
| D6 | `onTermination` 的正确用法与死锁注意 | “Canceling an active iteration invokes the `onTermination` callback first, then resumes by yielding `nil`… After reaching a terminal state as a result of cancellation, the `AsyncStream` sets the callback to `nil`.”；“Because the system might call the `onTermination` callback as part of task cancellation, it's subject to the same considerations for avoiding deadlock as outlined in the documentation for `withTaskCancellationHandler`.” | `GameSessionStore.swift:74-76`（在 `onTermination` 里 `lock.withLock { … removeValue }`） | **写法正确**：闭包内只做 `OSAllocatedUnfairLock.withLock`（作用域锁，无 `await`、无阻塞等待），不会死锁 |
| D7 | 多订阅者与终态回放 | 官方无「多订阅者/回放」的直接条款（`AsyncStream` 是单消费者模型） | `NetDownloaderDownloadEngine.swift:22-28,101-122,199-221`（`continuations` 数组 + `terminalHistory` 回放） | **未找到官方依据，标记存疑**：`AsyncStream` 官方文档只描述单一迭代点；对同一 continuation 的多次 `yield` 分发给多个订阅者是项目自建语义，需在合并阶段确认。代码层面无语法错误 |
| D8 | `AsyncStream.makeStream` 替代写法 | “Initializes a new `AsyncStream` and an `AsyncStream.Continuation`.”（`static func makeStream(of:bufferingPolicy:)`） | 项目统一用 `AsyncStream(bufferingPolicy:) { continuation = $0 }` 双段式 | **写法正确**：`observe` 内先把 `continuation` 传出闭包再 `yield`（`NetDownloaderDownloadEngine.swift:104-112`），因为 `AsyncStream` 的 `build` 闭包返回后 `continuation` 仍可逃逸使用 |

### 1.5 续体（continuation）

官方来源：
- `CheckedContinuation` <https://developer.apple.com/documentation/swift/checkedcontinuation>
- `withCheckedThrowingContinuation` <https://developer.apple.com/documentation/swift/withcheckedthrowingcontinuation(function:_:)-13yf6>

| # | 语法点 | 官方规则要点（原文关键句） | 项目对应位置 | 结论 |
|---|---|---|---|---|
| E1 | 必须**恰好一次** resume | “**You must call a resume method exactly once on every execution path throughout the program.** Resuming from a continuation more than once is undefined behavior. Never resuming leaves the task in a suspended state indefinitely, and leaks any associated resources. `CheckedContinuation` logs a message if either of these invariants is violated.” | 全部续体使用点 | **部分有风险**：多数正确，但 `GameProcessController.swift:39-48` 存在「永不 resume」路径，详见 §2.1 |
| E2 | 回调式 API → async 的标准桥接 | `withCheckedThrowingContinuation`：“Invokes the passed in closure with a checked continuation for the current task.”；配合 `CheckedContinuation` 的「恰好一次」约束使用 | `MinecraftInstanceLaunchService.swift:97-149` | **写法正确**：用 `LaunchResumeGate`（`NSLock` + `claimed`）保证 `completion` 只 resume 一次，注释也点明「重复恢复会直接触发运行时崩溃」 |
| E3 | 续体在非主线程 resume 是否合法 | 官方未限制 resume 的线程；`CheckedContinuation` 本身 `Sendable`（见其 Relationships 节 `Conforms To: Sendable`） | `ProcessPoolGameProcessController.swift:121-132`（在 `DispatchQueue.global` 内 resume） | **写法正确** |
| E4 | 超时兜底避免永久挂起 | 见 E1（“Never resuming leaves the task in a suspended state indefinitely”） | `NoticeCenter.swift:158-175` | **写法正确**：`hasPresenter == false` 直接返回 0；否则投递一个 300s 兜底 `Task`。`choose` 用 `pending.removeValue` 保证超时与用户点选不会双重 resume |
| E5 | 续体跨 `await` 持有的状态 | 无专门的官方条款 | `NoticeCenter.swift:130`（`pending: [UUID: CheckedContinuation<Int, Never>]`） | **有风险（低）**：若调用方 Task 被取消而 UI 承载者仍在，`pending` 条目会保留到兜底超时（300s）后才清理；不会崩溃，但有 300s 的资源滞留。Swift 并发未提供 `withTaskCancellationHandler` 保护此表 |

### 1.6 锁与信号量

官方来源：
- Swift 书《Attributes》`noasync` <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/>
- `DispatchSemaphore` <https://developer.apple.com/documentation/dispatch/dispatchsemaphore>
- `OSAllocatedUnfairLock` <https://developer.apple.com/documentation/os/osallocatedunfairlock>
- WWDC21《Swift concurrency: Behind the scenes》 <https://developer.apple.com/videos/play/wwdc2021/10254/>

| # | 语法点 | 官方规则要点（原文关键句） | 项目对应位置 | 结论 |
|---|---|---|---|---|
| F1 | `noasync` 属性语义 | Swift 书：“The `noasync` argument indicates that the declared symbol can't be used directly in an asynchronous context. Because Swift concurrency can resume on a different thread after a potential suspension point, using elements like thread-local storage, locks, mutexes, or semaphores across suspension points can lead to incorrect results.”；“This attribute raises a compile-time error when someone uses the symbol in an asynchronous context.”；“If you can guarantee that your code uses a potentially unsafe symbol in a safe manner, you can wrap it in a synchronous function and call that function from an asynchronous context.” | `NoasyncBridge.swift:30-33`（原 `LockCompat.swift:32-37`；`semaphoreWait` 同步中转） | **写法有争议**：官方**确实**给出了「用同步函数包装以绕过 noasync」的正式做法，故 `LockCompat.semaphoreWait` 有官方依据。但官方语义是「你能保证安全时才这么做」——`semaphoreWait` 在语义上并未改变阻塞行为，只是绕过诊断，属「诊断规避」而非「安全化」 |
| F2 | 同步包装可绕过 noasync 的适用边界 | 同上：“You can wrap it in a synchronous function and call that function from an asynchronous context.”（官方示例是 `withLock` 作用域锁，本质改变了用法而非仅隐藏调用） | `LockCompat.swift:13-30`（`withUnfairLock`、`NSLock.withLockCompat`） | **写法正确**：作用域锁形态符合官方示例 |
| F3 | 信号量禁止在 async 上下文直接使用 | 实测（§5.5）：`DispatchSemaphore.wait()` 在 `async` 函数内 → Swift 5 **warning**：“instance method 'wait' is unavailable from asynchronous contexts; Await a Task handle instead; this is an error in the Swift 6 language mode”；Swift 6 → **error** | `LocalModCatalog.swift:97-99`（在 `Task.detached` 的 async 闭包内直接 `localCatalogLock.lock()/unlock()`） | **写法错误**：实测告警 `instance method 'lock'/'unlock' is unavailable from asynchronous contexts`；详见 §2.3 |
| F4 | 信号量阻塞协作线程池 | WWDC21 10254：“primitives like semaphores and condition variables are unsafe to use with Swift concurrency… **do not use primitives that create unstructured tasks and then retroactively introduce a dependency across task boundaries by using a semaphore or an unsafe primitive.** Such a code pattern means that a thread can block indefinitely against the semaphore until another thread is able to unblock it. This violates the runtime contract of forward progress for threads.” | `JavaResolverBridge.swift:31-48`、`SLLaunchBridge.swift:138-155,177-182`、`MinecraftLauncher.swift:139,189`、`ProcessPool.swift:52,72-82,110-131` | **有风险**：`JavaResolverBridge` 完全命中官方点名的反模式（unstructured task + 跨 task 边界用信号量建立依赖）。`SLLaunchBridge` 的 `fixSemaphore` 同理（见 §2.2 同源问题） |
| F5 | 锁在同步临界区内是安全的 | WWDC21 10254：“Using a lock in synchronous code is safe when used for data synchronization around a tight, well-known critical section. This is because the thread holding the lock is always able to make progress towards releasing the lock.” | `CacheManager.swift:11,21-45`、`NetDownloaderDownloadEngine.swift:46,145-170`、`LaunchResumeGate`、`GameLogWriter`、`LaunchProgressRelay` | **写法正确**：均为同步临界区，且锁内只做内存操作（`CacheManager.swift:48-51` 的注释与实现一致：磁盘 IO 全部在锁外） |
| F6 | `NSLock` 直接 `lock()/unlock()` 是 noasync | 实测（§5.5）：`l.lock()` / `l.unlock()` 在 async 上下文 → 同类诊断（Swift 6 error） | `NSLock.withLockCompat`（`LockCompat.swift:21-30`，同步包装，正确）；`LocalModCatalog.swift:97-99`（**未包装，错误**） | 见 F3 |
| F7 | `NSLock.withLock` 的可用版本 | `OSAllocatedUnfairLock` 文档：“it's unsafe to use `os_unfair_lock` from Swift because it's a value type… Instead, use `OSAllocatedUnfairLock`, which avoids that pitfall”；`OSAllocatedUnfairLock` 可用性：**macOS 13.0+** | `~~LockCompat.swift:6-10~~` 注释：「Apple 官方建议的 `OSAllocatedUnfairLock` / `NSLock.withLock` 需要 macOS 13」 | **注释有误（结论无害）**：实测（§5.6）`NSLock.withLock` 在 `-target arm64-apple-macos10.13` 下**可直接编译通过**（SDK 中经 `@_alwaysEmitIntoClient` 回部署，声明可用性为 `macOS 10.10, iOS 8.0`）。只有 `OSAllocatedUnfairLock` 确实需要 macOS 13。项目部署目标是 13.0，故 `withLockCompat` 属冗余但不错。**2026-09-22 已落地本结论**：该符号删除，Translation 模块 5 处调用改用原生 `withLock`（`_ =` 显式丢弃闭包返回值，替代原 `@discardableResult`） |
| F8 | 作用域锁跨 `await` 安全 | `OSAllocatedUnfairLock` 文档：“When using this approach, you must call `unlock()` from the same thread you use to call `lock()`. Because of this, **it's unsafe to use this approach across an `await` suspension point.** When using a lock with asynchronous code, lock using a closure or, even better, consider using an `Actor`.” | `MinecraftInstanceLaunchService.swift:77,153,186,190`、`GameSessionStore.swift:47,52,58,67,73-76`、`ProcessPoolGameProcessController.swift:63,73,104` | **写法正确**：全部使用 `withLock { }` 作用域形态，无 `lock()/unlock()` 跨 `await` |
| F9 | `OSAllocatedUnfairLock` 非递归 | “`OSAllocatedUnfairLock` isn't a recursive lock. Attempting to lock an object more than once from the same thread without unlocking in between triggers a runtime exception.” | 上列各处 | **写法正确**：无嵌套 `withLock`（`GameSessionStore.observe` 的 `onTermination` 与 `update` 不会重入） |

### 1.7 DispatchSource 内存压力

官方来源：`makeMemoryPressureSource(eventMask:queue:)` <https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource(eventmask:queue:)>；`activate()` <https://developer.apple.com/documentation/dispatch/dispatchobject/activate()>

| # | 语法点 | 官方规则要点（原文关键句） | 项目对应位置 | 结论 |
|---|---|---|---|---|
| G1 | 构造与事件处理挂载 | “After creating the dispatch source, use the methods of the `DispatchSourceProtocol` protocol to install the event handlers you need. **The returned dispatch source is in the inactive state initially.** When you are ready to begin processing events, call its `activate()` method.” | `AppContext.swift:76-84` | **写法正确（但用旧 API）**：`setEventHandler` + `resume()` 语义等价于 `activate()`；`resume()` 已不在当前文档正文中出现，建议迁到 `activate()` |
| G2 | `queue` 参数缺省意味着什么 | 签名：`queue: DispatchQueue? = nil`；参数说明：“The dispatch queue to use when executing the installed handlers.”（**官方未在正文说明 nil 时落到哪个队列**） | `AppContext.swift:76`（未传 `queue` → `nil`） | **未找到官方依据，标记存疑**：`nil` 时的实际执行队列官方未写明（实践上落到默认全局并发队列，**不是主队列**）。本项目 `eventHandler` 里调用 `self?.cacheManager.trimMemory(toFraction: 0.5)` 与 `DownloadCategoryView.clearStaticCaches()`，二者在默认隔离下均为 `@MainActor` 隔离 → 实测告警（§2.10）。**结论：应显式传 `queue: .main`**，见 §2.10 |
| G3 | 事件源必须 `resume/activate` 才会投递 | 见 G1 | `AppContext.swift:83`（`source.resume()`） | **写法正确** |
| G4 | 生命周期与取消 | 官方未给出 `deinit` 中取消的明文要求；`DispatchSourceProtocol.cancel()` 存在 | `AppContext.swift:87-89` | **写法正确**：`AppContext.shared` 是进程级单例，`deinit` 实际不会执行；`cancel()` 属防御性写法 |
| G5 | `DispatchSourceMemoryPressure` 的事件掩码 | `eventMask: DispatchSource.MemoryPressureEvent`，项目传 `[.warning, .critical]` | `AppContext.swift:76` | **写法正确** |

### 1.8 值语义 / 引用语义

官方来源：Swift 书《Structures and Classes》 <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/>

| # | 语法点 | 官方规则要点（原文关键句） | 项目对应位置 | 结论 |
|---|---|---|---|---|
| H1 | `struct` 是值类型 | “A *value type* is a type whose value is *copied* when it's assigned to a variable or constant, or when it's passed to a function.”；“All structures and enumerations are value types in Swift. This means that any structure and enumeration instances you create — and any value types they have as properties — are always copied when they're passed around in your code.” | `SLModule.swift:15-18`（`protocol SLModule { func register(in context: ModuleContext) throws }`） | — |
| H2 | `class` 是引用类型 | “Unlike value types, *reference types* are *not* copied when they're assigned to a variable or constant, or when they're passed to a function. Rather than a copy, a reference to the same existing instance is used.” | `SLModule.swift:33-48`（`final class ModuleContext`） | **写法正确**：`ModuleContext` 用 class 是**必需**的 |
| H3 | 「`ModuleContext` 必须用 class」的论证 | 由 H1+H2 直接推出：若 `ModuleContext` 是 struct，`register(in:)` 内部写入的是**副本**，能力注册对调用方不可见 | `SLModule.swift:29-33` 的注释正是此论证 | **论点成立，且已实跑验证**（§5.7）：struct 版上下文注册后 `resolve` 返回 `nil`；class 版返回 `Optional(42)` |
| H4 | 泛型能力键用 `struct: Hashable` | 官方未专门条款；`Hashable` 作为字典键的标准用法 | `SLModule.swift:21-27`（`struct ModuleCapabilityKey<Value>: Hashable`） | **写法正确** |
| H5 | 模块上下文的并发可达性 | 官方无条款要求 `ModuleContext` 必须 `Sendable`；`final class` 无隔离时在默认隔离设置下变 `@MainActor`（§5.1） | `SLModule.swift:33`、`ModuleRegistry.swift:7-25` | **有风险（中）**：`ModuleContext` / `ModuleRegistry` 内部无锁、无隔离声明；在默认 MainActor 隔离下它们**被**推断为 `@MainActor`，但一旦有人在 `nonisolated` 上下文（例如子模块在后台线程做注册）触碰，即告警→Swift 6 报错。若意图是「启动期单线程装配」，建议在类型上**显式**写 `@MainActor` 把意图固化；若意图是「并发可访问」，必须加锁并标 `@unchecked Sendable`。当前二者皆无，属意图未表达 |

---

## 2. 重点标红：写法有风险或错误（按严重度排序）

> 每条给出「改前 / 改后」。改后代码以**符合官方文档**为目标，**不修改任何 `qwq/` 源码**，仅作记录。

### 2.1 【严重】`GameProcessController.waitForTermination()` 存在续体永不 resume 的路径

- 位置：`qwq/Features/Launch/GameProcessController.swift:39-48`
- 官方依据：`CheckedContinuation` <https://developer.apple.com/documentation/swift/checkedcontinuation> —— “**You must call a resume method exactly once on every execution path throughout the program.** … Never resuming leaves the task in a suspended state indefinitely, and leaks any associated resources.”
- 官方依据：`Process.terminationHandler` <https://developer.apple.com/documentation/foundation/process/terminationhandler> —— 签名 `(@Sendable (Process) -> Void)?`；Discussion 只说明“A completion block the system invokes when the task completes”，**未承诺「进程已退出后再设置 handler 仍会被调用」**。
- 情况：先判断 `process.isRunning`，再在 `withCheckedContinuation` 内**设置** `terminationHandler`。若进程在这两步之间退出，handler 可能永不触发 → continuation 永不 resume → 该 `await` 永久挂起并泄漏。文件自己的注释只把它当成「窄窗口竞态」并推给调用方，但官方对续体的要求是**所有路径恰好 resume 一次**，不能用「窗口很窄」豁免。

改前：

```swift
public func waitForTermination() async -> Int32 {
    if !process.isRunning {
        return process.terminationStatus
    }
    return await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
        process.terminationHandler = { proc in
            continuation.resume(returning: proc.terminationStatus)
        }
    }
}
```

改后（先挂观察、再补检；用一次性门控保证恰好 resume 一次）：

```swift
public func waitForTermination() async -> Int32 {
    await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
        let gate = LaunchResumeGate()          // 复用项目既有的 NSLock 门控类型
        // 先挂 handler：此后任何退出都会被观察到
        process.terminationHandler = { proc in
            guard gate.claim() else { return }
            continuation.resume(returning: proc.terminationStatus)
        }
        // 再补检一次：覆盖「挂 handler 之前就已退出」的窗口
        if !process.isRunning, gate.claim() {
            continuation.resume(returning: process.terminationStatus)
        }
    }
}
```

> 说明：`LaunchResumeGate` 定义于 `MinecraftInstanceLaunchService.swift:252`；若跨文件使用需将其提升为 internal（这属于改动，须在合并阶段统一决策）。

### 2.2 【严重】`JavaResolverBridge.resolveSynchronously` —— 官方明文禁止的「同步等待异步」，且存在数据竞争

- 位置：`qwq/Features/Java/JavaResolverBridge.swift:19-50`
- 官方依据（三条同时命中）：
  1. Swift 书《Concurrency》 <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/> —— “**In contrast, there's no safe way to wrap asynchronous code so you can call it from synchronous code and wait for the result. The Swift standard library intentionally omits this unsafe functionality — trying to implement it yourself can lead to problems like subtle races, threading issues, and deadlocks.**”
  2. WWDC21 10254 <https://developer.apple.com/videos/play/wwdc2021/10254/> —— “**do not use primitives that create unstructured tasks and then retroactively introduce a dependency across task boundaries by using a semaphore or an unsafe primitive.** … This violates the runtime contract of forward progress for threads.”
  3. SE-0430 <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md> —— “When a call passes an argument to a `sending` parameter, **the caller cannot use the argument value again after the callee returns.**”
- 具体问题：
  1. **数据竞争**：`var resolved: URL?` 由 `Task.detached` 闭包（协作线程池线程）写、由调用方线程在 `semaphore.wait` 返回后读。二者之间只有信号量做「时序」同步，**没有任何 happens-before 语义**（信号量不构成 Swift 内存模型下的同步边缘）。写与读同时可达同一存储。
  2. **编译器盲区（实测）**：该形态在 `-swift-version 5`（minimal）、`-swift-version 5 -strict-concurrency=complete`、`-swift-version 6` 三档下**均不产生任何诊断**（§5.4）。原因是当前 SDK 中 `Task.detached(operation:)` 参数类型是 `sending @escaping @isolated(any) () async -> Success`，而非 `@Sendable`，故 `SendableClosureCaptures` 检查不适用。
  3. **隔离归属错位**：在工程的 `-default-isolation MainActor` 设置下，`resolveSynchronously` **被推断为 `@MainActor`**（§5.1 实测：非隔离上下文调用它会产生 `[#ActorIsolatedCall]`）。而它内部执行 `semaphore.wait(timeout:)` —— 一个「阻塞至多 8 秒」的调用。当前之所以没卡住主线程，是因为调用它的 `slLaunchInternal` 实际被 `DispatchQueue.global` 丢到了后台线程（隔离声明与运行线程不一致）；一旦有**真正合规的 MainActor 调用方**（如 SwiftUI 按钮回调）调用它，将直接阻塞主线程 8 秒。
  4. 超时路径还会**遗留游离任务**：超时返回 `nil` 后，`Task.detached` 里的 resolve 仍在跑，最终仍会写 `resolved`（此时已无人读取），但 detached 任务无引用、无法取消。

改前：

```swift
static func resolveSynchronously(minimumMajor: Int, mcVersion: String?, timeout: TimeInterval = 8) -> URL? {
    let requirement = JavaRequirement(minimumMajor: max(0, minimumMajor), mcVersion: mcVersion, remarks: "SLLaunchBridge 同步桥接")
    let resolver = DefaultJavaResolver()
    let semaphore = DispatchSemaphore(value: 0)
    var resolved: URL?

    Task.detached(priority: .userInitiated) {
        defer { semaphore.signal() }
        do {
            let installation = try await resolver.resolve(requirement)
            resolved = installation.executableURL
        } catch {
            NSLog("[JavaResolverBridge] Java 解析未命中：\(error.localizedDescription)")
        }
    }

    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        NSLog("[JavaResolverBridge] Java 解析超时（\(Int(timeout))s），回退既有链路")
        return nil
    }
    return resolved
}
```

改后（官方推荐路径：把 async 能力向上暴露，由 async 调用方 `await`；同步调用方通过 `Task` + 一次性续体桥接，全部状态经 at-least-once 安全的通道传递）：

```swift
// 步骤 1：提供原生 async 版本，不再自造同步等待
enum JavaResolverBridge {
    static func resolve(minimumMajor: Int, mcVersion: String?) async -> URL? {
        let requirement = JavaRequirement(
            minimumMajor: max(0, minimumMajor),
            mcVersion: mcVersion,
            remarks: "JavaResolverBridge"
        )
        do {
            return try await DefaultJavaResolver().resolve(requirement).executableURL
        } catch {
            NSLog("[JavaResolverBridge] Java 解析未命中：\(error.localizedDescription)")
            return nil
        }
    }
}
```

```swift
// 步骤 2：调用方（slLaunchInternal）改为 async，并在需要超时的地方用结构化并发
//         注意：不要再把结果写进外层 var，改为把结果作为子任务返回值
private func resolveWithTimeout(minimumMajor: Int, mcVersion: String?, timeout: TimeInterval) async -> URL? {
    await withTaskGroup(of: URL?.self) { group in
        group.addTask { await JavaResolverBridge.resolve(minimumMajor: minimumMajor, mcVersion: mcVersion) }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()          // 取消未完成的子任务，避免遗留游离任务
        return first
    }
}
```

> 说明：若「启动链路整体改 async」的代价在工程上不可接受（文件头已声明风险过高），**至少**要把 `resolved` 的跨线程传递改成有 happens-before 保证的形式（例如用 `OSAllocatedUnfairLock<URL?>` 承载结果、且调用方 `withLock` 读取），并给 `resolveSynchronously` 显式标 `nonisolated` 以免被推断成 `@MainActor`。
>
> 「查不到」标注：`DispatchSemaphore` 是否在 Swift 内存模型下提供 happens-before 保证，**官方文档未作说明**，标记存疑；因此不能以「用了信号量」为由宣称此处无数据竞争。

### 2.3 【严重】`LocalModCatalog`：async 上下文内直接调用 `NSLock.lock()/unlock()`

- 位置：`qwq/Features/ModBrowser/LocalModCatalog.swift:97-99`（`preload()` 的 `Task.detached` 闭包内）
- 官方依据：Swift 书《Attributes》`noasync` <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/> —— “This attribute raises a compile-time error when someone uses the symbol in an asynchronous context.”
- 实测诊断（工程设置下）：

```
qwq/Features/ModBrowser/LocalModCatalog.swift:97:30: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
qwq/Features/ModBrowser/LocalModCatalog.swift:99:30: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
```

- 重要：同一文件 `:74-80`、`:88-90` 处的 `localCatalogLock.lock()/unlock()` 位于**同步函数**内，不违反 `noasync`；**只有 `:97-99` 那三行在 async 闭包内**。项目已备有 `LockCompat.swift:21-30` 的 `NSLock.withLockCompat`，此处未使用。

改前（`LocalModCatalog.swift:92-103` 节选）：

```swift
Task.detached(priority: .userInitiated) {
    _ = items(for: .mod)
    _ = items(for: .resourcePack)
    _ = items(for: .shader)
    _ = items(for: .modpack)
    localCatalogLock.lock()
    localCatalogReady = true
    localCatalogLock.unlock()
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: readyNotification, object: nil)
    }
}
```

改后（用项目既有的作用域锁；同时修掉 §2.6 的隔离问题）：

```swift
Task.detached(priority: .userInitiated) {
    _ = await Self.items(for: .mod)          // items(for:) 是 MainActor 隔离，见 §2.6
    _ = await Self.items(for: .resourcePack)
    _ = await Self.items(for: .shader)
    _ = await Self.items(for: .modpack)
    localCatalogLock.withLockCompat { localCatalogReady = true }   // 同步作用域锁，不跨 await
    await MainActor.run {
        NotificationCenter.default.post(name: Self.readyNotification, object: nil)
    }
}
```

### 2.4 【严重】`SLLaunchBridge`：`Task.detached` 内访问 `@MainActor` 隔离属性（Swift 6 硬错误）

- 位置：`qwq/SLCore/SLLaunchBridge.swift:316`（`windowTask` 内 `launcher.currentProcess`）
- 定义处：`qwq/SLCore/Minecraft/Launch/MinecraftLauncher.swift:105` `public private(set) var currentProcess: Process?`
- 官方依据：SE-0316 <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0316-global-actors.md> —— “the declaration can only be synchronously accessed from another declaration on the same global actor, but can be asynchronously accessed from elsewhere.”
- 实测诊断：

```
Swift 5（工程设置）：warning: main actor-isolated property 'currentProcess' cannot be accessed from outside of the actor; this is an error in the Swift 6 language mode
Swift 6 语言模式      ：error:   main actor-isolated property 'currentProcess' cannot be accessed from outside of the actor
```

- 这是全项目在 Swift 6 语言模式下**第一个**（也是编译中止前唯一暴露出的）硬错误。
- 根因有二：① `MinecraftLauncher` 未显式标注隔离，在 `-default-isolation MainActor` 下整个类被推断为 `@MainActor`；② 访问发生在无隔离的 `Task.detached` 内。

改前（`SLLaunchBridge.swift:313-331` 节选）：

```swift
let windowTask = Task.detached(priority: .utility) {
    var fired = false
    while !Task.isCancelled, !fired {
        if let process = launcher.currentProcess, process.isRunning {   // ← 跨 actor 同步访问
            …
```

改后（在本文件内读取一次并捕获值；`Task.detached` 只认这个值快照）：

```swift
// currentProcess 只在「进程刚拉起」这一小段窗口内被赋值，先取快照再进后台任务
// 注意：取值本身必须在 MainActor 上，故用 Task { @MainActor in } 或让 slLaunchInternal 保持 MainActor 上下文
let processSnapshot = launcher.currentProcess
let windowTask = Task.detached(priority: .utility) {
    guard let process = processSnapshot else { return }
    var fired = false
    while !Task.isCancelled, !fired {
        if process.isRunning { … }
```

> 更彻底的做法（与 §2.2 同源）：把 window 轮询放进 `MinecraftLauncher` 自身（`@MainActor`），由它对外暴露 `async` 的「等待窗口出现」接口，`SLLaunchBridge` 只 `await` 结果，不再跨 actor 摸内部存储。

### 2.5 【严重】`slLaunchInternal` 被推断为 `@MainActor`，却被丢到 GCD 后台队列 —— 隔离声明与运行线程不一致

- 位置：调用方 `qwq/SLCore/SLLaunchBridge.swift:66-78`（`DispatchQueue.global(qos: .userInitiated).async { slLaunchInternal(…) }`）；被调用方 `qwq/SLCore/SLLaunchBridge.swift:81-91`（`private func slLaunchInternal(…)`）
- 官方依据：同 §2.4（SE-0316）；`-default-isolation MainActor` 使未标注的自由函数也变 `@MainActor`。
- 实测（§5.1 复刻验证）：非隔离闭包内调用默认隔离的自由函数，在 **Swift 6 语言模式下报 `[#ActorIsolatedCall]` 告警**；在 **Swift 5 语言模式下不报**。因此工程当前**静默**地违反了自己的隔离声明。
- 影响面：整条 `slLaunchInternal` 链路上的「主 actor 隔离」都是**假的**（运行在 GCD 线程上）。这既掩盖了真实的主线程阻塞风险（如 §2.2 的 8s 等待），也让任何后续「合规地」从 MainActor 调用它的人踩雷。

改前：

```swift
public func slLaunch(...) {
    DispatchQueue.global(qos: .userInitiated).async {
        slLaunchInternal(version: version, …)      // slLaunchInternal 实为 @MainActor
    }
}

private func slLaunchInternal(version: String, …) {   // 默认隔离 → @MainActor（隐含）
    …
}
```

改后（二选一，取其一并把意图写在类型上；不要继续依赖推断）：

```swift
// 方案 A：明确认为它必须在主 actor 之外运行 → 显式 nonisolated，并保证内部不碰主 actor 状态
nonisolated private func slLaunchInternal(version: String, …) async { … }

// 方案 B：明确认为它属于主 actor → 显式 @MainActor，并改掉调用方的 GCD 跳转
@MainActor
private func slLaunchInternal(version: String, …) async { … }
// 调用方：
Task { await slLaunchInternal(version: version, …) }   // 继承 MainActor 隔离，无需 GCD 跳转
```

> 若选 A，`JavaResolverBridge` 也必须同步标 `nonisolated`（否则 §2.2 的隔离错位依旧）；若选 B，`JavaResolverBridge.resolveSynchronously` 的 8 秒阻塞会**真的落在主线程上**，必须先按 §2.2 改成 async。

### 2.6 【严重】`LocalModCatalog`：`Task.detached` 内调用 MainActor 隔离的静态成员

- 位置：`qwq/Features/ModBrowser/LocalModCatalog.swift:93-96`（`items(for:)` × 4）、`:97,99`（`localCatalogLock`）、`:113`（`TranslationService.shared`）、`:127`（`cachedTranslation(for:)`）、`:174`（`saveCatalogToDisk`）
- 官方依据：SE-0316（同 §2.4）；Swift 书《Concurrency》——“The new task defaults to running **without any actor isolation**”（`Task.detached`）。
- 实测诊断（工程设置下，节选）：

```
LocalModCatalog.swift:93:17: warning: main actor-isolated static method 'items(for:)' cannot be called from outside of the actor; this is an error in the Swift 6 language mode
LocalModCatalog.swift:94:17: warning: …（同上，×4）
LocalModCatalog.swift:97:13: warning: main actor-isolated static property 'localCatalogLock' cannot be accessed from outside of the actor; …
LocalModCatalog.swift:99:13: warning: …（同上）
LocalModCatalog.swift:113:46: warning: main actor-isolated static property 'shared' cannot be accessed from outside of the actor; …
LocalModCatalog.swift:127:55: warning: main actor-isolated instance method 'cachedTranslation(for:)' cannot be called from outside of the actor; …
LocalModCatalog.swift:174:45: warning: main actor-isolated static method 'saveCatalogToDisk' cannot be called from outside of the actor; …
```

- 注意 `LocalModCatalog` 并未标注 `@MainActor` —— 这些隔离**全部来自默认隔离设置**。

改前（`:107-128` 节选）：

```swift
static func preTranslateAll() {
    Task.detached(priority: .background) {
        …
        let service = TranslationService.shared
        for (type, _) in categories {
            …
            guard let (data, _) = try? await AppContext.shared.apiSession.data(for: req), … else { continue }
            for hit in hits.prefix(3) {
                let projectId = hit["project_id"] as? String ?? hit["slug"] as? String ?? ""
                guard !projectId.isEmpty, service.cachedTranslation(for: projectId) == nil else { continue }   // ← MainActor 隔离
                _ = try? await service.translateText(text: "", projectId: projectId)
            }
        }
    }
}
```

改后（原则：**在 MainActor 上取快照，把纯数据交给后台；后台不回摸隔离状态**）：

```swift
static func preTranslateAll() async {
    // 隔离成员只在 MainActor 上取引用（一次），随后按 Sendable 值传出去
    let service = TranslationService.shared
    let session = AppContext.shared.apiSession

    await Task.detached(priority: .background) {
        for (type, _) in categories {
            if Task.isCancelled { return }
            …
            guard let (data, _) = try? await session.data(for: req), … else { continue }
            for hit in hits.prefix(3) {
                let projectId = hit["project_id"] as? String ?? hit["slug"] as? String ?? ""
                guard !projectId.isEmpty else { continue }
                // 若 cachedTranslation 需要碰隔离状态，则改为在 MainActor 上判断后把「待翻译 id 数组」传回后台
                _ = try? await service.translateText(text: "", projectId: projectId)
            }
        }
    }.value
}
```

> 若 `TranslationService.cachedTranslation` 本质是纯内存查询，**首选**是给它加 `nonisolated`（官方 SE-0316 明确支持用 `nonisolated` 让成员退出全局 actor 隔离），而不是把逻辑搬到主线程。

### 2.7 【中】`NetDownloader.shared` / `LoaderSupportChecker`：MainActor 隔离静态成员被非隔离上下文访问

- 位置：`qwq/SLCore/Download/NetDownloader.swift:245,563,605,608`；`qwq/SLCore/Minecraft/Mod/Loader/LoaderSupportChecker.swift:271`
- 官方依据：SE-0316 —— “Global and static variables can be annotated with a global actor. Such variables can only be accessed from the same global actor or asynchronously.”
- 实测诊断：

```
NetDownloader.swift:245:33: warning: main actor-isolated static property 'shared' can not be referenced from a nonisolated context
NetDownloader.swift:563:53: warning: main actor-isolated static property 'shared' cannot be accessed from outside of the actor; this is an error in the Swift 6 language mode
NetDownloader.swift:605:33: warning: …（同上）
NetDownloader.swift:608:39: warning: …（同上）
LoaderSupportChecker.swift:271:17: warning: call to main actor-isolated static method 'unsubscribeInflight(version:ownerID:subscriberID:)' in a synchronous nonisolated context [#ActorIsolatedCall]
```

- 特别提示：`NetDownloaderDownloadEngine.swift:177` 在 `Task.detached` 内调用 `NetManager.shared.download(file)`，而 `NetManager.shared` 在默认隔离下是 `@MainActor` —— 这是 §2.2 之外第二处「后台任务摸主 actor 单例」的形态。

改前 / 改后（范式固定，逐处套用）：

```swift
// 改前
Task.detached(priority: .utility) {
    try await NetManager.shared.download(file) { … }      // shared 是 @MainActor
}

// 改后 A（推荐）：声明该单例不属于主 actor —— 它本就不该依赖主线程
// NetDownloader.swift
nonisolated public static let shared = NetManager()       // 若其内部可变状态另有锁保护（该文件确有锁）

// 改后 B：若单例确需主 actor 隔离，则在 MainActor 上取引用后按值/sending 传入后台
let manager = await NetManager.shared
try await Task.detached { try await manager.download(file) { … } }.value
```

### 2.8 【中】`AppContext`：`Task.detached` 内调用 MainActor 隔离方法 + 内存压力事件处理器未指定队列

- 位置：`qwq/App/AppContext.swift:71-73`（`Task.detached { cacheManager.cleanDiskCache(olderThan: 30) }`）、`:76-82`（`makeMemoryPressureSource` 未传 `queue`）
- 官方依据：SE-0316（同 §2.7）；`makeMemoryPressureSource` 签名 `queue: DispatchQueue? = nil`，参数说明仅“The dispatch queue to use when executing the installed handlers”，**未说明 `nil` 落到哪个队列**。
- 实测诊断：

```
qwq/App/AppContext.swift:72:26: warning: main actor-isolated instance method 'cleanDiskCache(olderThan:)' cannot be called from outside of the actor; this is an error in the Swift 6 language mode
```

改前：

```swift
Task.detached(priority: .utility) { [cacheManager] in
    cacheManager.cleanDiskCache(olderThan: 30)
}

let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
source.setEventHandler { [weak self] in
    self?.cacheManager.trimMemory(toFraction: 0.5)
    DownloadCategoryView.clearStaticCaches()
}
source.resume()
```

改后：

```swift
// ① 磁盘清理是纯 IO，明确标 nonisolated；不要靠 detached 绕过隔离检查
//    在 CacheManager 上：nonisolated func cleanDiskCache(olderThan days: Int = 7) { … }
Task.detached(priority: .utility) { [cacheManager] in
    await MainActor.run { cacheManager.cleanDiskCache(olderThan: 30) }   // 或把 cleanDiskCache 标 nonisolated
}

// ② 内存压力事件处理器显式落到主队列：处理函数是 MainActor 隔离状态，且不涉及重 IO
let source = DispatchSource.makeMemoryPressureSource(
    eventMask: [.warning, .critical],
    queue: .main
)
source.setEventHandler { [weak self] in
    self?.cacheManager.trimMemory(toFraction: 0.5)
    DownloadCategoryView.clearStaticCaches()
}
source.activate()          // 官方文档：返回的 source 初始为 inactive，需 activate()
```

> 存疑标注：`makeMemoryPressureSource(queue: nil)` 的默认队列**官方文档未载明**，标记存疑。在存疑前提下，显式传 `queue: .main` 是唯一可论证正确的选择。

### 2.9 【中】`GameSessionStore`：`Sendable` 闭包内引用 MainActor 隔离的计算属性

- 位置：`qwq/Features/Launch/GameSessionStore.swift:60`（`if launchState.isTerminal { … }` 位于 `lock.withLock { … }` 闭包内）
- 定义处：`qwq/Features/Launch/LaunchState.swift:42-47`
- 官方依据：SE-0316（同 §2.7）。实测（§5.2）：`Sendable` 枚举的计算属性在 `-default-isolation MainActor` 下**被推断为 `@MainActor`**，从非隔离上下文读取即告警/报错。
- 实测诊断：

```
qwq/Features/Launch/GameSessionStore.swift:60:28: warning: main actor-isolated property 'isTerminal' can not be referenced from a Sendable closure
```

改前 / 改后：

```swift
// 改前（LaunchState.swift）：纯数据计算属性，却被推成 MainActor 隔离
public enum LaunchState: Sendable, Equatable {
    public var isTerminal: Bool { … }
}

// 改后：显式 nonisolated —— 它与任何 actor 状态无关
public enum LaunchState: Sendable, Equatable {
    public nonisolated var isTerminal: Bool { … }
}
```

> 同一形态还有 `DownloadState.isTerminal` / `.progress` / `.error`（`qwq/Core/Download/DownloadState.swift:28-47`）。这三个属性被 `NetDownloaderDownloadEngine` 的非隔离路径使用，建议一并加 `nonisolated`。

### 2.10 【中】`MinecraftRepository` / `VersionUtils` / `CardTranslationModel` / `ModFileDownloadStarter` / `CategoryContentView`：函数值转换丢失 MainActor

- 位置与实测诊断：

```
qwq/Core/Minecraft/Module/MinecraftRepository.swift:61:27: warning: converting function value of type '@MainActor (URL) -> [MinecraftInstanceInfo]' to '(URL) throws -> [MinecraftInstanceInfo]' loses global actor 'MainActor'; this is an error in the Swift 6 language mode
qwq/Features/Game/VersionUtils.swift:185:20: warning: main actor-isolated static method 'findGameRootDirectories()' cannot be called from outside of the actor; …
qwq/Features/Game/VersionUtils.swift:191:20: warning: main actor-isolated static method 'findFirstValidGame()' cannot be called from outside of the actor; …
qwq/Features/Translation/CardTranslationModel.swift:52:33: warning: main actor-isolated instance method 'prefetchTranslations(ids:)' cannot be called from outside of the actor; …
qwq/Features/Translation/CardTranslationModel.swift:83:90: warning: main actor-isolated instance method 'cachedTranslation(for:)' cannot be called from outside of the actor; …
qwq/Features/Download/ModFileDownloadStarter.swift:35:28,45:22,79:22: warning: main actor-isolated … cannot be called from outside of the actor; …
qwq/Features/ModBrowser/CategoryContentView.swift:169:38,170:37: warning: main actor-isolated static method 'cropped(imageData:startX:startY:)' cannot be called from outside of the actor; …
```

- 官方依据：SE-0316（“it is permissible for the global actor qualifier to be removed when the result of the conversion is an `async` function”；反之，同步函数值转换会丢失隔离并报错）。
- 特别说明 `MinecraftRepository.swift:61`：该文件注释自称“跨线程只传递 Sendable 的 `MinecraftInstanceInfo`”，但**函数值本身**携带了 `@MainActor` 限定，转换到非限定函数类型即丢失隔离。这是「值 Sendable ≠ 函数 Sendable」的典型误判。

改后（统一范式）：

```swift
// ① 纯函数/纯数据方法：显式 nonisolated
nonisolated static func cropped(imageData: Data, startX: Int, startY: Int) -> … { … }
nonisolated static func findGameRootDirectories() -> [URL] { … }

// ② 确实需要隔离的函数值：保持 @MainActor 限定，不要转成非限定类型
let loader: @MainActor (URL) -> [MinecraftInstanceInfo] = repository.instances(at:)

// ③ 需要跨隔离使用：用 async 转换（官方允许），调用点 await
let instances = await repository.instances(at: url)
```

### 2.11 【中】`slLaunch`：`DispatchQueue.global().async` 捕获 6 个非 Sendable 闭包参数

- 位置：`qwq/SLCore/SLLaunchBridge.swift:66-78`
- 官方依据：SE-0302 <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md> —— “A `@Sendable` function type is safe to transfer across concurrency domains… the compiler checks several things about values (e.g. closures and functions) that have `@Sendable` function type: A function can be marked `@Sendable`. **Any captures must also conform to `Sendable`.**”
- 实测诊断（Swift 5 + 默认隔离下 6 条，节选）：

```
qwq/SLCore/SLLaunchBridge.swift:71:30: warning: capture of 'progressHandler' with non-Sendable type '(Double) -> Void' in a '@Sendable' closure [#SendableClosureCaptures]
qwq/SLCore/SLLaunchBridge.swift:72:27: warning: capture of 'phaseHandler' with non-Sendable type '(String) -> Void' in a '@Sendable' closure [#SendableClosureCaptures]
… （logHandler / launchSuccess / onLauncherReady / completion 各一条）
qwq/SLCore/SLLaunchBridge.swift:341:36: warning: capture of 'reportLaunchSuccess' with non-Sendable type '() -> ()' in a '@Sendable' closure [#SendableClosureCaptures]
qwq/SLCore/SLLaunchBridge.swift:342:17: warning: capture of 'completion' with non-Sendable type '(MinecraftLauncher?, Result<Int32, any Error>) -> Void' in a '@Sendable' closure [#SendableClosureCaptures]
```

改前：

```swift
public func slLaunch(
    version: String, username: String, gameDir: String?,
    progressHandler: @escaping (Double) -> Void,
    phaseHandler: @escaping (String) -> Void,
    logHandler: @escaping (String) -> Void,
    launchSuccess: @escaping () -> Void,
    onLauncherReady: @escaping (MinecraftLauncher) -> Void,
    completion: @escaping (MinecraftLauncher?, Result<Int32, Error>) -> Void
) {
    DispatchQueue.global(qos: .userInitiated).async { … }
}
```

改后（把回调类型显式标 `@Sendable`，并保证回调不捕获非 Sendable 状态；`MinecraftLauncher` 参数需改为 Sendable 载体或改为在 MainActor 上回调）：

```swift
public func slLaunch(
    version: String, username: String, gameDir: String?,
    progressHandler: @escaping @Sendable (Double) -> Void,
    phaseHandler: @escaping @Sendable (String) -> Void,
    logHandler: @escaping @Sendable (String) -> Void,
    launchSuccess: @escaping @Sendable () -> Void,
    onLauncherReady: @escaping @MainActor @Sendable (MinecraftLauncher) -> Void,
    completion: @escaping @MainActor @Sendable (MinecraftLauncher?, Result<Int32, Error>) -> Void
) { … }
```

> 项目内已有正确范式可参照：`MinecraftLauncher.swift:117` 的 `callback: @MainActor @escaping (MinecraftLaunchOutcome) -> Void`、`MinecraftInstanceLaunchService.swift:71` 的 `typealias LogSink = @Sendable (UUID, String) -> Void`、`LaunchState.swift:14` 的 `LaunchProgressHandler = @Sendable (Double) -> Void`。

### 2.12 【低】`ProcessPool.execute` 的信号量 + `Thread.sleep` 组合

- 位置：`qwq/Features/Launch/ProcessPool.swift:52,72-82,110-131`
- 官方依据：WWDC21 10254（同 §2.2 第 2 条）。
- 情况：`semaphore.wait()`（并发额度）与 `sem.wait(timeout:)`（进程退出）都是阻塞式；超时路径还有 `Thread.sleep(forTimeInterval: 0.5)`。当前所有调用点都在同步/GCD 上下文（`ProcessPoolGameProcessController.swift:123-131` 特意用 `DispatchQueue.global().async` 包住，注释亦说明「避免占用 Swift 并发协作线程」），**当前安全**。
- 结论：**有风险（低）**，属「正确使用但极易被后续误用」的形态。`ProcessPoolGameProcessController.swift:121-132` 的包装方式已给出正确范式，建议在 `ProcessPool` 的公开方法上标 `@available(*, noasync)`，让编译器替未来的人挡住误用（官方 Attributes 文档明确该属性可用于此目的）。
- 未找到官方依据，标记存疑：`Process.terminationStatus` 与 `terminationHandler` 之间是否存在内存可见性保证，官方文档未载明。

---

## 3. 一页速查：最容易被写错的 10 条规则

| # | 规则 | 一句话依据 |
|---|---|---|
| 1 | **async 上下文里不要直接调用 `DispatchSemaphore.wait()` / `NSLock.lock()`** ；要加锁就用作用域形态（`withLock { }`），要等待就用 `await` 或 `AsyncStream` | 官方 `noasync`：*“This attribute raises a compile-time error when someone uses the symbol in an asynchronous context.”* <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/> |
| 2 | **不要用信号量把「非结构化任务」接到同步代码上**（`Task.detached` + `semaphore.wait` 是官方点名的反模式） | WWDC21 10254：*“do not use primitives that create unstructured tasks and then retroactively introduce a dependency across task boundaries by using a semaphore or an unsafe primitive.”* <https://developer.apple.com/videos/play/wwdc2021/10254/> |
| 3 | **不要用外层 `var` 承接任务内写的结果**；让任务**返回**值，用 `await task.value` / `group.next()` 取。编译器**不会**替你发现 `Task`/`Task.detached` 闭包里的可变捕获 | 实测（§5.4）：`Task.detached { resolved = … }` 在 minimal / complete / Swift 6 三档下**零诊断**。原理见 SE-0430：*“the caller cannot use the argument value again after the callee returns.”* |
| 4 | **续体必须恰好 resume 一次**；凡是「先判断状态、后挂回调」的写法都可能永不 resume | `CheckedContinuation`：*“You must call a resume method exactly once on every execution path… **Never resuming leaves the task in a suspended state indefinitely, and leaks any associated resources.**”* <https://developer.apple.com/documentation/swift/checkedcontinuation> |
| 5 | **`Task.detached` 无任何 actor 隔离**；`Task {}` 才继承当前隔离 | Swift 书：*“The new task defaults to running **without any actor isolation**…”*；*“The new task defaults to running with the same actor isolation, priority, and task-local state as the current task.”* <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/> |
| 6 | **actor 内不要跨 `await` 依赖「挂起前的状态」**；同步段才是临界区 | SE-0306：*“it means that actor-isolated state can change across an `await`…”*；*“synchronous code in an actor provides a critical section, whereas an `await` interrupts a critical section.”* <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md> |
| 7 | **锁不要跨 `await` 持有**；`OSAllocatedUnfairLock` 的 `lock()/unlock()` 必须同线程配对 | `OSAllocatedUnfairLock`：*“it's unsafe to use this approach across an `await` suspension point. When using a lock with asynchronous code, lock using a closure or, even better, consider using an `Actor`.”* <https://developer.apple.com/documentation/os/osallocatedunfairlock> |
| 8 | **`@unchecked Sendable` = 你自己承担正确性**；要么加锁，要么保证状态不可变 | `Sendable`：*“**You are responsible for the correctness** of unchecked sendable types, for example, by protecting all access to its state with a lock or a queue.”* <https://developer.apple.com/documentation/swift/sendable> |
| 9 | **`AsyncStream` 的缓冲不是背压**；有界策略会**丢弃**元素（`bufferingNewest` 丢最旧、`bufferingOldest` 丢最新），终态事件必须单独保证送达 | `BufferingPolicy`：*“When the buffer is full, discard the newest received element.” / “When the buffer is full, discard the oldest element in the buffer.”* <https://developer.apple.com/documentation/swift/asyncstream/continuation/bufferingpolicy> |
| 10 | **`struct` 按值拷贝、`class` 共享实例**；凡「注册/写入必须被调用方看见」的上下文/累加器，必须是 `class`（或用 `inout`） | Swift 书：*“A value type is a type whose value is **copied** when it's assigned to a variable or constant, or when it's passed to a function.”*；*“reference types are **not** copied… Rather than a copy, a reference to the same existing instance is used.”* <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/> |

**本项目专属提醒（第 11 条，但必须记住）**：工程开启了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，**任何未标注隔离的声明（含自由函数、`enum` 的 `static func`、`Sendable` 枚举的计算属性、`final class`）都会变成 `@MainActor` 隔离**。写新代码时，如果它与 UI 无关，请**显式**写 `nonisolated`；不要依赖推断——推断不会在 Swift 5 模式下报错，但会在 Swift 6 模式下成片变红（实测：开关该设置使告警从 20 条升到 86 条）。

---

## 4. 未找到官方依据 / 存疑项汇总

| 项 | 位置 | 说明 |
|---|---|---|
| `DispatchSemaphore` 是否提供 happens-before 保证 | `JavaResolverBridge.swift:31-49` | 官方 `DispatchSemaphore` 文档只描述计数信号量的增减语义，**未载明内存可见性/同步边缘**。因此不能以「用了信号量」论证此处无数据竞争 |
| `makeMemoryPressureSource(queue: nil)` 的默认执行队列 | `AppContext.swift:76` | 官方文档未说明 `queue` 为 `nil` 时的落点。凭文档无法论证「事件处理器在哪个队列上跑」 |
| `AsyncStream` 是否支持多订阅者 / 终态回放 | `NetDownloaderDownloadEngine.swift:22-51,101-122` | 官方文档将 `AsyncStream` 描述为单一迭代点模型，**未定义**多 continuation 广播与终结后回放的语义。属项目自建语义 |
| `TerminationHandler` 在进程已退出后再设置是否仍会回调 | `GameProcessController.swift:44` | 官方只说明「系统在任务完成时调用该 block」，未承诺「后置设置仍然生效」。因此 §2.1 的竞态无法用文档排除 |
| `nonisolated(unsafe)` 用于 `deinit` 中的状态访问 | `SpeedMeter.swift:54-56` | SE-0412 说明了属性语义，但未针对 `deinit`（非隔离）访问 `nonisolated(unsafe)` 存储给出专门规则 |
| `Process.terminationStatus` 与 `terminationHandler` 之间的可见性 | `MinecraftLauncher.swift:162-165`、`ProcessPool.swift:73` | 官方未载明 |

---

## 5. 本地实测证据（可复现）

所有实验均在 `/tmp` 下进行，**未写入项目目录**。命令统一为：

```bash
swiftc -typecheck <模式> -target arm64-apple-macos13.0 <file.swift>
```

### 5.1 默认 MainActor 隔离的推断范围

```swift
final class PlainClass { var x = 0 }
enum PlainEnum { static func plainFunc() -> Int { 1 } }
nonisolated func probe() { _ = PlainEnum.plainFunc(); _ = PlainClass() }
```

```
$ swiftc -typecheck -swift-version 5 -default-isolation MainActor …
warning: call to main actor-isolated static method 'plainFunc()' in a synchronous nonisolated context [#ActorIsolatedCall]
warning: call to main actor-isolated initializer 'init()' in a synchronous nonisolated context [#ActorIsolatedCall]
```

结论：`final class` 与 `enum` 的静态方法**都被**推断为 `@MainActor`。对照组（去掉 `-default-isolation MainActor`）无任何诊断。

### 5.2 `Sendable` 枚举的计算属性也被推断为 `@MainActor`

```swift
enum S: Sendable, Equatable {
    case a, b
    var isTerminal: Bool { switch self { case .a: return true; case .b: return false } }
}
nonisolated func readIt(_ s: S) -> Bool { s.isTerminal }
```

```
$ … -swift-version 5 -default-isolation MainActor   → warning: main actor-isolated property 'isTerminal' can not be referenced from a nonisolated context
$ … -swift-version 6 -default-isolation MainActor   → error:   （同上）
$ … -swift-version 6（不加默认隔离）                 → 无诊断
```

### 5.3 三类闭包的捕获检查差异

| 形态 | Swift 5 | Swift 5 + complete | Swift 6 |
|---|---|---|---|
| `let g: @Sendable () -> Void = { x = 1 }` | — | — | **error**: mutation of captured var 'x' in concurrently-executing code |
| `DispatchQueue.global().async { x = 1 }` | — | warning（同文案） | warning（同文案） |
| `DispatchQueue.global().async { o.v = 1 }`（`o` 非 Sendable） | — | — | warning: capture of 'o' with non-Sendable type 'NonSendable' in a '@Sendable' closure |
| **`Task.detached { x = 1 }`** | **无** | **无** | **无** |
| **`Task { x = 1 }`（在 sync 或 async 函数内）** | **无** | **无** | **无** |

（对照组：同文件内写入 `let _: Int = "x"` 会正常报错，确认编译器确实处理了该文件。）

### 5.4 `JavaResolverBridge` 形态的零诊断验证

```swift
func c() -> URL? {
    var resolved: URL?
    let sem = DispatchSemaphore(value: 0)
    Task.detached { defer { sem.signal() }; resolved = URL(fileURLWithPath: "/x") }
    _ = sem.wait(timeout: .now() + 1)
    return resolved
}
```

```
-swift-version 5                          → 诊断数 0
-swift-version 5 -strict-concurrency=complete → 诊断数 0
-swift-version 6                          → 诊断数 0
```

SDK 中 `Task.detached` 的实际签名（`_Concurrency.swiftmodule/arm64e-apple-macos.swiftinterface:4014`）：

```
@_alwaysEmitIntoClient public static func detached(name: String? = nil, priority: TaskPriority? = nil,
    operation: sending @escaping @isolated(any) () async -> Success) -> Task<Success, Never>
```

注意是 `sending`，**不是** `@Sendable`。这正是 `SendableClosureCaptures` 检查不生效的原因。

### 5.5 `noasync` 实测（工程同类写法）

```swift
func a1(_ s: DispatchSemaphore, _ l: NSLock) async { s.wait(); l.lock(); l.unlock() }
```

```
$ swiftc -typecheck -swift-version 5 …
warning: instance method 'wait' is unavailable from asynchronous contexts; Await a Task handle instead; this is an error in the Swift 6 language mode
warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode

$ swiftc -typecheck -swift-version 6 …
error:   （上述三条全部升级为 error）
```

补充：在 SDK 中检索 `noasync` 字面量，**仅** `Foundation.NSFastEnumerationIterator` 及其成员存在该标注；`NSLock` / `os_unfair_lock` / `DispatchSemaphore` 的标注以其它形式（ObjC `swift_attr` / 模块接口）携带，因此「grep 源码找不到」不代表没有 `noasync` 语义——以编译器实测为准。

### 5.6 `NSLock.withLock` 的可用版本（用于核对 `LockCompat.swift` 的注释）

```swift
func b1(_ l: NSLock) { l.withLock { _ = 1 } }
func b2() { _ = OSAllocatedUnfairLock(initialState: 0) }
```

| 部署目标 | `NSLock.withLock` | `OSAllocatedUnfairLock` |
|---|---|---|
| `macos10.13` | OK | **error: 'OSAllocatedUnfairLock' is only available in macOS 13.0 or newer** |
| `macos11.0` | OK | error（同上） |
| `macos12.0` | OK | error（同上） |
| `macos13.0` | OK | OK |

SDK 中的声明（`Foundation.swiftinterface:22449-22457`）：

```swift
@available(macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, *)
extension Foundation.NSLocking {
  @_alwaysEmitIntoClient @_disfavoredOverload public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        self.lock(); defer { self.unlock() }; return try body()
    }
}
```

结论：`LockCompat.swift:6-10` 的注释中「`NSLock.withLock` 需要 macOS 13」不成立；`OSAllocatedUnfairLock` 需要 macOS 13 成立。项目部署目标是 13.0，故 `withLockCompat` 是**冗余但无害**的兼容层（去掉它改用 `withLock` 可直接编译）。

### 5.7 `ModuleContext` 值语义 vs 引用语义（实跑）

```swift
struct StructContext { private var values: [String: Any] = [:]
    mutating func register<V>(_ v: V, for key: String) { values[key] = v }
    func resolve<V>(_ key: String) -> V? { values[key] as? V } }
final class ClassContext { private var values: [String: Any] = [:]
    func register<V>(_ v: V, for key: String) { values[key] = v }
    func resolve<V>(_ key: String) -> V? { values[key] as? V } }

func registerIntoStruct(_ c: StructContext) { var copy = c; copy.register(42, for: "n") }
func registerIntoClass(_ c: ClassContext) { c.register(42, for: "n") }
```

运行输出：

```
struct 版 resolve = nil
class  版 resolve = Optional(42)
```

结论：`SLModule.swift:29-33` 的注释「**必须是引用类型（class）**」**论证成立且可复现**。

---

## 6. 官方文档索引

### Swift 语言与并发
- Swift 书《Concurrency》 — <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/>
- Swift 书《Attributes》（`noasync` / `available`） — <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/>
- Swift 书《Structures and Classes》（值语义/引用语义） — <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/>
- SE-0302 ConcurrentValue / ConcurrentClosures — <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md>
- SE-0306 Actors（含 Actor reentrancy） — <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md>
- SE-0316 Global Actors — <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0316-global-actors.md>
- SE-0412 Strict concurrency for global variables（`nonisolated(unsafe)`） — <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md>
- SE-0430 Transferring parameters and results（`sending`） — <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md>
- 诊断说明：`[#ActorIsolatedCall]` — <https://docs.swift.org/compiler/documentation/diagnostics/actor-isolated-call>
- 诊断说明：`[#SendableClosureCaptures]` — <https://docs.swift.org/compiler/documentation/diagnostics/sendable-closure-captures>

### 类型与协议
- `Sendable` — <https://developer.apple.com/documentation/swift/sendable>
- `Actor` — <https://developer.apple.com/documentation/swift/actor>
- `MainActor` — <https://developer.apple.com/documentation/swift/mainactor>
- `MainActor.run(resultType:body:)` — <https://developer.apple.com/documentation/swift/mainactor/run(resulttype:body:)>

### 任务与续体
- `Task`（含取消、`Task.detached`） — <https://developer.apple.com/documentation/swift/task>
- `TaskGroup` — <https://developer.apple.com/documentation/swift/taskgroup>
- `withTaskGroup(of:returning:isolation:body:)` — <https://developer.apple.com/documentation/swift/withtaskgroup(of:returning:isolation:body:)>
- `CheckedContinuation` — <https://developer.apple.com/documentation/swift/checkedcontinuation>
- `withCheckedThrowingContinuation` — <https://developer.apple.com/documentation/swift/withcheckedthrowingcontinuation(function:_:)-13yf6>

### 异步序列
- `AsyncStream` — <https://developer.apple.com/documentation/swift/asyncstream>
- `AsyncStream.init(_:bufferingPolicy:_:)` — <https://developer.apple.com/documentation/swift/asyncstream/init(_:bufferingpolicy:_:)>
- `AsyncStream.Continuation` — <https://developer.apple.com/documentation/swift/asyncstream/continuation>
- `Continuation.BufferingPolicy` — <https://developer.apple.com/documentation/swift/asyncstream/continuation/bufferingpolicy>
- `Continuation.finish()` — <https://developer.apple.com/documentation/swift/asyncstream/continuation/finish()>
- `Continuation.onTermination` — <https://developer.apple.com/documentation/swift/asyncstream/continuation/ontermination>
- `AsyncSequence` — <https://developer.apple.com/documentation/swift/asyncsequence>

### 同步原语与系统集成
- `DispatchSemaphore` — <https://developer.apple.com/documentation/dispatch/dispatchsemaphore>
- `OSAllocatedUnfairLock` — <https://developer.apple.com/documentation/os/osallocatedunfairlock>
- `DispatchSource.makeMemoryPressureSource(eventMask:queue:)` — <https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource(eventmask:queue:)>
- `DispatchObject.activate()` — <https://developer.apple.com/documentation/dispatch/dispatchobject/activate()>
- `Process.terminationHandler` — <https://developer.apple.com/documentation/foundation/process/terminationhandler>
- WWDC21 Session 10254《Swift concurrency: Behind the scenes》 — <https://developer.apple.com/videos/play/wwdc2021/10254/>

---

## 7. 附：本次核对的项目文件清单

| 文件 | 涉及的语法点 |
|---|---|
| `qwq/Core/Module/SLModule.swift` | H1–H5（值语义/引用语义、泛型能力键） |
| `qwq/Core/Module/ModuleRegistry.swift` | H2、H5 |
| `qwq/Features/Java/JavaResolverBridge.swift` | A2、A4、A5、C6、F4（**重点**） |
| `qwq/Features/Java/JavaRepository.swift` | A4、B8（`Task.detached` 内调 MainActor `init`，且缺 `await`） |
| `qwq/Core/Download/Adapters/NetDownloaderDownloadEngine.swift` | C2、D1、D3、D4、D5、D7、F5、E1 |
| `qwq/Core/Download/DownloadState.swift` | B9、C1 |
| `qwq/Features/Launch/GameSessionStore.swift` | C2、D6、F8、F9、B9 |
| `qwq/Features/Launch/GameProcessController.swift` | E1、E3、（对 `Process.terminationHandler` 的定时假设） |
| `qwq/Features/Launch/ProcessPool.swift` | C5、F4、F5 |
| `qwq/Features/Launch/LaunchState.swift` | B9、C1 |
| `qwq/Features/Launch/LaunchCoordinator.swift` | A3（`DispatchQueue.main.async` 回主线程） |
| `qwq/Features/Launch/Adapters/MinecraftInstanceLaunchService.swift` | C2、E2、F8、`@unchecked Sendable` 的两种承载（`NSLock` / `OSAllocatedUnfairLock`） |
| `qwq/Features/Launch/Adapters/ProcessPoolGameProcessController.swift` | C2、E3、F8 |
| `qwq/Features/Launch/Adapters/LaunchFixPreflight.swift` | C2（结构体上的 `@unchecked Sendable`） |
| `qwq/Features/Skin/Module/SkinService.swift` 等 | C1（`Sendable` 协议）、`MainActor.run` |
| `qwq/Services/CacheManager.swift` | F5（锁内只做内存操作、磁盘 IO 在锁外） |
| `qwq/App/AppContext.swift` | A4、B8、G1–G5 |
| `qwq/App/ViewModels/NavigationState.swift` | B3、B4（`@MainActor` + 隐式 `Sendable`） |
| `qwq/UI/Notices/NoticeCenter.swift` | A3、B7、E4、E5 |
| `qwq/SLCore/SLLaunchBridge.swift` | A4、A6、C3、F4、**2.4 / 2.5 / 2.11**（Swift 6 首个硬错误所在） |
| `qwq/SLCore/Minecraft/Launch/MinecraftLauncher.swift` | F4、C2、`@MainActor` 回调 |
| `qwq/SLCore/Download/SpeedMeter.swift` | B1、B2、B6 |
| `qwq/SLCore/Download/NetDownloader.swift` | B7、B8 |
| `qwq/SLCore/Utils/LockCompat.swift` | F1、F2、F6、F7（注释与事实的差异） |
| `qwq/SLCore/Minecraft/Mod/Loader/LoaderSupportChecker.swift` | A8、B7、B8 |
| `qwq/Features/ModBrowser/LocalModCatalog.swift` | **2.3、2.6** |
| `qwq/Core/Minecraft/Module/MinecraftRepository.swift` | 2.10（函数值转换丢失 `@MainActor`） |

---

*本手册由静态阅读 + `swiftc -typecheck` 实测 + 官方文档逐条比对产出；未修改 `qwq/` 下任何源码。*

---

## 8. 本次修复记录与待办

> 本节由修复任务追加。改动范围仅限 `qwq/Features/Java/JavaResolverBridge.swift`、
> `qwq/Features/Launch/GameProcessController.swift` 与本文件；未触碰 `SLLaunchBridge.swift`。

### 8.1 已落地的修复

| 对应条目 | 文件 | 落地内容 |
|---|---|---|
| §2.2 | `Features/Java/JavaResolverBridge.swift` | ① 类型与方法显式 `nonisolated`，消除默认 MainActor 推断；② 跨线程结果由裸 `var` 改为 `OSAllocatedUnfairLock<URL?>`（沿用 `Features/Launch/Adapters/` 的原语），写入/读取均入锁，由锁建立 happens-before；③ 新增主线程判断，主线程调用直接返回 `nil`（放弃同步解析，不阻塞、不留游离任务）；④ 保持对外语义：失败 / 超时 / 主线程放弃一律返回 `nil`，调用方回退旧链路。即 §2.2 文末「若整体改 async 代价过高，至少……」的方案 |
| §2.1 | `Features/Launch/GameProcessController.swift` | 顺序倒置为「先挂 `terminationHandler` → 再补检 `isRunning`」，并引入一次性门控 `TerminationResumeGate`（本文件私有的 `NSLock` + 布尔标志，显式 `nonisolated`），保证任何路径**恰好 resume 一次** |

> 与 §2.1 建议稿的差异：`LaunchResumeGate` 定义在 `MinecraftInstanceLaunchService.swift:252` 且为 `private`，
> 跨文件复用需改动第三个文件、并将其提升为 `internal`。为把改动面收敛在授权范围内，
> 此处按同一范式在 `GameProcessController.swift` 内私有复刻一份，语义与实现一致。

### 8.2 `slLaunchInternal` 的线程归属（结论）

**结论：`slLaunchInternal` 不在主线程执行，本次修复后上述桥接不会失效。**

调用链依据（源码实读）：

1. `Features/ModBrowser/CategoryContentView.swift:395` —— SwiftUI 启动按钮回调
   `private func startLaunch()` → `LaunchCoordinator.start(...)`（MainActor 上下文）；
2. `Features/Launch/LaunchCoordinator.swift:47` → `slLaunch(...)`；
3. `qwq/SLCore/SLLaunchBridge.swift:53-79` —— `slLaunch` 本身**不阻塞、立即返回**，
   内部为 `DispatchQueue.global(qos: .userInitiated).async { slLaunchInternal(...) }`；
4. `slLaunch` 全项目仅两个调用方：`LaunchCoordinator.swift:47` 与
   `Features/Launch/Adapters/MinecraftInstanceLaunchService.swift:98`，二者都只能经由上述 GCD 跳转。

因此 `slLaunchInternal`（及其内部的 `JavaResolverBridge.resolveSynchronously`）恒运行在
GCD 全局并发队列的工作线程上：`Thread.isMainThread` 为假，桥接**继续走阻塞式同步解析路径**，
阻塞的是 GCD 线程而非主线程，UI 不受影响。

需要留意的反例（当前不存在，但迁到 Swift 6 / 改隔离后会出现）：§2.5 指出该函数被推断为
`@MainActor`。一旦有人按 `@MainActor` 语义「合规地」从主线程直接调用它，桥接就会命中主线程
分支并**始终返回 `nil`**——即桥接实际失效、Java 选择恒定回退到 DataManager / JavaManager 兜底链。
本次修复不改变这一点（`SLLaunchBridge.swift` 不在改动范围内），仅把它显式记录在下面的待办里。

### 8.3 告警基线核对（改动未新增诊断）

两处改动在**工程设置**（`-swift-version 5 -default-isolation MainActor`）下的诊断集合与改动前**逐条一致**
（各 112 条告警、0 错误，且改动文件本身 0 诊断）；在任务给定的验证设置（不附加默认隔离）下亦为
48 条告警、0 错误，与改动前一致。做法：`JavaResolverBridge` 内对两个同样被推断为 `@MainActor` 的
类型（`JavaRequirement` / `DefaultJavaResolver`）改为在后台任务内经 `await MainActor.run` **异步构造**，
避免「把函数标成 `nonisolated`、却仍在非隔离上下文同步访问主 actor 初始化器」这一新的隔离错位。

> 说明：`JavaRequirement` / `DefaultJavaResolver` 属纯数据 / 无状态对象，本不该带主 actor 隔离
> （根因见 §1「本项目专属提醒」第 11 条）。彻底修法是给它们显式标 `nonisolated`，但不在本次改动范围内。

### 8.4 测试覆盖语义的变化（待跟进）

XCTest 用例方法默认在主线程执行，因此新增的主线程判断生效后，该文件里的所有断言都会走
「主线程放弃 → 返回 `nil`」分支：断言仍然全部通过，但**不再覆盖**超时路径与「非 nil 结果必为真实文件」
这两条原意。跟进项见 8.6。

### 8.5 待办：实现侧（本次**不**实施）

- [ ] **Java 解析改为启动前异步预解析 + 结果缓存（推荐方向）**
  在进入 `slLaunch` 之前（或应用启动 / 切换实例时）以原生 `async` 方式调用
  `DefaultJavaResolver`，把命中的 `URL` 写入带锁缓存的 `selectedJavaURL`；启动链路只读缓存，
  不再在同步上下文里等待异步结果。这样可同时消除：`DispatchSemaphore` 阻塞、游离
  `Task.detached`、以及 §2.5 的「隔离声明与运行线程不一致」。落地时需一并处理缓存失效
  （版本不足 / 文件被删除）与失效后回退顺序。
- [ ] **评估把 `JavaResolverBridge.resolveSynchronously` 降级为 `@available(*, noasync)`**
  用编译器挡住未来在 async 上下文中的误用（官方《Attributes》明确该属性可用于此目的）。
- [ ] **复核 §2.5**：若决定让 `slLaunchInternal` 成为真正的 `@MainActor`（方案 B），
  必须先完成上一条预解析改造，否则 8 秒阻塞会真的落在主线程上。

### 8.6 待办：测试侧（本次**不**实施）

- [ ] **把 `JavaResolverBridgeTests` 的超时用例改为不在主线程运行**
  （例如放进后台队列或用 `async` 用例），使其继续覆盖「超时 → nil」与「非 nil 结果必为本机文件」
  两条路径；否则主线程判断会把这批用例变成同一条分支的重复断言。
- [ ] 为 `ManagedProcess.waitForTermination()` 补一条**已结束进程**的用例：
  构造一个立即退出的 `Process`，断言 `waitForTermination()` 能返回而**不永久挂起**
  ——这正是 §2.1 修复所保护的行为（当前 `ManagedProcess` 直接持有 `Process`、无注入点，
  如需可断言性需先抽象协议，见 `qwqTests/TESTING.md` 的同名建议）。
