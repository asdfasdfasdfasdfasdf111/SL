# qwq 单元测试说明

本目录是给 `qwq` 工程补的单元测试，覆盖 `Core/`（下载抽象）、`Features/Java/`、
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

测试文件清单（共 **52** 个，目录自动同步，无需手工加入 target）：

| 文件 | 被测对象 | 备注 |
| --- | --- | --- |
| `JavaResolverTests.swift` | JavaRequirement / DefaultJavaResolver / JavaInstallation | 经 `JavaRepository` 协议注入 fake，无需真实扫描 |
| `DownloadVerifierTests.swift` | CryptoKitDownloadVerifier | 临时目录造真实文件，不依赖网络 |
| `ArtifactVersionMapperTests.swift` | `SLCore/Minecraft/Download/ArtifactVersionMapper.swift`（Apple Silicon 兼容适配） | 8 条替换规则 + 2 个架构分支逐条钉住；夹具经公开入口 `ClientManifest.parse(url:)` 由临时文件构造，**无需任何生产代码改动**（见 §4.20） |
| `ClientManifestArgumentsTests.swift` | `SLCore/Minecraft/ClientManifestArguments.swift`（启动参数模型） | 新版 `arguments` 与旧版 `minecraftArguments` 两条格式；规则组命中/不命中/否决/特性开关；畸形输入与 `value` 归一化。同样走 `parse(url:)`，**不 import SwiftyJSON** |
| `ClientManifestRuleTests.swift` | `SLCore/Minecraft/ClientManifestRule.swift`（`Rule`/`OSRule`/`Features`） | 顺序叠加语义逐条钉住；含源码注释点名的 `allSatisfy` 误实现反例。经 `parse` 时对 `libraries` 的筛选结果反推判定，**不 import SwiftyJSON** |
| `PropertiesParserTests.swift` | `SLCore/Utils/PropertiesParser.swift` | 逐条钉住源码自列的「与 `java.util.Properties` 的 3 处差异」+ 静默降级（读不到 ⇒ 空字典）；含空值/多 `=`/引号剥离等边界 |
| `AssetIndexTests.swift` | `SLCore/Minecraft/AssetIndex.swift` | 解析、`appendTo` 的分桶布局 `<base>/<hash 前两位>/<hash>`；钉住「丢弃逻辑路径 key ⇒ 同 hash 两条目不去重」。**断言不依赖 `objects` 顺序**（来自字典 values） |
| `OfflineUsernameValidatorTests.swift` | `Features/Skin/OfflineUsernameValidator.swift` | 长度上限 16 的**边界两侧**、`utf16.count` 语义（emoji 记 2）、trim 发生在长度判定之前、长度提示优先于字符提示 |
| `GameVersionHelperTests.swift` | `Features/Game/GameVersionHelper.swift` | `compare` 的数值序（非字符串序）、缺位补 0、**非数字段被丢弃**（`1.20.1-rc1` 与 `1.20` 判等、`1.20-pre` 小于 `1.19`）；`sortForDisplay` 置顶；`isAprilFoolVersion` 的列表命中先于 type 守卫、`point→.` 归一化、新旧快照格式 |
| `ModpackVersionGroupingTests.swift` | `Features/Download/ModpackVersionGrouping.swift` | 只用 `game_versions.first` 当键、`game_versions` 为空整条跳过、降序用语义比较（`1.10` 在 `1.9` 前） || `DownloadStateTests.swift` | DownloadProgress / DownloadState / DownloadError | 纯值类型，重点覆盖「大小未知」时的 NaN/除零边界 |
| `NetDownloadStateTests.swift` | `SLCore/Download/NetDownloadState.swift`（`NetManager.Slice` / `FileRecord`） | 分片剩余量、文件完成度、源是否全判死。钉住源码自认的三处问题：`end` 找不到自己时兜底成文件末尾、`fileSize == -2` 未特判得 0、`isAllSourcesFailed` 分界是 `<` |
| `DetailVersionDecisionTests.swift` | `Features/Game/DetailVersionDecision.swift` | 详情页「默认选中哪个版本」的完整规则；重点守住两处反直觉设计：游戏版本页 `itemName` 缺失时**返回 nil 不回退**、两个函数的 nil 语义分别是「不决定」与「保持现状」 |
| `LoaderNameResolverTests.swift` | `Features/ModBrowser/ModLoader.swift` + `Features/Download/LoaderNameResolver.swift` | `displayName`/`assetName` 映射；钉住注释点名的三条：rawValue 全小写而 assetName 混排、assetName **非单射**（rift/unknown 都→fabric）、子串匹配 **neoforge 先于 forge** |
| `InstallProgressTests.swift` | `SLCore/Minecraft/Download/InstallProgress.swift` | 钉住「`rawValue` 是**排序键**不是序号」这条无编译期保护的不变量（0…7 连续、1000+/2000+ 分段、整体有序），以及全部用户可见中文文案 |
| `MinecraftVersionInfoTests.swift` | `Features/Game/Module/MinecraftVersionInfo.swift` | `init?(manifestEntry:)` 的取舍（`id` 为空即丢、其余字段缺失只丢字段）；**并排钉住** `kind` 用可失败构造而非 `.release` 回落 |
| `GameModelsTests.swift` | `Models/GameModels.swift` | 侧边栏分类的**中文 rawValue 即显示名、也是 id**（注释：这串中文还承担页面分派，改名会静默落空）；`ModrinthTagMap` 的白名单语义；`DownloadedItem` **自定义 `==` 只比 id 与 subtitle** 的副作用 |
| `VersionFilterUseCaseTests.swift` | `Features/Game/Module/VersionFilterUseCase.swift` | 版本三分桶（测试版**排除**愚人节、远古版**包含**全部愚人节）；钉住「`subCategory: nil` 返回**空列表**而非不过滤」这条被注释特别强调的契约 |
| `MinecraftInstanceInfoTests.swift` | `Core/Minecraft/Module/MinecraftInstanceInfo.swift` | 镜像映射规则：清单文本判定的**分支顺序**（neoforged 先于 forge）、**认不出 quilt**、判定大小写敏感；`id` 取标准化路径；`manifestPath`/`configPath` 派生 |
| `SpeedMeterTests.swift` | `SLCore/Download/SpeedMeter.swift` 的 `CounterActor` | `takeInterval` 的**单次消费**语义（第二次必为 0）、`&+=` 溢出回绕不崩、actor 串行化下并发加减与取值守恒 |
| `ModProjectTests.swift` | `Features/ModBrowser/Module/ModProject.swift` | 四个转换 init **各自丢哪些字段**（搜索命中无分类、详情响应无简介/图标/下载量且 title 回落 id、本地目录无 slug、分类页单元无下载量与版本列表）；`primaryFile` 取值顺序 |
| `ArchiveUtilTests.swift` | `SLCore/Utils/ArchiveUtil.swift` | 三个方法**三种失败表达**（`hasEntry`/`getEntry` 把「归档打不开」与「条目不存在」合并；`getEntryOrThrow` 可区分）；夹具用 ZIPFoundation 现造真 zip |
| `MinecraftLauncherLogTests.swift` | `SLCore/Minecraft/Launch/MinecraftLauncherLog.swift` | 两个**已修 bug** 的回归守卫：`close()` 补刷无换行的残行、`drainPipe` 在写端被孙进程持有时**有时限返回**；另覆盖丢弃模式与跨回调多字节字符 |
| `ShaderLoaderFilterTests.swift` | `Features/Download/ShaderLoaderFilter.swift` | 光影页加载器白名单与**空则回退默认**；钉住「去重走 `Set` ⇒ 结果顺序不确定」与「回退列表须与白名单同集合」 |
| `ItemFilterTests.swift` | `Features/ModBrowser/ItemFilter.swift` | 搜索谓词四分支；重点是**中文译名反向匹配**（输「科技」须经 `ModrinthTagMap` 反查到 `technology`），且该分支是**精确相等**而非包含 |
| `GameVersionFilterTests.swift` | `Features/Game/GameVersionFilter.swift` | 适配层的取舍：`id` 缺失**静默丢弃**、`type` 缺失不落入任何分类、保序；并与 `VersionFilterUseCase` 逐子分类对齐 |
| `ModSearchRequestTests.swift` | `Features/ModBrowser/Module/ModSearchRequest.swift` | `nextPage()` 的偏移量顺推（连翻多页**不重叠不跳号**）；并用字段集合钉住「刻意没有 loader / 游戏版本过滤」的能力边界 |
| `LoaderSupportStateTests.swift` | `SLCore/Minecraft/Mod/Loader/LoaderSupportState.swift` | `LoaderSupportResult` **三态不可合并**（`.notSupported` 可缓存、`.unavailable` 不得缓存，否则一次网络抖动被永久缓存成「不支持」） |
| `LaunchOptionsTests.swift` | `SLCore/Minecraft/Launch/LaunchOptions.swift` | 默认值（尤其 `skipResourceCheck` 默认 false）；钉住 `javaPath` 是**隐式解包可选**这一危险声明 |
| `FabricManifestTests.swift` | `SLCore/Minecraft/Mod/Loader/Fabric/FabricManifest.swift` | 只读**嵌套** `loader.version` / `loader.stable`（顶层同名字段不参与）；非法 JSON 抛出而非静默空数组 |
| `ForgeInstallProfileTests.swift` | `SLCore/Minecraft/Mod/Loader/Forge/ForgeInstallProfile.swift` | `Processor.isAvailableOnClient` 的规则（**只有恰好 `["server"]`** 才判否，双端通用仍为真）；`classpath` 尾部追加 jarPath；`jarPath` 是**已解析路径**而非坐标 |
| `ModSearchResultTests.swift` | `Features/ModBrowser/Module/ModSearchResult.swift` | `hasMore` 用 **`offset + items.count`** 而非 `offset + limit`（服务端少返时的结论不同）；边界「相等即结束」 |
| `ModrinthSectionTypeTests.swift` | `Features/ModBrowser/ModrinthSectionType.swift` | 五个侧边栏分类的 `project_type` 映射；`.game` 必须为 nil（走 Mojang 清单而非 Modrinth）；拼写与接口对齐 |
| `DownloadSliceBudgetTests.swift` | `NetManager.sliceBudget`（分片总超时预算） | 纯函数：验证超时随剩余量与实测速度缩放，慢而健康的下载不再被判失败 |
| `InstallTaskProgressTests.swift` | InstallTask.getProgress / InstallTasks.getProgress | 纯值类型；同名的两个 `getProgress()` 边界口径必须一致（空任务组 0/0 → 曾显示字面量「nan %」，见 §4.15） |
| `LaunchStateTests.swift` | LaunchState / LaunchError / LaunchResult | 纯值类型 |
| `LaunchCancellationTests.swift` | `LaunchCancellationToken`（`SLCore/SLLaunchBridge.swift`） | 「进程还没起就别起了」这条语义的守卫；只覆盖令牌本身，不拉起进程 |
| `GameSessionStoreTests.swift` | `Features/Launch/GameSessionStore.swift` 的 `InMemoryGameSessionStore` | 钉住三条语义：多订阅者、终态 `finish()` 并清理订阅、晚订阅者回放最新状态。用**限时收集**而非直接 `for await`——实现若坏在「不 finish」上，用例应变红而不是把宿主挂死（见 §4.19） |
| `GameLogRetentionTests.swift` | `Features/Launch/GameSession.swift` 的 `dropCount(forCount:)` 与 `maxLogLines` | 日志合并窗口 + 上限裁剪的边界 |
| `GameScanGenerationTests.swift` | `Features/Game/ViewModels/GameCategoryViewModel.swift` | 扫描代际；含「超时不作废结果」的回归守卫 |
| `JavaResolverBridgeTests.swift` | JavaResolverBridge | 2026-09-25 起经 `makeResolver` 注入 resolver 替身。**调用线程是显式选择的**：覆盖解析结果 / 超时 / 失败 / 并发 / 入参透传的断言**一律在非主线程**调用（否则会被「主线程直接返回 nil」的早退分支整体短路 —— 这正是重写前那 8 条用例的假绿成因，见 §4.3）；**只有 `testMainThreadCallReturnsNilWithoutTouchingResolver` 一条在主线程上**调用，专测早退分支本身。 |
| `NoticeCenterTests.swift` | NoticeCenter / Notice / NoticeLevel / NoticeButton | MainActor 单例，用例内复位承载者状态 |
| `NavigationStateTests.swift` | NavigationState | 断言已复位 `DownloadDetailManager.shared` |
| `LaunchPanelStateTests.swift` | LaunchPanelState | 断言已复位 `LauncherSettings` 四个内存字段；另含「持久化字段经 `AppSettingsStore` 转发」那段的两条透传断言（绕过兼容层直写存储点验桥接、经兼容层写验转发与落值） |
| `HomeInteractionStateTests.swift` | HomeInteractionState | 纯视图级状态容器 |
| `DropInstallCoordinatorTests.swift` | DropInstallCoordinator | 分流与失败分支 + **成功安装分支**（经构造注入点把版本检测/实例匹配替换成替身，实例指向临时目录，断言文件真的落到 `versions/<版本>/mods`） |
| `DownloadAdapterTests.swift` | DownloadSourceResolver / DefaultDownloadSourceResolver / NetDownloaderDownloadEngine / DefaultDownloadVerifier.checker | 经构造参数注入 resolver，`precheck` 跳过路径无需网络 |
| `MemoryPressureTests.swift` | `Core/Events/MemoryPressure.swift`、`App/MemoryCacheReclaimer.swift`、`App/AppCompositionRoot.swift` | 事件发布/订阅语义 + 「装配根确实跑过」（断言 `AppCompositionRoot.didRegisterRuntimeServices`，见 §4.17）+ 生产同构的 dispatch source 上下文；端到端验证内存压力真能清掉 `ModrinthCategoryCache` |
| `SkinDecoderTests.swift` | `DefaultSkinDecoder.supportedPixelSizes` 与 `SkinAvatarCropper.validateSkin` | 钉死「校验放行的尺寸必须真能被裁剪」这条一致性约束 |
| `SkinPatchSupportTests.swift` | 皮肤补丁的尺寸分类 / 版本 id 拆分 / 加载器闸门 | 尺寸必须按整倍数判定，最易误放行的是 `128×32` |
| `RealLaunchIntegrationTests.swift` | （见 §4.14，默认跳过）真实启动链路集成用例 | 拉起真实 Minecraft 进程，靠 `/tmp/sl-real-launch.enabled` 开关默认跳过 |

每个测试文件顶部都有 `@testable import qwq`，因为多数被测类型（`JavaInstallation`、
`JavaRequirement`、`DefaultJavaResolver`、
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
- `LaunchStateTests.swift` → `Features/Launch/LaunchState.swift`、`LaunchError.swift`、`LaunchResult.swift`
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
- `AccountPersistenceCompatTests.swift` → `SLCore/Account/AnyAccount.swift`、`SLCore/Account/OfflineAccount.swift`、`SLCore/Storage/CodableAppStorage.swift`
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
| `DownloadStateTests.swift` | 10 | 真实断言（纯值类型） |
| `LaunchStateTests.swift` | 9 | 真实断言（纯值类型） |
| `JavaResolverBridgeTests.swift` | 12 | 真实断言（注入 resolver 替身；调用线程显式选择：非主线程走真实路径、主线程专测早退分支） |
| `NoticeCenterTests.swift` | 22 | 真实断言 |
| `NavigationStateTests.swift` | 16 | 真实断言 |
| `LaunchPanelStateTests.swift` | 12 | 真实断言 |
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
| `AccountPersistenceCompatTests.swift` | 13 | 真实断言（历史 JSON 字面量解码 / 编码器形状 / 往返 / 包装器机制 / 身份语义 / 安全护栏） |
| `GameSessionStoreTests.swift` | 6 | 真实断言（多订阅者 / 终态收口 / 回放 / 终态后不投递；限时收集防挂死，见 §4.19） |
| `ArtifactVersionMapperTests.swift` | 11 | 真实断言（逐条 switch 分支：`.x64` 只钉 natives 不动 url/path、`.arm64` 无 natives 早退、LWJGL 3.x 钉 3.3.2、3.3.3 不降级、JNA 4.4.0→5.14.0、objc-bridge 换 Maven Central、LWJGL2 natives 换 glavo、无关 groupId 不动、幂等、artifact 为 nil 不崩） |
| `ClientManifestArgumentsTests.swift` | 14 | 真实断言（裸字符串透传、规则组命中/不命中/否决、无 os 条件放行、特性开关排除、`value` 字符串与数组两形态、数组内非字符串丢弃、非字符串 value 归一成空、畸形数字条目静默不生效、旧版兜底切分 + 硬编码 10 项 jvm、`arguments` 优先于旧字段、两者皆无返回空、jvm 与 game 同逻辑） |
| `ClientManifestRuleTests.swift` | 12 | 真实断言（空规则恒放行、allow 命中/不命中/`unknown` 通用、`allow`+不匹配 `disallow` 必须保留（`allSatisfy` 反例）、匹配 `disallow` 否决、孤立 `disallow` 默认 false、后出现的 allow 覆盖先前 disallow、`features` 为 `true` 不命中而为 `false` 命中、多条库独立筛选且保序） |
| `PropertiesParserTests.swift` | 21 | 真实断言（基本解析 / 空值与多 `=` / 空行与两类注释 / `:` 不作分隔符 / 值内 `#`·`!` 截断 / 不处理转义与续行 / 键值 trim / 引号剥一层 / 读不到即空字典） |
| `AssetIndexTests.swift` | 13 | 真实断言（解析 hash+size、空与缺失 `objects`、非法 JSON 抛出、缺字段默认值、同 hash 两条目、`appendTo` 分桶、单字符与空 hash 不崩、`appendTo` 与 size 无关） |
| `OfflineUsernameValidatorTests.swift` | 10 | 真实断言（合法/空/纯空白、trim 前置、16 边界两侧、utf16 计数、非法字符、长度优先、emoji 落在字符提示） |
| `GameVersionHelperTests.swift` | 23 | 真实断言（数值序、缺位补 0、返回差值、非数字段丢弃的三种表现、降序与置顶、列表命中先于 type 守卫、`point→.`、新旧快照格式、pre/rc 排除、兜底 true） |
| `ModpackVersionGroupingTests.swift` | 8 | 真实断言（首现保留、多游戏版本只用第一个、空 `game_versions` 跳过、空输入、语义降序、原字符串去重键、结果取自入参） |
| `NetDownloadStateTests.swift` | 25 | 真实断言（`end` 中间/末尾/乱序/找不到自己、`undone` 正常与夹 0 与未知大小 `-1` 与未获取大小 `-2`、活跃分片含 resumed、`merging` 非终止、进度在 done/非正大小/正常/夹 1 四种情形、`isAllSourcesFailed` 的 `<` 边界与 `sourcesOnce` 排除与空真） |
| `DetailVersionDecisionTests.swift` | 19 | 真实断言（游戏版本页 vs 其他页 × 首次加载/就绪后决议的全部分支；nil 的两种含义分列） |
| `LoaderNameResolverTests.swift` | 19 | 真实断言（displayName/assetName 全表、rawValue 小写与往返、assetName 非单射、assetName(for:) 大小写与未知回退、name(forVersion:) 的本地优先/后缀从后往前/子串顺序/各级回退） |
| `InstallProgressTests.swift` | 10 | 真实断言（rawValue 分段与连续性、排序即执行序、分段整体有序、rawValue 唯一、13 条显示名与全非空、图标名的 Missingno 占位） |
| `MinecraftVersionInfoTests.swift` | 19 | 真实断言（id 缺失/空/非字符串丢条目、type 缺失退化 unknown、releaseTime 缺失空串、URL 解析与非法 URL 只丢字段、kind 全表与未识别为 nil、与 rawVersionType 回落并排对比、isAprilFool 与 helper 逐字一致、attaching 不可变、快照缺省为 nil 与可哈希） |
| `GameModelsTests.swift` | 20 | 真实断言（中文 rawValue 全表、id==rawValue、cases 顺序、SF Symbol 名与互异、TagMap 白名单/三类标签族/值非空、`==` 忽略 name·icon·tags、id 与 subtitle 各自决定不等、改名不刷新、Codable 往返与编码含被忽略字段） |
| `VersionFilterUseCaseTests.swift` | 16 | 真实断言（.all 原样保序、未识别 kind 只在 .all、三分桶各自成员、pre-release/rc 不进桶、愚人节只归远古、三桶互斥且并集可枚举、保序、空输入、nil 子分类返回空、子分类映射与往返、rawValue 与 id） |
| `MinecraftInstanceInfoTests.swift` | 21 | 真实断言（清单文本判定全表、neoforged 先于 forge、quilt 认不出、大小写敏感、空串 vanilla、displayName 的 NeoForge 特例、VersionKind 全表 rawValue 与回落 .release、id 标准化、manifestPath/configPath、Hashable 与 Sendable） |
| `SpeedMeterTests.swift` | 12 | 真实断言（初始 0、累加、读取即清零、清零后再累计、加 0、负值与负累计、上下溢回绕、20×50 并发不丢计数、8 次并发取用恰好一次命中、逐轮取值总和守恒） |
| `ModProjectTests.swift` | 21 | 真实断言（type 全表与展示名与往返、sha1 取 hashes 与两类缺失、hashes nil 归一空字典、primaryFile 四种情形、四个 init 的字段得失与 title 回落 id 与未知 projectType 为 nil、可哈希） |
| `ArchiveUtilTests.swift` | 14 | 真实断言（存在/缺失条目、不可打开归档同样 false、重载版本、取内容、缺失抛 MyLocalizedError 且文案精确、不可打开抛底层错、静默版两类失败都 nil、二进制逐字节保真、空条目、多条目独立、条目名大小写敏感） |
| `MinecraftLauncherLogTests.swift` | 21 | 真实断言（门控恰好一次与 32 并发只一个赢、完整行立即落盘、制表符展开、残行缓冲、**close 补刷残行**、残行展开、空缓冲不补行、非法 UTF-8 残字节原样落盘、close 幂等、关闭后丢弃、多字节跨回调拼接、非法整行丢弃不影响后续、丢弃模式、空 Data、drainPipe 正常/写端不关有时限/无数据有时限/排空后残行仍补刷）⚠️ 含 2 条各等约 3s 的用例 |
| `ShaderLoaderFilterTests.swift` | 11 | 真实断言（非光影页小写去重与空不回退、Set 顺序不定、光影页白名单过滤与大小写不敏感、空则回退默认、回退与白名单同集合、回退顺序确定） |
| `ItemFilterTests.swift` | 13 | 真实断言（标题/简介/标签三分支与大小写、中文译名反向匹配、反向匹配是精确相等、要求条目确有该标签、空 tags 退化、空查询恒真、无关查询不命中） |
| `GameVersionFilterTests.swift` | 10 | 真实断言（三桶成员、id 缺失与空串被丢弃、type 缺失不落任何分类、保序、nil 子分类为空、空输入、只返回 id、与 UseCase 逐子分类一致） |
| `ModSearchRequestTests.swift` | 8 | 真实断言（默认值、翻页顺推、连翻五页区间首尾相接、自定义 limit、不改原值、全字段参与相等、可入集合） |
| `LoaderSupportStateTests.swift` | 9 | 真实断言（supported 空列表合法且不同于 notSupported、非 supported 的 loaders 恒空、只有 unavailable 是未知、三态互不相等、列表顺序参与相等、LoaderState 四态与两层分离） |
| `LaunchOptionsTests.swift` | 7 | 真实断言（默认值、uuid 每次新、javaPath 未赋值为 nil 与可赋值、字段独立、引用类型共享、yggdrasilArguments 可追加） |
| `FabricManifestTests.swift` | 10 | 真实断言（嵌套字段解析、顶层同名字段不参与、空数组、缺字段默认、非法 JSON 抛出、非数组顶层为空、id 唯一且可变、引用类型、按 stable 过滤） |
| `ForgeInstallProfileTests.swift` | 12 | 真实断言（data 只取 client 子字段与缺省空串、isAvailableOnClient 五种 sides 组合、jarPath 是解析后路径、classpath 尾追 jar、无 classpath 只有 jar、args 原样含占位符、libraries 丢弃空坐标、空 profile） |
| `ModSearchResultTests.swift` | 8 | 真实断言（hasMore 的三类边界、恰好填满即结束、按 items.count 而非 limit、空页行为、无命中、.empty 常量、全字段参与相等） |
| `ModrinthSectionTypeTests.swift` | 5 | 真实断言（四类映射逐字、.game 为 nil、五分类恰好四个有值、拼写与接口一致、与 ModProjectType.rawValue 同集合） |
| **合计** | **682** | 其中 2 条默认跳过 |

> **用例数的正确数法（2026-10-02 踩坑后补记）**
>
> ```bash
> grep -h 'func test' qwqTests/*.swift | wc -l
> ```
>
> 两个会让数字虚高的坑，都实际踩过：
> 1. **`grep -r qwqTests/` 会把本文件自己算进去** —— TESTING.md 在 `qwqTests/` 目录下，
>    而正文里有 `func test…` 的代码示例，于是"文中的示例"被当成真实用例；
> 2. **编辑工具可能在 `qwqTests/` 下留隐藏的 `.xxx.tmpdir/` 备份**
>    （内含 `<文件名>.swift.tmp` 副本），`-r` 一样会命中。
>
> 实测一次：逐文件求和 **457**、`grep -r` 全目录 **488**，差 31 = TESTING.md 的 3 + 两个 tmpdir 的 28。
> ⇒ 数用例**只数 `*.swift`**，并在数之前确认目录里没有隐藏 tmpdir。
> 上表逐行数字之和即总数，可交叉验证。

> **本次实测口径（含提交锚点，便于复核）**
>
> ```text
> Executed 268 tests, with 2 tests skipped and 0 failures
> ** TEST EXECUTE SUCCEEDED **
> Commit: <待提交（本轮 LauncherSettings 转发层收敛，LaunchPanelStateTests 11→12）>
> Date:   2026-09-25
> Branch: refactor/modular
> ```
>
> ⚠️ **2026-10-01 变更（净减 21 条）**：提交 `cdf9dee` 删除两个**为不存在之物而写**的测试文件：
> - `ModuleRegistryTests.swift`（13 条）—— 测的是生产中零调用方的模块注册表（`ModuleContext` 体系整体删除，见 `ARCHITECTURE.md` §三）
> - `DownloadMergerTests.swift`（8 条）—— 该文件自认「`DownloadMerger` 只有协议声明，工程内尚无默认实现」，
>   故自定义测试替身 `OffsetOrderingMerger` 再测该替身
>
> ✅ **2026-10-02 实测（本条覆盖此前基于推算的 247）**：提交 `b73df40` 新增
> `GameSessionStoreTests`（6 条）后，本地 `./scripts/verify-test.sh run` 结果：
>
> ```text
> 22 / 22 个 suite 全部执行
> 总用例 253 = passed 250 + 按设计跳过 2 + 因工具链 abort 未重跑 1
> 断言失败 0
> ```
>
> **口径说明（不要直接抄日志里的 `Executed N tests`）**：本次运行中途在
> `LaunchCancellationTests.testUncancelledTokenPassesEntryGate` 处 abort 并重启
> （即下方那条概率性缺陷），**重启后该 suite 报 `Executed 0 tests`**；
> 而末尾的 `Executed 101 tests` 只是**最后一次 launch** 的汇总，不是总数。
> 上面的 253 由「逐 suite 的 `Executed` 行求和 + 补回崩溃前已完成项」得到，
> 并用日志中 `Test Case … passed` 的**独立计数交叉验证**（250 条，与 253−2−1 吻合）。
> `** TEST EXECUTE FAILED **` 的成因是 abort 与 logarchive 收集失败，**不是断言失败**。
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
> - `254 → 267`：新增 `AccountPersistenceCompatTests`（13 条）。**③ `AnyAccount` 模型分层的前置用例**：
>   把当前持久化契约（`@CodableAppStorage("accounts")` / `("accountId")` 的磁盘 JSON 形状、
>   `.microsoft` / `.yggdrasil` 的历史兼容解码、`==` 只比 `id` 的等值语义、`id` 随机 vs `uuid` 可复现）
>   钉成可执行断言，这样下一步动模型时「改了什么」会被用例立刻拦住。详见 §4.18。
> - `267 → 268`：`LaunchPanelStateTests` 补**持久化字段那一段链路**的透传用例（11 条 → 12 条，净 +1）：
>   `LauncherSettings` 收敛为 `AppSettingsStore` 的转发层后，这些字段在兼容层里已**不是 `@Published`**，
>   通知只能靠一条桥接订阅转发。该用例分三段分别证伪：① 绕过兼容层直写存储点 → 兼容层应收到
>   **1 次**通知（只有桥接能产生它）；② 经兼容层写 → 应发出 **1 次**通知；③ 写入哨兵值 → 值必须
>   真的落到存储点（同值写回会让断言恒真，故必须用哨兵 + `defer` 还原）。反向验证：摘桥接 → 2 红、
>   停转发 → 2 红，均只红在本用例内。**这个用例本身修过一次假绿**（初版只查「收到通知」，
>   桥接摘掉后仍绿），过程记在 `CHANGELOG.md` 同名条目里。
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

### 4.7 `DownloadMerger` 的真实实现 —— **已随删除闭合（2026-10-01）**

- `DownloadMerger` / `DownloadSliceStore` / `DownloadScheduler` / `DownloadTask` 都是
  **只有协议声明、零实现、零调用**的文件，已于 `cdf9dee` 整体删除，`DownloadMergerTests.swift` 一并删除。
- 结论：它从来不是「覆盖率缺口」，而是**为不存在的实现预留的抽象**。真实合并逻辑一直在
  `SLCore/Download/NetMerger.swift`，由 `SLCore/Download/` 侧自己的测试覆盖。
- 教训：不要提交「先定协议、实现待补」的文件 —— 它们会长期留在树里冒充架构，
  还会牵出一整套测试替身来测这个空壳。

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

### 4.11 `JavaModule` 的注册结果 —— **已随删除闭合（2026-10-01）**

`JavaModule` 与整个 `ModuleContext` / `SLModule` 体系已于 `cdf9dee` 删除。
原缺口（「注册结果无法有效断言」）不再存在，因为**没有任何调用方从上下文取能力**。
`JavaResolver` / `JavaRepository` 本身保留并由 `JavaResolverBridgeTests` 覆盖。

### 4.12 `ModuleRegistry` 的并发安全 —— **已随删除闭合（2026-10-01）**

`ModuleRegistry.register(_:)` / `ModuleContext.values` 连同其「未加锁、假定装配期单线程」
的隐患一并删除。无需再讨论其并发约定。

### 4.13 CI —— **已落地（2026-10-01）**

- `.github/workflows/test.yml`：push / PR / 手动触发，跑 `./scripts/verify-test.sh run`
  （真实 `xcodebuild` build-for-testing + test-without-building），失败时上传 `/tmp/sl_test.log`。
- 不跑 `scripts/typecheck.sh`：它依赖 `/tmp/deps` 里由**上一次真实构建**产出的第三方
  `.swiftmodule`，CI 是干净环境。该脚本的定位始终是**本地即时反馈**。
- **用例数自此以 CI 为准，不再手写进文档与提交信息。**
- 未做：覆盖率门禁。

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

### 4.18 账号持久化兼容契约（`AnyAccount` 模型分层前置，2026-09-25 落地）

**背景**：`AccountManager` 通过 `@CodableAppStorage("accounts")` / `("accountId")` 把账号
以 **JSON** 落在 `UserDefaults`。落盘格式**不是手写的解析器**，而是 Swift 为「带关联值的 enum」
与「合成的 Codable 类」自动生成的形状 —— 由 case 名、声明顺序和字段集合决定。
任何一次「模型分层」重构（拆 struct、改 case 名、增删字段）都会**静默**改变磁盘字节，
让用户既有账号数据解码失败（UI 表现为「账号没了」）。

**本文件在动模型之前先把当前形状钉死**，覆盖两个方向：
- **读方向（真正的兼容性）**：按**历史字面量**硬写的 JSON 必须仍能解码，且字段值正确。
  硬编码 `[{"offline":{"_0":{"id":…,"uuid":…,"name":…}}}]`，不是由被测代码现编出来
  （否则重构时编码器与解码器一起改就会「自洽地」通过）。
- **写方向**：当前编码器必须仍产出同一形状（只比**结构/键集合**，不比字符串 ——
  实测合成 Codable 的键序不稳定：数组形态 `id,uuid,name`、单值形态 `uuid,name,id`）。

**覆盖的性质**（13 条，1 条 `XCTSkip` 跳过）：
1. 历史 `.offline` 数据仍能解码，`id` / `uuid` / `name` 逐字保留；
2. `.microsoft` / `.yggdrasil` 这两个**只为兼容历史而保留**的 case 仍能解码，
   且解出来仍会自报未实现（不被静默当成已实现）；
3. **未知 case 必须报错**，不得被兜底成 `.offline`（防静默降级）；
4. 不存在第二种历史形状（扁平字典格式解不出来 → 不该加兼容解码）；
5. 当前编码器仍产出「合成形状」（case 名键 → `_0` → `{id,uuid,name}`）；
6. 三种 case 往返后字段逐一保留且 case 不被换掉；
7. `CodableAppStorage` 包装器机制：写盘 → `JSONDecoder` 读回 → 包装器读回，三者形状一致；
8. 包装器无数据时回落到默认值、每次读都问存储（不缓存）；
9. `accountId` 的落盘形状：裸 UUID 字符串 / `null`；
10. `==` 只比 `id`，**不看 case**（同名 payload 的 `.offline` 与 `.microsoft` 相等）；
11. `id` 随机（每次新建不同）vs `uuid` 可复现（同名同 uuid）+ RFC 4122 合法性（version=3, variant=9）；
12. **安全护栏**：用例操作后断言真实 `accounts` / `accountId` 键逐字节未变（测试宿主 = qwq.app，
    `UserDefaults.standard` 是用户真实偏好域）；
13. **活体校验**（`XCTSkip`）：本机若真有账号数据，它必须仍能被解码。

**未覆盖（有意）**：`AccountManager.shared.getAccount()` 的 `accountId == nil` 回写分支
**本轮不测** —— 它会写真实 `UserDefaults`。要安全地测它，得先给 `CodableAppStorage` 注入
`UserDefaults` 实例（属模型分层那一轮的范围）。

**反向验证**（三条变异，各精确命中、无误伤）：
- R1（给 `OfflineAccount` 加 `CodingKeys` 把 `uuid` 映射到 `uniqueId`）：3 红
  （读方向 ×2 + 写方向 ×1）；
- R2（`==` 改成区分 case）：2 红（`testEqualityIsByIDOnlyAndIgnoresKind`）；
- R3（`.microsoft` 的 `unimplementedError` 返回 `nil`）：2 红
  （`testLegacyUnimplementedKindsStillDecodeAndSelfReport` + `testRoundTripPreservesIdentityFieldsAndKind`）。
  三条变异后均逐字节还原（md5 一致），零残留标记。

### 4.19 `InMemoryGameSessionStore` 的三处缺陷（**已定位并修复**，2026-10-02）

**背景**：该类型此前带 `@available(*, deprecated, message: "全库无引用，待清理")`。
读实现后确认它不是「死代码」而是**带缺陷的代码**，且缺陷都命中 T8/T9 那条迁移路径上要依赖的语义。
基准取自**同库既有实现** `Core/Download/Adapters/NetDownloaderDownloadEngine.swift`
（数组承载多订阅者、`lastState` 回放、终态 `finish()`），即正确做法本项目自己写过。

| # | 缺陷 | 位置 | 后果 |
|---|---|---|---|
| 1 | `continuations[UUID: Continuation]` 单个而非集合 | 原 `observe` | 第二次 `observe` **覆盖**第一个 → 先订阅者收不到任何事件且永不结束 |
| 2 | 终态只 `yield` 不 `finish()` | 原 `update` | `for await` 永不退出；continuation 留在台账里泄漏。**违反协议本文档第 34 行**「流结束时自动清理订阅」 |
| 3 | 无 `lastState` 回放 | 原 `observe` | 订阅前发生的状态全部丢失 —— 与文件头 T8/T9 同源 |

**取证方式**：本机 xcodebuild 不可用（嵌套沙箱），故先写**独立 swiftc 探针**复刻原逻辑，
可执行地复现三处缺陷（先订阅者收到 `[]`、两个流都不结束、终态后残留 1 个 continuation、
晚订阅者首事件 `nil`），并带**反向对照**（照 `NetDownloaderDownloadEngine` 写法 → 两个订阅者都收全、
都结束、0 泄漏）。修复后再用探针跑全部用例判断逻辑：**15/15 通过**。

**⚠️ 探针的边界（本轮实际踩到）**：探针用 `NSLock` + 多语句闭包，照不出**类型错误**；
真实源码用 `OSAllocatedUnfairLock`，`onTermination` 闭包隐式返回 `removeValue(forKey:)` 的
`Continuation?` 与签名的 `Void` 冲突，**`swiftc -typecheck` 当场报错**。
⇒ 语义由探针验、可编译性由 typecheck 验，**两个关口都要过**，不能用一个替另一个。

**反向验证（三项变异，各精确命中）**：
- 把 `continuations` 改回单个 → `testAllObserversReceiveUpdates` 红；
- 摘掉终态的 `finish()` → `testTerminalFinishesStream` + `testFailedStateAlsoFinishesStream` 红；
- 摘掉回放 → `testLateObserverSeesCurrentState` + `testLateObserverAfterTerminalGetsTerminalThenEnds` 红。

**同轮移除**：该类型上的 `@available(*, deprecated, "全库无引用，待清理")` 标注。
加入测试后「全库无引用」不再成立；其真实状态是**待接线**（受 `MinecraftInstanceLaunchService`
文件头的 T1/T2/T8/T9 阻塞，其中 T2 未解决前接线只会写进一个没人订阅的表）。

### 4.20 `ArtifactVersionMapper` 的 11 条用例，与一份「现在就能测」的普查清单（2026-10-02）

**为什么先测它**：它是 Apple Silicon 兼容适配 —— 出错的表现不是崩溃，而是**游戏起不来**
（缺 arm64 natives → 启动后 `UnsatisfiedLinkError`），且它此前 0 测试触达、有 fix 历史。
`map()` 是纯输入→输出，依赖只有 `ClientManifest`（可经**公开**入口 `parse(url:)` 由临时文件构造）
与 `Util.toPath`（纯函数），所以**加测试不需要改一行生产代码**。

覆盖方式：逐条对应源码的 `switch` 分支，而不是只测 happy path。
夹具用 `natives.osx` + `downloads.classifiers` 组合来区分「普通库 / natives 库」
（`Library.isNativeLibrary` 的判定入口就是这个组合）。另外钉住两条**源码注释里自认的**性质：
幂等性「恰好成立」、`artifact == nil` 时可选链空转不崩。

#### 判据 D 的前后对比（2026-10-02 补记）

本轮补测后**重算**了判据 D（口径：生产文件内**所有**顶层类型名都未在测试文本中出现 = 零触达；
只统计 `qwqTests/*.swift`，不含本文件自身）：

| 时点 | 文件零触达 | 行数零触达 |
| --- | --- | --- |
| 会话开始（`f3ca5a5`） | 163 / 251 = **64%** | 20,849 / 31,559 = **66%** |
| 当前（本轮补测后） | 110 / 234 = **47%** | 16,109 / 30,752 = **52%** |

⚠️ 两点口径说明：
1. 会话开始那一列的分母是 **251** 文件（本轮**删除**了 17 个零消费方文件，见 `cdf9dee`），
   所以两列的分子分母都不同 —— 这是「一边补测试一边删死代码」的合并效果，不是单纯的补测收益；
2. 该指标是**类型名提及**的**上界**，会**低估**覆盖：例如
   `Features/ModBrowser/Module/ModSearchRequest.swift` 已被 `ModSearchRequestTests`
   覆盖，但测试里用的是 `nextPage()` / `ModSearchRequest` 的方法与字面量，
   某些文件的类型名仍可能不出现在测试文本里（`ClientManifestArguments.swift` 就是这种情况，
   它的类型是嵌套的 `ClientManifest.Arguments`，测试里写的是 `manifest.getArguments()`）。

#### 配套：零测试触达文件的「可测性普查」

判据 D 显示 **172/234 个生产文件（73%）从未被测试提及**（按行数 23,161/30,752 = 75%）。
但「没测」不等于「不能测」——把可测性按「是否依赖单例 / 文件IO / 网络 / 进程 / AppKit / SwiftUI」分档后：

| 档 | 含义 | 规模 |
| --- | --- | --- |
| **A** | **零硬依赖 ⇒ 现在就能测**（加测试不改生产代码） | **47 个文件 / 3,538 行** |
| B | 只依赖文件IO/网络/进程/UI ⇒ 通常可注入，但需要开缝 | 其余 |
| C | 抓 `static let shared` 单例 ⇒ 开缝 = 改行为，须先有别的测试兜着 | 其余 |

**A 档是当前性价比最高的施力点**。A 档内按「fix 历史 × 行数」排序的优先项（已完成的划掉）：

- ~~`Features/Launch/GameSessionStore.swift`（133 行，fix×2）~~ → §4.19，已完成
- ~~`SLCore/Minecraft/Download/ArtifactVersionMapper.swift`（159 行，fix×1）~~ → 本节，已完成
- ~~`SLCore/Minecraft/ClientManifestArguments.swift`（125 行，fix×1）~~ → 已完成（14 条，见文件清单）
- ~~`SLCore/Minecraft/ClientManifestRule.swift`（92 行）~~ → 已完成（12 条）
- ~~`SLCore/Utils/PropertiesParser.swift`（81 行）~~ → 已完成（21 条）
- ~~`SLCore/Minecraft/AssetIndex.swift`（76 行）~~ → 已完成（13 条）
- ~~`Features/Skin/OfflineUsernameValidator.swift`（23 行）~~ → 已完成（10 条）
- ~~`Features/Game/GameVersionHelper.swift`（57 行）~~ → 已完成（23 条）
- ~~`Features/Download/ModpackVersionGrouping.swift`（31 行）~~ → 已完成（8 条）
- ~~`SLCore/Download/NetDownloadState.swift`（147 行，fix×1）~~ → 已完成（25 条）
- ~~`Features/Game/DetailVersionDecision.swift`（54 行）~~ → 已完成（19 条）
- ~~`Features/ModBrowser/ModLoader.swift` + `Features/Download/LoaderNameResolver.swift`~~ → 已完成（19 条）
- `Features/Launch/LauncherError.swift`（52 行，fix×1，**已评估为差目标**：7 个 case 里 5 个是死枚举、live 的只是中文文案映射，测它是镜像测试）
- `Services/DragDropHandler.swift`（61 行，fix×1）
- `App/CrashReporter.swift`（198 行，fix×1，走信号路径，改动前先读 `signal-handler-alloc-audit`）

> ⚠️ **该普查是粗筛，不是结论**，且它出过两次错，都已修正 —— 记录在此以避免重犯：
>
> 1. **单位错（最严重）**：初版把「文件内**任一**类型未被提及」当作零触达，
>    于是 `Features/Skin/Module/SkinDecoder.swift`（被 `SkinDecoderTests` 覆盖）也被算进去。
>    正确口径是「文件内**所有**类型都未被提及」。修正后零触达数由 162 升到 **172**
>    —— 即**问题比初版报的更严重**，不是更轻。
> 2. **同名类型归属错**：中途改用「全局 `类型名→文件` 映射」，同名类型只归属第一个文件，
>    使「类型名被别的文件顶掉」的文件被误判零触达（172→173 那次）。
>    正确写法是**逐文件收集自己的类型名**，不做全局去重。
>
> 另有两个已知口径边界：**27 个文件没有顶层类型声明**（纯 extension 文件），按定义计入零触达，
> 但它们可能被间接覆盖；**同名文件/类型跨目录**时按完整路径区分。
>
> ⚠️ 即便归入 A 档，挑中后仍须**读源码确认真的可测**（粗筛曾把
> `MinecraftInstanceLaunchService.swift`（401 行）标成 A 档，实际需要真实 `MinecraftLauncher`）。
> 判据 D 的下降只能靠**逐个文件读完再写**。

### 4.21 `ArtifactVersionMapper` 的 LWJGL 3.3.3 守卫是**死代码**（2026-10-02 首轮实测抓到，**待决策**）

**怎么发现的**：`ArtifactVersionMapperTests` 首轮实跑 290 条、**4 条断言失败**。
其中 2 条是本套件**自己的夹具错误**（见本节末），另 1 条用例（2 处断言）是**真缺陷**。

**缺陷**：`.arm64` 分支的 natives 循环里，`!= 3.3.3` 守卫只拦得住 `changeVersion`，
紧随其后的一行却把版本**硬写成常量**：

```swift
if library.version.starts(with: "3.") && library.version != lwjglNativeArm64Version {
    changeVersion(library, lwjglPinnedVersion)      // 守卫只拦得住这一行
}
library.name = "org.lwjgl:\(library.artifactId):\(lwjglPinnedVersion):natives-macos-arm64"
//                                ^^^^^^^^^^^^^^^^^^ 硬编码常量 ⇒ 守卫被作废
// 下一行的 url 又用 library.version 拼接，而它已被上面这行重新推导成 3.3.2
```

**后果**：3.3.3 的 natives 仍被钉到 3.3.2；而**核心 jar 因另一个循环里同一个守卫保持 3.3.3**
⇒ core 与 natives **版本不一致**（LWJGL 的 natives 与 core 强耦合）。
`ArtifactVersionMapper.swift` 文件头也明说「对 **< 3.3.3** 的版本统一钉到 3.3.2」，
即 3.3.3 本不该被钉 —— **行为与自述矛盾**。

**可达性**：需同时满足「清单里有 natives 条目」且「LWJGL 版本 == 3.3.3」。
文件头指出多数现代版本走 `-cp` 本地库路径（`getNeededNatives().isEmpty` ⇒ 早退），
故属**潜在缺陷而非必然触发**，但可达。

**修法（一行）**：该行改用 `library.version` ——
`library.name = "org.lwjgl:\(library.artifactId):\(library.version):natives-macos-arm64"`
对 <3.3.3 无影响（`changeVersion` 已把 version 改成 3.3.2），**只影响 3.3.3 这一种输入**。

**当前处置**：**未改生产代码** —— 这是改游戏启动行为的变更，而本机没有端到端验证通道（跑不起游戏）。
用例 `testArm64DoesNotDowngradeLWJGL333` 按**预期行为**断言并用 `XCTExpectFailure` 标记：
修好后它会报 "expected failure did not occur" 而**变红**，提醒移除标记 —— 自清理，不靠人记。

**同轮修掉的 2 条夹具错误（本套件自己的错，非生产缺陷）**：
`.arm64` 分支开头有 `if manifest.getNeededNatives().isEmpty { return }` 的**早退**；
`testArm64UpgradesLegacyJNA` 与 `testArm64ReplacesObjcBridgeToMavenCentral` 的夹具里
**没有 natives 库**，于是整段替换逻辑根本没执行，「查不到改后的坐标」被误报成失败。
⇒ 已给两个夹具各加一个 natives 库，并在测试文件头写明这条坑：
**凡验证 `.arm64` 替换规则的夹具，必须至少含一个 natives 库。**

### 4.22 `CrashReporter` 的信号路径**并非零分配**：`gmtime_r` 惰性初始化（2026-10-02 实测并修复）

**背景**：`qwq/App/CrashReporter.swift` 的文件注释明确声称「现改为：路径在安装期 `strdup`，
三个缓冲全部走 `withUnsafeTemporaryAllocation`（栈上）」。但**「看起来没有分配」不算数** ——
必须能**被证明**。

**方法**（`DYLD_INTERPOSE` 拦截 `malloc` + 地板值对照）：
1. 拦截器发现 `/tmp/allocprobe/armed` 存在后才开始记录每次分配的大小；
   被测程序在 `raise()` 前一行创建该文件 ⇒ 计到的全部在信号路径内；
2. **地板值对照**：另编一个与 `CrashReporter` **同运行时**的探针
   （Swift + Foundation、同样 `install()` 信号处理器与 `NSSetUncaughtExceptionHandler`，
   但 handler 里**不写日志**）—— 它测到的是「Swift/Foundation + 信号投递」的地板值；
3. **阳性对照**：一个 handler 里故意用 `[CChar](repeating:)` 与字符串插值的版本，
   用来证明拦截器**确实能**测到分配（否则一串 0 可能只是探针坏了）。

**实测（每项 3 轮，结果完全稳定）**：

| 探针 | 信号路径内分配 |
| --- | --- |
| 纯 C（只 `signal`+`raise`） | 0 |
| Swift 地板（装 handler 但不写日志） | **0** |
| 阳性对照（故意分配） | 3（`[112, 16, 56]`） |
| `CrashReporter`（修复前） | **5**（`[1025, 41448, 18280, 1025, 41448]`） |

**归因**（逐个砍掉 `writeCrashLog` 的各段）：

| 变体 | 分配 |
| --- | --- |
| `writeCrashLog` 立刻返回 | 0 |
| 只 `writeLiteral` / 只 `writeSignalName` / 只 `writeInt` / 只 `backtrace` 块 | 全部 **0** |
| 只 `time(nil)` | 0 |
| 只 `tm()` | 0 |
| **只 `gmtime_r`** | **5** |
| 只 `writeTime` | 0 |

⇒ **5 次分配全部来自 `gmtime_r` 的首次调用**（libc 惰性初始化时区数据）。
反向验证：先在非信号上下文调一次 `gmtime_r` 再崩溃 ⇒ **0 次**。

**为什么这是真问题**：全库唯一的 `gmtime_r` 调用就在本文件的 `writeCrashLog` 里，
而实测 **`DateFormatter` 与 `ISO8601DateFormatter` 不会预热它**
（走 ICU、不碰 libc 时区表；调用后信号路径仍是 5 次）。
⇒ App 正常启动流程下，**第一次崩溃**就会在信号处理器里触发这 5 次堆分配 ——
正是本文件要消除的自死锁风险（崩溃点若在 malloc 内部，信号处理器再进 malloc 会死锁，
日志静默写不出来）。

**修复**：在 `install()`（非信号上下文）里预热一次 `gmtime_r`。

**修复后实测**：**0 次**（3 轮稳定），且崩溃日志仍正常写出
（804 字节，含 `signal:` / `time(UTC):` / 带符号的完整 backtrace）。

**留下的教训**：POSIX 的 async-signal-safe 清单把 `gmtime_r` 列为安全，
但「清单在列」不等于「实现不分配」—— **这类结论只能实测，不能靠查表**。

### 4.23 `LocalModCatalog` 的「省 75 MB」偏乐观：复测为约 50 MB（2026-10-02）

**被复核的声称**（`qwq/Features/ModBrowser/LocalModCatalog.swift` 注释，122477 条真实目录数据）：

| 策略 | 原记录 | 本轮复测（同机同数据，各 3 轮独立进程） |
| --- | --- | --- |
| `JSONSerialization` + 手工搬运 | 249.6 MB | 250.7 / 250.3 / **249.6** MB ⇒ **精确吻合** |
| `JSONDecoder` 直解（现实现） | 174.4 MB | 196.0 / 202.8 / 199.7 MB ⇒ **高约 25 MB** |
| 净省 | 75 MB（30%） | **约 50 MB（约 20%）** |

**结论不变的部分**：换 `JSONDecoder` 确实省内存（方向正确），耗时同量级
（0.41 s vs 0.38 s），解析结果一致（122477 条、首末条 title 相同）。
**需要修正的部分**：省下的量被**说重了约 10 个百分点**，而那个数字正是用来支撑
「本实现更好」的论据。

**方法**（可复跑）：
1. `gunzip -c qwq/modrinth_catalog.json.gz > catalog.json`（37,167,460 字节、122477 条）；
2. 两种策略各编成**独立可执行文件**，各跑 3 轮 —— **峰值 RSS 是进程级累积量，
   同进程内先后跑两种策略会互相污染**；
3. 用 `getrusage(RUSAGE_SELF).ru_maxrss` 取峰值（macOS 单位是**字节**，Linux 是 KB）；
4. 基线（仅把 37 MB 原始 JSON 读进 `Data`）为 **37.9 MB**，故比较按**净增**做。

⚠️ 口径边界：RSS 峰值含 `Data` 缓冲与运行时开销，且受分配器行为与系统版本影响；
本复测只说明「原记录的新实现数字偏乐观」，不声称 199.5 MB 是普适值。

**处置**：**没有覆盖原记录**，而是在源码注释里追加了一条带日期的复测注记 ——
原记录是当时环境的实测证据，直接改写会抹掉它；两版数字并存，差异与复测方法都写明。

## 五、必须遵守：用例一律写成 `async`（Xcode 26.2 隔离析构缺陷）

**结论**：`qwqTests` 里**每个 `test…()` 方法都必须写成 `async`**。这不是为了等待什么，
而是为了躲开一条会把整个测试进程打死的工具链缺陷。当前 **25** 个测试文件、**290** 个用例已全部统一
（2026-10-02 实测：`Executed 290 tests, with 2 tests skipped and 4 failures` —— 那 4 条是
`ArtifactVersionMapperTests` 首轮暴露的问题，其中 2 条为本套件夹具错误、1 条为真缺陷见 §4.21，
均已处置；最后一次**全绿**实测为 2026-09-25 的 `Executed 268 tests, with 2 tests skipped and 0 failures`。
**用例数以 CI 为准**，新增测试文件时不必再手工同步上面的数字）。

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
