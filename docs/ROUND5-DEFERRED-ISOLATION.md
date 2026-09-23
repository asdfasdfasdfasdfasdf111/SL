# 遗留待决：两处「假后台」磁盘扫描（隔离级联，未改）

> 本文记录本轮（Round 5）逐模块深读中发现、但**没有当场修改**的一类真缺陷。
> 不是「不确定就跳过」，而是修复必须跨 4 个文件做一次隔离归属变更，属于行为/架构级改动，
> 按约定先出方案再动。文中每条都附编译器原文与可核对的调用链。

## 一句话结论

工程有两处代码**写着「在后台扫描」**，实际**跑在主线程**：

| 位置 | 声明意图（代码注释） | 实际情况 |
|---|---|---|
| `qwq/Features/Game/VersionUtils.swift:156-166` | 「磁盘扫描走 `Task.detached(priority: .userInitiated)`」 | 被调函数是 `@MainActor`，调用时**隐式回跳主 actor** → `/usr/bin/find` 在主线程跑 |
| `qwq/Features/Java/JavaRepository.swift:57-63` | 「在 detached task 内完成扫描与转换」 | 被调 `JavaManager.scanInstalledJava` 是 `@MainActor` → 扫描在主线程跑 |

后果（用户可感知）：
- 点「全盘查找游戏」→ 主线程同步执行最多 3 条 `/usr/bin/find`（`findGameRootDirectories` 里每条 `timeout: 10`），**最坏 30 秒转菊花**；
- 打开 Java 扫描（`preScanJavaAsync`）→ `ContentsOfDirectory` + 每个 Java 跑 `/usr/libexec/java_home`，主线程阻塞。

## 证据（编译器原文）

`-default-isolation MainActor` 口径下：

```
qwq/Features/Game/VersionUtils.swift:158:20: warning: main actor-isolated static method
  'findGameRootDirectories()' cannot be called from outside of the actor;
  this is an error in the Swift 6 language mode
qwq/Features/Game/VersionUtils.swift:164:20: warning: main actor-isolated static method
  'findFirstValidGame()' cannot be called from outside of the actor
qwq/Features/Java/JavaRepository.swift:60:13: warning: expression is 'async' but is not marked with 'await';
  this is an error in the Swift 6 language mode
qwq/Features/Java/JavaRepository.swift:60:76: warning: call to main actor-isolated initializer 'init(_:)' in a synchronous nonisolated context
```

警告本身就是「这次调用跨了 actor」的证明：Swift 5 语言模式下编译器**插入隐式 await**完成跳转，
所以代码能跑通、也没有崩溃，只是**跳回了主 actor 去执行本该在后台的活**。
`Task.detached` 的封装因此完全失效——detached 只保证「闭包体的起点不在主 actor」，
一旦闭包体内调用了 `@MainActor` 函数，后面的活就全在主线程了。

依据：《Concurrency》——`Task.detached` 不继承 actor 隔离，但**被调用方自身的隔离标注仍然生效**；
`nonisolated` 声明不参与隔离推断，可从任意并发域调用。
官方链接：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

## 为什么不能就地改

把 `findGameRootDirectories` / `getVersions` / `normalizeVersionFolderNames` / `detectLoaderName` /
`findFirstValidGame` 标 `nonisolated` 是**正确方向**，实测（本轮做过、已回退）会连锁引出 15 条新告警，
因为它们依赖的东西同样是隐式 `@MainActor`：

```
VersionUtils:25/26     static property 'renameLock'          → 需 nonisolated
VersionUtils:61        global func 'log(_:file:line:)'        → 需 nonisolated（LogManager）
VersionUtils:94/121    AppContext.shared                      → 需 AppContext 可非隔离访问
VersionUtils:96/99/103/104/131  static property 'cacheKey' + cacheManager.setObject/removeObject
VersionUtils:121       processPool.execute(_:args:...)        → 需 ProcessPool.execute nonisolated
JavaRepository:60      JavaInstallation.init + JavaManager.scanInstalledJava
```

即一次改动要覆盖 **4 个文件**：`VersionUtils.swift`、`LogManager.swift`（`log`）、
`App/AppContext.swift`（`shared`）、`Features/Launch/ProcessPool.swift`（`execute` / `executeForData`）、
外加 `JavaManager` / `JavaInstallation`。其中两处有**明确的既有设计意图**，改之前需要确认：

1. `ProcessPool` 类头注释写着：本类「本可标 `nonisolated`；但那**不解决**阻塞问题……标 `nonisolated`
   只会让调用点失去编译器的主线程提醒。因此这里保持默认隔离，**等调用点改造时一并处理**」。
   → 本条就是「调用点改造」的时刻：调用点要的是真后台，所以提醒已经完成了它的使命；
   但推翻这条注释等于撤销全库对 `execute` 的主线程保护，属于架构决策。
2. `AppContext` 是全局依赖容器（持 `URLSession` / `CacheManager` / `ProcessPool` / `ProcessPool` 的
   `DispatchSourceMemoryPressure`）。整类标 `nonisolated` 需先评估 `memoryPressureSource`（可变状态）
   与 `ProcessPool`（非 `Sendable`）的处置。

## 建议改法（供决策，未实施）

按「先窄后宽」，任选其一：

**方案 A（推荐，改动最小且不推翻 ProcessPool 的设计意图）**：只把**纯计算与文件系统部分**做成
`nonisolated` 静态函数，把两个需要主 actor 的依赖**以参数传入**，让 `Task.detached` 里不再出现
`@MainActor` 调用：

```swift
// 1) ProcessPool 增加一个显式的后台入口（内部仍走同一份白名单/超时/并发控制），
//    仅在该入口上标 nonisolated，并在文档里写明「阻塞语义不变，禁止主线程调用」。
// 2) VersionUtils.findGameRootDirectories(runner:) 改为 nonisolated，runner 由调用方在主 actor 取值后传入。
// 3) JavaRepository.scan 同理：先 await MainActor.run 取 JavaManager 需要的值，再进 detached。
```

**方案 B（一次性收口）**：给 `AppContext` / `ProcessPool` / `JavaManager` / `JavaInstallation` 统一加
`nonisolated`（`ProcessPool` 需 `@unchecked Sendable`，其成员全是 `let`/`DispatchSemaphore`，
天然满足），并给 `log(_:file:line:)` 加 `nonisolated`（`LogStore` 内部已有串行队列，本就线程安全）。
一步到位后可消掉上表全部 15 条告警，并让 `Task.detached` 真正落到协作线程池。

两者都必须**两口径 0 错误 + 真实 xcodebuild 通过**后才算完成；且需要一次真机验证
（点「全盘查找游戏」时界面不得转菊花）。

## 顺带记录：一处不能照「口径二」单独优化的坑

`ForgeInstaller.swift:137/174/181` 与 `ForgeInstallerInstallFlow.swift:139` 在**口径二**下报
`no 'async' operations occur within 'await' expression`（看起来 `await` 是多余的），
但在**口径一（无 default-isolation）**下那 4 个 `await` 是**必需的**：`setProgress` / `increaseProgress`
本身带 `@MainActor`，而 `ForgeInstaller` 类在口径一里不是 `@MainActor`，去掉 `await` 直接产生 6 个 error。

本轮已实测并回退。结论：**这两条告警只能留在基线里，不能靠删 `await` 消掉**；
要消它必须让两个口径的隔离结论一致（即把 `ForgeInstaller` 显式标 `@MainActor`，
或把 `setProgress` 从 `@MainActor` 降为 `nonisolated`）——同样是隔离级联，归入上文一并决策。
