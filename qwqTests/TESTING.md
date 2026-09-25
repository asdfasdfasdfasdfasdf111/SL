# qwq 单元测试说明

本目录是给 `qwq` 工程补的单元测试，覆盖 `Core/`（下载、模块内核）、`Features/Java/`、
`Features/Launch/`、`App/ViewModels/`、`UI/Notices/` 与下载适配器层。

**当前状态：工程已包含 `qwqTests` unit-test target（`productType = com.apple.product-type.bundle.unit-test`）。`qwq.xcodeproj` 通过 `PBXFileSystemSynchronizedRootGroup` 自动同步整个 `qwqTests/` 目录，新增 / 删除测试文件无需手工加入 target；`qwq.xcscheme` 的 TestAction 已挂 `qwqTests.xctest`，直接 ⌘U 即可运行。详细进展见 `REFACTOR_PLAN.md`。**

## 一、XCTest target（已完成，无需手工创建）

工程已包含 `qwqTests` unit-test target（`productType = com.apple.product-type.bundle.unit-test`）。`qwq.xcodeproj` 通过 `PBXFileSystemSynchronizedRootGroup` 自动同步整个 `qwqTests/` 目录，新增 / 删除测试文件无需手工加入 target；`qwq.xcscheme` 的 TestAction 已挂 `qwqTests.xctest`，直接 ⌘U 即可运行。详细进展见 `REFACTOR_PLAN.md`。

- **target**：`qwqTests`，产物 `qwqTests.xctest`，类型 unit-test bundle。
- **目录自动同步**：`qwqTests/` 作为 `PBXFileSystemSynchronizedRootGroup` 自动纳入编译，测试文件放在该目录下即生效，不需要拖进 Xcode 或在 File Inspector 里勾选 Target Membership。
- **运行**：Xcode 中 ⌘U；或执行 `./scripts/verify-test.sh run`（编译 + 运行，约 40 秒）。
  2026-09-24 复核：**AI 会话里就能跑**（沙箱已由用户关闭）—— 旧文档「必须脱离沙箱在 Terminal 里跑」
  的结论已作废，根因就是调用方沙箱。
- **接线记录**：见 `REFACTOR_PLAN.md` 第 15 项（`8172dbf`，TEST BUILD SUCCEEDED，14 文件 181 用例可编译）。

测试文件清单（共 **22** 个，目录自动同步，无需手工加入 target）：

| 文件 | 被测对象 | 备注 |
| --- | --- | --- |
| `JavaResolverTests.swift` | JavaRequirement / DefaultJavaResolver / JavaInstallation | 经 `JavaRepository` 协议注入 fake，无需真实扫描 |
| `DownloadVerifierTests.swift` | CryptoKitDownloadVerifier | 临时目录造真实文件，不依赖网络 |
| `DownloadMergerTests.swift` | DownloadMerger 契约 | 协议无默认实现，用测试替身验证契约 |
| `DownloadStateTests.swift` | DownloadProgress / DownloadState / DownloadError | 纯值类型，重点覆盖「大小未知」时的 NaN/除零边界 |
| `DownloadSliceBudgetTests.swift` | `NetManager.sliceBudget`（分片总超时预算） | 纯函数：验证超时随剩余量与实测速度缩放，慢而健康的下载不再被判失败 |
| `InstallTaskProgressTests.swift` | InstallTask.getProgress / InstallTasks.getProgress | 纯值类型；同名的两个 `getProgress()` 边界口径必须一致（空任务组 0/0 → 曾显示字面量「nan %」，见 §4.15） |
| `LaunchStateTests.swift` | LaunchState / LaunchError / LaunchResult | 纯值类型 |
| `LaunchCancellationTests.swift` | `LaunchCancellationToken`（`SLCore/SLLaunchBridge.swift`） | 「进程还没起就别起了」这条语义的守卫；只覆盖令牌本身，不拉起进程 |
| `GameLogRetentionTests.swift` | `Features/Launch/GameSession.swift` 的 `dropCount(forCount:)` 与 `maxLogLines` | 日志合并窗口 + 上限裁剪的边界 |
| `GameScanGenerationTests.swift` | `Features/Game/ViewModels/GameCategoryViewModel.swift` | 扫描代际；含「超时不作废结果」的回归守卫 |
| `ModuleRegistryTests.swift` | SLModule / ModuleContext / ModuleRegistry / ModuleCapabilityKey | 用 `SLModule` 替身，不触发真实模块副作用 |
| `JavaResolverBridgeTests.swift` | JavaResolverBridge | 2026-09-25 起经 `makeResolver` 注入 resolver 替身。**调用线程是显式选择的**：覆盖解析结果 / 超时 / 失败 / 并发 / 入参透传的断言**一律在非主线程**调用（否则会被「主线程直接返回 nil」的早退分支整体短路 —— 这正是重写前那 8 条用例的假绿成因，见 §4.3）；**只有 `testMainThreadCallReturnsNilWithoutTouchingResolver` 一条在主线程上**调用，专测早退分支本身。 |
| `NoticeCenterTests.swift` | NoticeCenter / Notice / NoticeLevel / NoticeButton | MainActor 单例，用例内复位承载者状态 |
| `NavigationStateTests.swift` | NavigationState | 断言已复位 `DownloadDetailManager.shared` |
| `LaunchPanelStateTests.swift` | LaunchPanelState | 断言已复位 `LauncherSettings` 四个内存字段 |
| `HomeInteractionStateTests.swift` | HomeInteractionState | 纯视图级状态容器 |
| `DropInstallCoordinatorTests.swift` | DropInstallCoordinator | 分流与失败分支 + **成功安装分支**（经构造注入点把版本检测/实例匹配替换成替身，实例指向临时目录，断言文件真的落到 `versions/<版本>/mods`） |
| `DownloadAdapterTests.swift` | DownloadSourceResolver / DefaultDownloadSourceResolver / NetDownloaderDownloadEngine / DefaultDownloadVerifier.checker | 经构造参数注入 resolver，`precheck` 跳过路径无需网络 |
| `MemoryPressureTests.swift` | `Core/Events/MemoryPressure.swift`、`App/MemoryCacheReclaimer.swift`、`App/AppCompositionRoot.swift` | 事件发布/订阅语义 + 「装配根确实跑过」（断言 `AppCompositionRoot.didRegisterRuntimeServices`，见 §4.17）+ 生产同构的 dispatch source 上下文；端到端验证内存压力真能清掉 `ModrinthCategoryCache` |
| `SkinDecoderTests.swift` | `DefaultSkinDecoder.supportedPixelSizes` 与 `SkinAvatarCropper.validateSkin` | 钉死「校验放行的尺寸必须真能被裁剪」这条一致性约束 |
| `SkinPatchSupportTests.swift` | 皮肤补丁的尺寸分类 / 版本 id 拆分 / 加载器闸门 | 尺寸必须按整倍数判定，最易误放行的是 `128×32` |
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

- **退出码 0，0 个 error**（当时的 18 个测试文件 + 全部生产源码）。
- 48 条 warning，其中绝大多数是每个测试文件各一条
  `warning: file '...' is part of module 'qwq'; ignoring import`（单模块编译的预期产物）；
  其余是生产代码里既有的 warning（未使用的局部变量、Swift 6 并发警告等），与测试无关。

> ★ **2026-09-25 复核**（改用统一入口 `./scripts/typecheck.sh`，口径见该脚本头部注释）：
> **22 个测试文件 / 248 个用例**；两口径均 **0 个 error**；
> 告警 **口径一 46 / 口径二 24**（口径一 = 口径二 + 2×测试文件数，差值 22×2 = 44 正是单模块编译
> 下每个测试文件那两条 `@testable import` 产物，属预期）。
> ⚠️ 该脚本的**裸** `grep -c 'error:'`／`'warning:'` 会把 swiftc 打印的**源码上下文行**也算进去，
> 且每条诊断按 **2 倍**计数（本项目正好有一行 `var error: Error?` 会被误算成 error）。
> 判定一律以**告警集合逐条 diff** 为准，**不要**用数字相等做判据。
> ⚠️ 2026-09-25 补充实测：**编译一旦报错，后面文件的告警会被吞掉** ——
> 同一份源码带着 4 处错误时口径一只报 32 告警，修掉后恢复到 46。
> 所以「告警变少」可能是被截断，不是变好。（该脚本本轮起带 `-D DEBUG`，
> 理由与实测写在脚本头部：不定义 `DEBUG` 时 `#if DEBUG` 的代码从未被这一层检查过。）

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
- `NoticeCenterTests.swift` → `UI/Notices/NoticeCenter.swift`、`SLCore/Notices/Hint.swift`、`SLCore/Notices/Popup.swift`
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
> `AppContext` / SwiftUI；离线账号 / 提示通道（`SLCore/Account/`、`SLCore/Notices/`）依赖
> `VersionManifest` / `MinecraftDirectory`；全局 `err()` 所在的 `LogManager.swift` 依赖 `SharedConstants`）。
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
| `JavaResolverBridgeTests.swift` | 12 | 真实断言（注入 resolver 替身；调用线程显式选择：非主线程走真实路径、主线程专测早退分支） |
| `NoticeCenterTests.swift` | 22 | 真实断言 |
| `NavigationStateTests.swift` | 16 | 真实断言 |
| `LaunchPanelStateTests.swift` | 11 | 真实断言 |
| `HomeInteractionStateTests.swift` | 5 | 真实断言 |
| `DropInstallCoordinatorTests.swift` | 22 | 真实断言（分流/失败分支 + 成功安装路径：注入替身 + 临时目录，断言文件真的落到 `versions/<版本>/mods`） |
| `DownloadAdapterTests.swift` | 25 | 真实断言（注入 resolver + `precheck` 跳过路径） |
| `DownloadSliceBudgetTests.swift` | 6 | 真实断言（纯函数：超时预算的缩放与上下界） |
| `InstallTaskProgressTests.swift` | 5 | 真实断言（进度边界口径，含任务组空集合的 NaN 防护） |
| `LaunchCancellationTests.swift` | 4 | 真实断言（令牌置位后各判定点一律以 `cancelled` 收口） |
| `GameLogRetentionTests.swift` | 3 | 真实断言（合并窗口 + 行数上限裁剪） |
| `SkinDecoderTests.swift` | 9 | 真实断言（尺寸白名单与裁剪口径一致性） |
| `SkinPatchSupportTests.swift` | 20 | 真实断言（尺寸分类 / 版本 id 拆分 / 加载器闸门） |
| `GameScanGenerationTests.swift` | 3 | 真实断言（扫描代际；含「超时不作废结果」的回归守卫） |
| `MemoryPressureTests.swift` | 12 | 真实断言（主线程同步送达 / 等级透传 / 注销与闭包释放 / 生产同构的 dispatch source 上下文 / 装配根接线（§4.17）/ 首次注册 +1 与重复注册 +0 / 端到端清缓存） |
| `RealLaunchIntegrationTests.swift` | 1 | 默认跳过：真实拉起 Minecraft 进程验证启动链路健康（见 §4.14） |
| **合计** | **254** | 其中 1 条默认跳过 |

> **本次实测口径（含提交锚点，便于复核）**
>
> ```text
> Executed 254 tests, with 1 test skipped and 0 failures
> ** TEST EXECUTE SUCCEEDED **
> Commit: d9b4f3c77f290a5c1ad32c0aec5bff8947c043f2（254 用例即该提交的内容）
> Date:   2026-09-25
> Branch: refactor/modular
> ```
>
> ⚠️ **这道门是概率性的**（2026-09-25 实测，详见 §五末）：套件约 **1/4** 概率在
> `LaunchCancellationTests.testUncancelledTokenPassesEntryGate` 处 **abort**
> （`pointer being freed was not allocated`，即 §五 那条工具链缺陷的另一个触发面，**真实启动路径**
> 里析构 `MinecraftInstance` / `MinecraftDirectory` 时踩到）。**HEAD 上同样会崩**
> （只跑「DropInstallCoordinatorTests + LaunchCancellationTests」两套、各 4 次：工作区 3 通 1 崩、
> HEAD 3 通 1 崩）⇒ **abort 本身不能作为「代码有问题」的判据，要定性必须用同一命令在 HEAD 上对照跑。**
> 复现方式：`SL_DERIVED=/tmp/<新目录> ./scripts/verify-test.sh run`，abort 后换全新派生目录重试。
>
> **232 → 241 → 243 → 244 → 248 → 254 的来源逐条写明**（不要只更新总数）：
>
> - `218 → 232`：**不是新增用例，是本表漏记**。此前新增的 4 个文件的用例从未录入本表 ——
>   `DownloadSliceBudgetTests` +6、`LaunchCancellationTests` +4、`GameLogRetentionTests` +3，
>   加上 `NoticeCenterTests` 后来补的同步投递用例 +1 ⇒ 218 + 14 = **232**。
> - `232 → 241`：新增 `MemoryPressureTests`（9 条）。
> - `241 → 243`：`MemoryPressureTests` 再补 2 条 —— 生产同构的 dispatch source 上下文
>   （`testPostFromMainQueueDispatchSourceIsDelivered`）与注销后闭包释放
>   （`testRemovedHandlerReleasesItsCaptures`）。
> - `243 → 244`：把幂等用例拆成两条（`testFirstRegisterAddsExactlyOneHandler` +
>   `testRepeatedRegisterAddsNoHandler`），用例数 +1 —— 拆分理由见 §4.17。
> - `244 → 248`：`JavaResolverBridgeTests` **重写**（8 条 → 12 条，净 +4）。原 8 条里的 6 条因「主线程早退分支」
>   短路而从未执行到真实路径（详见 §4.3），重写后全部改为显式选择调用线程 + 注入 resolver 替身。
>   新增的 4 条净增覆盖：命中透传、`minimumMajor` 钳制与 `Int.max`/`mcVersion`/`remarks` 透传、
>   三条解析失败原因逐条吞掉 + 失败立刻返回（不耗满 timeout）、并发不串扰（断言每次拿到自己的结果）。
> - `248 → 254`：`DropInstallCoordinatorTests` 补**成功安装路径**（16 条 → 22 条，净 +6）：
>   进弹窗（成功分支）、无匹配实例只报错、一批 jar 后写覆盖暂存目标（确认时装的的确是暂存那个）、
>   确认安装后文件落到每个实例的 `versions/<版本>/mods` + 成功气泡、部分失败（warning 横幅 + 可写实例照常装上）、
>   全部失败（error 横幅列出每个原因）。驱动方式与「为什么不去驱动真实 `findInstances`」见 §4.5。
>
> 历史：2026-09-24 为 218 条 / 18 个文件。⚠️ **新增测试文件时必须一并更新本表、总数与上表行** ——
> 本表已漂移过两次（一次「表里 14 个、实际 18 个」，一次「表里 218、实际 232」）。
> 核对命令：`ls qwqTests/*.swift | wc -l` 校验文件数，
> `./scripts/verify-test.sh run` 后 grep `Executed [0-9]+ tests` 与各
> `Test Suite 'XxxTests'` 的 `Executed` 行校验用例数。

关于「非纯真实断言」的**一处**（原为两处，第一处已于 2026-09-25 消除），已在对应文件注释中写明：

1. ~~`JavaResolverBridgeTests` 的「解析成功」分支依赖本机是否装有 Java~~ —— **已于 2026-09-25 消除**。
   原 `testNonNilResultIsAnExistingLocalFile` 是条件断言（`if let url = result { … }`，为 nil 时不断言）。
   根因比注释写的更重：那次调用在**主线程**上，结果**恒为 nil**，`if let` 的整段其实是**死代码**。
   加 `makeResolver` 注入点 + 把调用移到非主线程后，命中分支由替身确定性驱动，
   该条已替换为无条件的 `testNonNilResultIsAFileURLWithNonEmptyPath`。详见 §4.3。
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

### 4.3 `JavaResolverBridge` 的「解析失败（非超时）」确定性覆盖 —— **已于 2026-09-25 完成**

- **结论**：注入点已加（`makeResolver`，默认值 `{ DefaultJavaResolver() }` 即生产路径），
  `scanFailed` / `noCompatibleVersion` / `notFound` 三条原因现在都有确定性断言。
- **但真正的问题比「缺注入点」严重得多**：原 8 条用例里 6 条用 `timeout: 0`（或负数）**在主线程**调用，
  而 `resolveSynchronously` 的第一条分支就是 `if Thread.isMainThread { return nil }`
  （避免 8 秒信号量等待冻结 UI）。测试 target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
  async 用例体就跑在主线程上 ⇒ **早退分支先返回，`semaphore.wait` 从未执行**：
  - 那 6 条声称覆盖的「超时即放弃」**从未被验证**（且 `timeout: 0` 本身意味着内部任务还没被调度，
    即使不在主线程也测不到）；
  - `testNonNilResultIsAnExistingLocalFile` 结果恒为 nil，断言体是**死代码**；
  - `testConcurrentCallsReturnNilWithoutDeadlock` 有部分迭代确实走到真实超时路径，但断言无区分力。
- **修法**：把「调用线程」变成必须显式选择的两个入口 —— `callOffMainThread`（`Task.detached`，走真实路径）
  与 `callOnMainThread`（`MainActor.run`，专测早退分支）；并把「`MainActor.run` 内是主线程 /
  `Task.detached` 内不是」这两个前提本身钉成断言（`testThreadPremisesHold`），防止将来悄悄退回假绿。
- **反向验证**（各精确只红 1 条）：摘掉主线程早退分支 → 只红 `testMainThreadCallReturnsNilWithoutTouchingResolver`
  （耗时 10.001s；副作用实证：主 actor 被信号量阻塞后内部 `MainActor.run` 拿不到主 actor，
  只能等满 timeout —— 这正是早退分支必须放最前的原因）；摘掉 `max(0, minimumMajor)` →
  只红 `testMinimumMajorIsClampedBeforeReachingResolver`。
- **代价 / 剩余缺口**：不驱动真实默认解析器，因为 `DefaultJavaRepository.save` 会写入
  `JavaManager.shared.saveCachedJavaPath`，即**真实用户设置**（在测试里改用户数据不可接受）。
  因此 `{ DefaultJavaResolver() }` 这一行只在评审层面被守住。
- **测试范围的准确说法**（别写成「全部覆盖」）：**已验证 `JavaResolverBridge` 的桥接语义** ——
  命中透传、三条失败原因一律吞掉并返回 nil、超时/失败快速返回、主线程早退、入参钳制与透传、并发不串扰；
  **未验证默认 resolver 在真实机器环境里的完整端到端行为**（真实扫描、用户环境隔离、
  以及超时后后台任务无法取消）。

### 4.3.1 一条工具链盲区（本轮实际踩到，别再重复推导）

`swiftc -typecheck` 对 **`escaping closure captures non-escaping parameter`** 完全静默：
给函数加闭包参数（为可测性加注入点时的常规动作），并在 `Task.detached` 里调用它、忘记 `@escaping`，
则**两口径 0 错误**，而 `xcodebuild build` 报 1 error。5 行最小复现见技能 `xcodebuild-in-sandbox`
的「真实编译 ≠ 类型检查」第 6 条。注意 `@MainActor` / `@Sendable` 都**不改变逃逸性**，三者要分别标。

### 4.4 `DefaultDownloadSourceResolver` 的镜像（自动切换）方向

- 未覆盖：`AppSettings.fileDownloadSource == .both` 且主源属于官方域名族时，
  追加 BMCLAPI 备用源（第二个候选仅 host 被替换，path / query 保持不变）。
- 阻塞原因：`DownloadSourceManager` 是单例，both 模式下 `getDownloadSource()`
  会触发真实的官方源测速后台任务，测速结果会改写当前主源，
  导致候选个数在官方源与镜像源之间漂移，无法稳定断言。
- 计划：给源管理器加注入点或把「当前源 + 互补源」改成纯函数后再补。
- 已覆盖的单源一侧：非官方域名、手动限定「仅官方 / 仅镜像」、无 host 的本地路径，
  均断言只返回一个候选。

### 4.5 `DropInstallCoordinator` 的成功安装分支（2026-09-25 已覆盖）

- **已覆盖**（`DropInstallCoordinatorTests`，+6 条）：`beginModInstall` 成功分支（版本能识别 + 匹配到实例
  → 打开弹窗并暂存）、`confirmModInstall` 的成功分支（文件真的落到每个实例的 `versions/<版本>/mods`，
  逐字节比对内容），以及**部分失败 / 全部失败**两条结果分支（warning / error 横幅 + 失败原因逐条列出，
  且不得把失败伪装成「已安装到 N 个实例」）。
- **怎么做到的**：给 `DropInstallCoordinator` 加了构造注入点（两个带默认值的 `@MainActor` 闭包：
  `detectVersion` / `findInstances`）。默认值即生产接线，生产调用点 `DropInstallCoordinator()`
  一个字节都没改。注入后把实例指向临时目录，**保留真实的 `ModDragInstaller.install`** ——
  被测的落盘行为因此是真代码，而不是替身自己造出来的结论。
  ⚠️ 顺带把类显式标了 `@MainActor`（口径二下语义不变，因为它本来就被推断为主 actor 隔离）：
  闭包参数标 `@MainActor` 后，只有显式隔离的调用方才被允许同步调它，否则「默认隔离」口径报
  `#ActorIsolatedCall`。这也是「显式标注能把静默的隔离误用变成编译错误」的一个实例。
- **未覆盖（有意不覆盖）**：真实的 `ModVersionDetector.detectVersion` 与 `ModDragInstaller.findInstances`
  不在用例里驱动 —— **不是因为没有注入点（现在有了），而是因为驱动它们会写用户的真实游戏目录**：
  `findInstances` 除「选定根目录」外还会全盘扫描本机游戏目录，并对每个扫到的根目录调
  `MinecraftVersionManager.getVersions` → 内部 `normalizeVersionFolderNames` **会重命名磁盘上的版本文件夹
  并改写其中的 json**。测试不该触发这类写副作用。代价：`findInstances` 自身的匹配规则（含它那个
  `savedRoot` 分支）仍无用例；要覆盖它得先把「扫描」与「匹配」拆开，或注入一个目录列举器。
- `confirmModpackInstall` 的成功分支**不可达**（不是「没测」）：`ModpackInstaller.install` 的最后一步
  `installLoader` 无条件抛 `InstallError.loaderInstallUnsupported`（刻意为之，见其文档注释：
  宁可真失败，也不假装装上加载器）⇒ `presentMessage("整合包安装完成")` 永远执行不到。
  其失败分支要真正联网（`installMinecraft` 先打 launchermeta 官方源）才走得到，属集成测试范畴。

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

### 4.15 安装进度的 NaN 显示（**原缺口，已闭合**）

- 历史现象：空任务组（0/0）的总进度算出 `NaN`，下载详情页把它原样打印成字面量「**nan %**」。
- 现状：**已由 `InstallTaskProgressTests` 覆盖**（`XCTAssertFalse(group.getProgress().isNaN)` 等），
  同名两个 `getProgress()` 的边界口径一致。此处保留条目是为了让「§4 = 缺口登记簿」
  能体现**已闭合**的历史缺口，不再计入待办。

### 4.16 内存压力链路：有意接受的运行时假设（**非缺口，但必须登记**）

- `MemoryPressureBroadcaster.post` 在 `Thread.isMainThread` 为真时**同步**调用处理器，
  而 Swift 并不保证「主线程」等价于「在 MainActor 执行器上」（`assumeIsolated` 校验的是后者）。
- **这是有意接受的假设，不是待修缺陷**。实测证据与取舍写在 `Core/Events/MemoryPressure.swift`
  的 `post` 文档里，简述：生产发布点（`queue: .main` 的 dispatch source 回调）下 `assumeIsolated`
  实测可用；后台线程会被正确拒绝（`SIGTRAP`）；「主线程但非 MainActor」这个上下文在本工具链下
  构造不出来（40000 个非主 actor 任务落在主线程的次数为 0）；且若 source 的 `queue` 被改掉，
  该检查会退化到更安全的 hop 路径。
- **守它的用例**：`MemoryPressureTests.testPostFromMainQueueDispatchSourceIsDelivered`
  （同构的 dispatch source 上下文）。假设一旦不成立，该用例会当场 trap，而不是静默出错。
- **不能覆盖的部分**：`AppContext` 只有私有 init + `shared` 单例，实例化会建 3 个 URLSession、
  1 个 ProcessPool 并启动一次磁盘清扫，故 `AppContext.init()` 里的 source 接线（含
  「先赋值后 activate」的顺序）无法用用例驱动，只能靠读代码 + 真实运行覆盖；
  `MemoryPressureTests` 末尾的「覆盖率缺口」注释里逐条记了原因。

### 4.17 「装配根接线」这条性质是怎么被测的（**曾假绿，2026-09-25 修正**）

- 原先断言的是 `handlerCount >= 1`（**进程级绝对条数**）。它有两个结构性问题：
  ① 无法区分「应用装配根注册的」与「本文件其它用例自己 `register()` 注册的」；
  ② `MemoryCacheReclaimer.register()` 是**幂等**的、`token` 又是静态持久状态，
  于是反向验证可能只是「顺序刚好」而不是「测到了装配根」。
- 实测（改前）：它当时**确实**会红 —— 把 `register()` 从 `SLApp.init()` 摘掉后，
  `-only-testing` 单跑与全量跑都**恰好 1 条失败**。但它成立的前提是
  「该用例在本类按字母序排最前 + 全仓只有这一个类会注册回收器 + 未开随机测试顺序」，
  属**顺序巧合**：顺序一乱、或将来别的类先注册，它就会**假绿**，反向验证也随之失效。
- 现在的形式：断言 `AppCompositionRoot.didRegisterRuntimeServices` ——
  **单调**（置位后无人重置）、**唯一置位点**是应用自己的装配入口（且是它的最后一行，
  三条装配动作都跑完才置位）。因此与用例执行顺序无关。
- ⚠️ **它成立的承载性假设**：测试 bundle 由 `qwq.app` 宿主（`qwqTests` 的 `TEST_HOST` 指向
  `qwq.app/Contents/MacOS/qwq`），所以 `SLApp.init()` 先于任何用例执行。
  若哪天改成无宿主的 logic test，该用例会变红 —— 那是**正确**的失败（装配根确实不再被执行），
  按该用例注释里的三步排查，**不要直接删断言**。
- 配套手段：`MemoryCacheReclaimer.resetForTesting()`（`#if DEBUG`）让用例能从**未注册**这一
  确定状态出发断言**差值**；动过注册状态的用例在 `defer` 里还原成进程启动态，避免顺序污染。
- 反向验证（两次破坏**各精确红 1 条**）见 `CHANGELOG.md` 同日条目。

## 五、必须遵守：用例一律写成 `async`（Xcode 26.2 隔离析构缺陷）

**结论**：`qwqTests` 里**每个 `test…()` 方法都必须写成 `async`**。这不是为了等待什么，
而是为了躲开一条会把整个测试进程打死的工具链缺陷。当前 **22** 个测试文件、**248** 个用例已全部统一
（2026-09-25 实测：`Executed 248 tests, with 1 test skipped and 0 failures`；
新增测试文件时请同步上面的数字）。

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

### 残余触发面：`async` 并没有把这条缺陷完全挡住（2026-09-25 新证据）

「用例一律 `async`」修掉的是**同步用例**那一整类。但 2026-09-25 又观测到**同一个缺陷的另一条触发路径**，
**在 async 用例里**：

```
# 崩溃报告（~/Library/Logs/DiagnosticReports/qwq-*.ips）里的栈，自下往上：
swift::runJobInEstablishedExecutorContext          ← 确实在一个 job 里，不是「不在 Task 里」
MinecraftInstance.deinit / MinecraftInstance.__isolated_deallocating_deinit
_swift_release_dealloc
MinecraftDirectory.__deallocating_deinit           ← 内层：隐式析构 → 隔离析构
swift_task_deinitOnExecutorMainActorBackDeploy
swift::TaskLocal::StopLookupScope::~StopLookupScope()
___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED   → abort
```

共同点是**嵌套的隔离析构**：一个主 actor 隔离类的 `deinit` 里释放了另一个**没有显式 `deinit`**
的主 actor 隔离类（`MinecraftInstance` → `MinecraftDirectory`；更早的两份报告是
`ClientManifest.Rule` → `ClientManifest.Rule.OSRule`）。触发点是**真实启动路径**
（`LaunchCancellationTests.testUncancelledTokenPassesEntryGate` 真的调了一次 `slLaunch`）。

**当前状态：未修，且它是概率性的** ——2026-09-25 实测约 **1/4**：

| 命令（只跑 DropInstallCoordinatorTests + LaunchCancellationTests，26 条） | 4 次结果 |
|---|---|
| 当前工作区 | 通过 通过 通过 **崩** |
| HEAD（未含当轮改动） | **崩** 通过 通过 通过 |

⇒ 两条纪律：① **abort 同轮重试即可**（换全新 `SL_DERIVED`），不要据此判定代码有问题；
② 要下「是谁弄崩的」这种结论，必须**同一命令在 HEAD 上对照跑**，单次结果没有说服力。
也可用更便宜的复现：`-only-testing:` 指定上面两套即可，不必跑全量。

⚠️ 另一个连带坑：**进程 abort 之后派生目录会退化** —— `qwq.app/Contents/PlugIns/qwqTests.xctest`
会消失，此后连 `build-for-testing` 报「成功」也不补回来（`test-without-building` 于是报
`Failed to create a bundle instance ... exists on disk`）⇒ **abort 后一律换全新 `SL_DERIVED`**。
⚠️ 还有：`test-without-building` **不会重新构建**，跑完「反向用例破坏版」后若不先 `build-for-testing`，
会拿旧的坏二进制跑出**假失败**（本轮踩过，见 CHANGELOG）。
