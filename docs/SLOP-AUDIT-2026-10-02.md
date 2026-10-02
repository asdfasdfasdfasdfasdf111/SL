# 屎山审计：Swim111Launcher（2026-10-02 并行全库扫描）

> **本文回答**：这个项目为什么是屎山？——不评价风格，只报**可复现数字** +
> **项目自己写下的规则被自己违反** 两张表。任何人重跑命令得到同一输出。
> 取证阶段只读，未改一行代码。HEAD：`7fec44a`，分支 `refactor/cleanup-dead-modules`。
> 审计方法：12 组并行子代理 + 主代理逐条 grep 复核（子代理报告只当线索，本文每条都回原文核对过）。

---

## 0. 结论（含推翻条件）

**在 A/B/C/D 四条判据下，本项目达到「屎山」水平**：

- **A 耦合度**：25 个单例，230 处调用，**161 处跨模块（70%）**，且存在**分层倒置**（SLCore 直连 Features 单例 6 处、Features 反向直连 App 层 AppContext 24 处）。
- **B 冗余度**：≥5 组"同一能力两套实现"（loader→资源名映射 ×2、unzip ×2、userAgent ×7、弹窗骨架 ×2、下载双轨）。
- **C 收敛性**：**净交付 = 0** —— `LaunchPreflight` 协议族（4 协议 + 默认实现）生产**零消费方**；`ModpackDownloader` 三条 public API 构成死链；`GameSessionStore`/`GameProcessController.terminate` 自证"待接线"。
- **D 测试覆盖面**：709 用例 / 55 文件，但**51% 生产文件（60% 行）零触达**——UI 层 100% 零触达、App 核心（ContentView/AppContext/CrashReporter）100% 零触达、DataManager/LogManager/CacheManager 零触达。

**推翻条件**（任一成立即撤回结论）：
1. 判据 A：跨模块单例调用可复现数 < 161 处，或分层倒置 = 0 处；
2. 判据 B：`ModLoader.assetName` 与 `LoaderNameResolver.assetMap` 只存在一份数据源；
3. 判据 C：`LaunchPreflight` 在生产出现任一构造点（`DefaultLaunchPreflight(`），或 `ModpackDownloader.search/downloadLatest/downloadFirst` 出现任一外部调用方；
4. 判据 D：生产文件零触达降为 0%。

---

## 1. 判据 A 耦合度（跨层单例调用）

### 1.1 数字（主代理实测）

```bash
grep -rn 'static let shared' qwq --include=*.swift | grep -v '//' | wc -l   # 25 处声明
# 修正口径（python 逐调用点正则匹配、跳过 // 注释行）：
# 非注释 .shared 调用 230 次，其中跨模块 161 次 = 70%
# ⚠️ 行口径会略大于次口径（ContentView.swift:60 一行含 2 个单例），引用时写明单位
```

### 1.2 分层倒置（底层反向依赖上层，方向错误）

| 位置 | 方向 | 证据 |
|---|---|---|
| `SLCore/SLLaunchBridge.swift:337,381,385` | **SLCore → Features/Java** | `JavaManager.shared.preScanJavaAsync()` / `.scanInstalledJava` / `.selectBestJava` |
| `SLCore/SLLaunchBridge.swift:379,382,394` | **SLCore → Features/Settings** | `LauncherSettings.shared.availableJavaList` |
| `Features/*` 24 处 | **Features → App 层** | `AppContext.shared` 被 Skin/ModBrowser/Translation/Java/Game/Download 六模块调用（SkinResourcePackApplier:153,167、ModrinthCategoryCache:92,107、SearchTranslator:31、JavaManager:9、VersionUtils:125,156、ModpackInstaller:153,162,212 等） |

**自证**：`ARCHITECTURE.md:55` 自己承认「底层 SLCore 反向直连上层 Features 的 JavaManager / LauncherSettings 各 3 处」——**项目自己知道自己违反分层**，且尚未修。

**反证**：`ARCHITECTURE.md:17` 声称 `qwq/App/` = 应用入口/装配根/导航状态，`AppContext` 是「进程级基础设施」（:51）——基础设施被放在 App 层目录里，导致 Features 层向上依赖 App 层。

### 1.3 依赖注入声称 vs 实际

- `ARCHITECTURE.md:26`：「本项目**不用** DI 容器。跨模块取用依赖的统一写法是构造器默认参数」。
- `qwq/App/AppContext.swift:3`：「统一应用上下文（**依赖注入容器**，替代散落的单例）」——**同一工程、自定规则被自己代码注释打脸**。
- 且大量调用点绕开构造器默认参数直接取 `.shared`：`ModFileDownloadStarter.swift:54` 签名收了 `settings: LauncherSettings` 参数、内部却用 `LauncherSettings.shared.selectedGameRoot`（同一函数两套取数方式）。

---

## 2. 判据 B 冗余度（同一能力几套实现）

| # | 能力 | 并存实现 | 证据 |
|---|---|---|---|
| 1 | 加载器→资源名映射 | `ModLoader.assetName`（ModBrowser/ModLoader.swift:29-38）**逐字等价于** `LoaderNameResolver.assetMap`（Download/LoaderNameResolver.swift:8-11） | 两处维护 fabric/forge/neoforge/quilt/rift→图标名 |
| 2 | ZIP 解压 | `ModpackInstaller.unzip`（Features/Download/ModpackInstaller.swift:83）**复制** `Util.unzip`（SLCore/Utils/Util.swift:130） | 注释自称「同 Util.unzip」但实现是另一份 |
| 3 | User-Agent 串 | `"Swim111Launcher/1.0 (Minecraft Launcher)"` 硬编码 **7 处** | ModDownloader:84、ModrinthSearcher:38、SearchTranslator:29、TranslationSourceFetcher:56,92、ModpackDownloader:65、LoaderSupportProbe:153 |
| 4 | 弹窗骨架 | `ModInstallSelectionView` 与 `ModpackFolderPickerView` 同源自 `ModInstallViews.swift`，脚手架（标题/Divider/按钮/入场动画）逐段复制 | 两个弹窗 34-192 行与 32-169 行结构同构 |
| 5 | 下载引擎 | 双轨：`SLCore/Download/` 旧引擎（17 文件 1983 行）vs `Core/Download/` 新门面（10 文件 1037 行） | ARCHITECTURE.md §六自认「双轨且这是有意的」，但同节又自认「绕过引擎直连 URLSession 的路径尚未接入」 |

**自证**：`ModpackDownloader.swift:124-125` 注释自认「downloadLatest 与 resolveFile 都依赖它，两者连续调用会产生两次相同请求」——同一个类内已知重复请求而不合并。

---

## 3. 判据 C 收敛性（新代码替换旧的，还是叠加？）

### 3.1 修正口径的悬空类型

按「顶层非 private 类型 + 全库（生产+测试）出现 ≤1 次」修正口径（吸取历次审计教训）：
- 313 个顶层类型中，**真悬空 2 个**：`ThemeDefinition`（Features/Theme/ThemeDefinition.swift，全库仅声明行 1 次）、`ContentView_Previews`（SwiftUI 自动生成，非缺陷）。
- 半悬空（出现 2~4 次）133 个——多数是「声明 + 1 处消费」，需逐个读源码才能定性，本文只定性了下面的重点对象。

### 3.2 三段漏斗：声明 → 登记 → 消费（净交付 = 0 的实证）

**`LaunchPreflight` 协议族（Features/Launch/LaunchPreflight.swift:116-147）**：

```
① 声明：4 个协议（ClientFileVerifier/LibraryFileVerifier/AssetFileVerifier/NativeInstaller）
        + 默认实现 DefaultLaunchPreflight（:147） + LaunchPreflightContext
② 登记：无（生产零构造点，grep DefaultLaunchPreflight( 无命中）
③ 消费：无（连 qwqTests 都只有 LaunchStateTests.swift:180 的**注释**提及；LaunchPreflightTests 文件不存在）
```

`ARCHITECTURE.md §七` 声称「`LaunchPreflight`（client / library / asset / natives 四类校验拆分）」是已交付结构——**实际是一个从未接线的骨架**。

**`ModpackDownloader` 死链（Features/Download/ModpackDownloader.swift）**：
- `search(query:limit:)`（:86）→ `downloadLatest(packId:to:)`（:143）→ `downloadFirst(query:to:)`（:188）——三者互相调用成环，**生产/测试零外部调用**，无测试。一条「一键下载」public API 从未接线。

**自证待接线（项目自己的注释承认）**：
- `GameSessionStore.swift:46-53`：「**接线状态（2026-10-02）**：生产代码仍无构造点……本类型当前的状态是**待接线**」
- `GameProcessController.swift:36-40`：「**全库无引用，待清理**（含 qwqTests）……从未执行」
- `TemperatureDirectory.swift:23`：「那个导出功能本身还没接线，所以这条路径现在跑不到」
- `AppContext.swift:14` `downloadSession`（含 16MB 缓存配置）**全库仅声明行 1 次**，无消费者
- `AppContext.swift:52` `appSupportURL` 写而不读（声明+赋值后零读取）

### 3.3 收敛性自证违反

| 项目自己写的规则 | 实际 |
|---|---|
| `ARCHITECTURE.md:180`「不要继续维持**待接线**状态」 | 至少 4 处公开待接线骨架（§3.2），其中 GameSessionStore 的待接线状态**写进了 2026-10-02 的注释** |
| `ARCHITECTURE.md §三`（已删注册表）「删除即结论：判定该方案不适用于本项目」 | 注册表删了，**全局状态照样全网共享**：`DownloadDetailManager.shared` 被 App/Game/ModBrowser 三层跨层使用（NavigationState:65、GameViews:163、ModDetailView 系） |
| `ARCHITECTURE.md §六`「`DownloadEngine` 是对外**唯一入口**」 | `ModDownloader.swift:160,179,201,225` 直连 `URLSession.data/download`；`ModpackDownloader.swift:106,130,153` 同；同节 :118 自认「绕过引擎直连 URLSession 的路径尚未接入」——**"唯一"与"明知有例外"同节自相矛盾** |
| `ARCHITECTURE.md §九`「重构的验收标准是减法」「单文件头部注释不宜超过 15 行」 | App 层 5/13 文件头部注释 16~26 行超限；`CrashReporter.swift` 214 行里约一半是提交考古注释（违反「考古写进 docs/」） |

---

## 4. 判据 D 测试覆盖面（709 用例护住了多少运行代码）

### 4.1 数字（修正口径：类型名在测试文本出现 ≥1 次 = 触达）

```
生产文件 204（含顶层类型声明）/ 总行 26443
零触达文件 105 = 51% / 行 15865 = 60%
```

**与交接文档 §2 声称的「47% / 52%」不同**：交接文档口径是「文件内**所有**顶层类型名都未出现」，本文口径是「**任一**类型名出现即触达」（更宽松、触达数更多）。两口径方向一致——**过半生产文件从未被测试提及**。如实记录口径差，不当矛盾报。

### 4.2 零触达最严重处（按模块）

| 模块 | 零触达 | 说明 |
|---|---|---|
| UI/（VersionButton/TaskPill/ScrollBounceModifier/ViewComponents/Shell） | 5/5 = **100%** | 全部视图组件零测试 |
| App/（ContentView/AppContext/CrashReporter/AppDelegate/DebugAutoLaunch） | 5/5 = **100%** | **运行核心零触达** |
| Features/Theme | 1/1 = 100% | ThemeDefinition 悬空 |
| Services/（CacheManager/DragDropHandler） | 2/2 = 100% | |
| SLCore/DataManager + LogManager | 2/2 = 100% | 下载/启动主链依赖的全局状态零触达 |
| Features/Translation | 6/7 = 86% | |
| Features/Download | 11/16 = 69% | 死链 ModpackDownloader 在其中 |
| Features/Game | 15/23 = 65% | |

**对照**：Core/Download 10% 零触达、Features/Launch 39%、Features/Java 45%——测试能量确实集中在这几处，但**正是 App/ContentView、AppContext、DataManager、SLLaunchBridge 这些"什么都经过它们"的枢纽零触达**，导致"测试行数增长了，被保护的运行代码面积没怎么长"。

---

## 5. 自证表总览（项目自己写的规则 vs 实际）

| # | 规则出处 | 规则 | 实际 | 证据 |
|---|---|---|---|---|
| 1 | ARCHITECTURE.md:26 | 不用 DI 容器 | 代码自称 DI 容器 | AppContext.swift:3 |
| 2 | ARCHITECTURE.md:113 | DownloadEngine 唯一入口 | 直连 URLSession ≥7 处 | ModDownloader/ModpackDownloader |
| 3 | ARCHITECTURE.md:180 | 不要维持待接线 | ≥4 处待接线骨架 | §3.2 |
| 4 | ARCHITECTURE.md:144 | 当前 21 文件 / 250 用例 | **55 文件 / 709 用例** | 实测 |
| 5 | ARCHITECTURE.md:151 | 用例数不再手写进文档 | :144 自己写了 | 同上 |
| 6 | ARCHITECTURE.md:172 | 注释记录"为什么"，考古写 docs/ | CrashReporter 214 行半数为考古注释 | §3.3 |
| 7 | ARCHITECTURE.md:55 | （自认）SLCore 反向直连 Features 各 3 处 | 实测仍在，未收口 | SLLaunchBridge:337-394 |
| 8 | ARCHITECTURE.md:51 | AppContext 28 处真实使用 | 实测 Features 24 处 + App 层 0 处 | 判据 A |
| 9 | AppCompositionRoot.swift:3 | 一次性运行时装配集中在一处 | 实际装配点 2 处（+ AppContext.init 惰性触发） | App 层审计 |

---

## 6. 工程化配套（环境级证据）

| 项 | 状态 |
|---|---|
| 工作区根目录泄漏 `.o` 目标文件 | **4 个**（AppSettingsStore.o 103KB、ContentView.o 2.5MB、ThemeManager.o 158KB、stubs.o 11KB） |
| 源码副本目录 | `qwq 2026-05-30 15-51-29 2/` + `15-51-29.zip`（1.5MB）躺在根目录，污染所有 `find`/`grep` |
| git 历史泄漏 | 曾提交 `probe.yml` 的 tmpdir 备份文件（commit f15e971），后已删 |
| CI | `.github/workflows/test.yml` + `probe.yml` 存在，但**从未在 CI 上跑过**（本地无网络出口） |
| 代码风格工具 | 无 .swiftlint.yml / .swiftformat / .editorconfig |
| 提交数 | 271 个，含大量 refactor 提交（"清理"类提交 15+ 个） |

**副本污染量化**：若用裸 `find . -name '*.swift'` 会命中副本目录，计数失真——本文所有数字均已排除 `qwq 2026-05-30*`、`.zip`、`build*`。

---

## 7. 为什么它不会自己变好（机制，三级证据——推断段）

1. **治理手段 = 文档 + 测试，但验证通道与运行代码脱节**。709 用例集中在一批纯逻辑文件（判据 D：过半生产零触达），而 AppContext/ContentView/DataManager 这些枢纽零测试——**修它们只能靠真机（SL_DEBUG_AUTO_LAUNCH）**，单元测试护不住，回归靠人肉。
2. **重构以"拆分文件 + 加测试"的形式推进，回避了"去掉旧路径"**。每个 refactor 提交的验收标准是「净行数 ≤ 0 + 测试绿」，于是下载双轨、兼容层、未接线骨架全部**保留**——结构变好了，能力没收敛（判据 C 净交付 = 0）。
3. **每个功能迭代都留下第二套影子实现后"待接线"**。需求来了先写协议/骨架/适配器，接线条件不满足就永久待接线（LaunchPreflight 全家零消费是活证据）。「不要继续维持待接线」的规则写在文档里，但接线需要真机验证、真机验证不可信（环境沙箱历史），于是只能做**形式改动**——死循环。
4. **"唯一"声称靠文档维护，不靠编译保证**。每处"唯一入口"都有绕过路径（DownloadEngine 被 URLSession 绕过），编译器不拦——架构靠自觉。

---

## 8. 公允之处（先承认，再谈指控）

- 注释密度极高，且**大量"为什么"注释与代码一致**（如 `MemoryCacheReclaimer` 引用「`DownloadCategoryView` 上的那个方法已删除」属实；`AppSettingsStore` 唯一存储点经核实成立；窗口最小尺寸唯一来源成立）。
- 死代码已部分自登记（`getImageName` 双侧注释、CodingKeys 自纠注释），说明有主动维护意愿。
- 修过真缺陷（CrashReporter 5 次堆分配归零、GameLogWriter tab 断言修正、D1-D9 启动缺陷），且每条都配了防回归测试。
- 设置层收口（AppSettingsStore）是真实完成的结构性改进。

---

## 9. 交接文档 §8.2「别再清死代码（判据 C 已 1.9%）」核验

**结论：该条建议方向错误，不可信**。

1. **"1.9%"不可复现**：全仓库 grep "1.9%" 只命中交接文档自身一处（HANDOVER-SESSION-2026-10-02.md:220），TESTING.md / docs/ 无任何推导出处。按 skill「任何聚合数字都要能还原成哪几个文件相加」——还原不出来。
2. **判据 C 的真问题不是"死代码"，是"未接线骨架"**：修正口径实测悬空类型只有 2 个（死代码确实少），但 **LaunchPreflight 协议族、GameSessionStore、ModpackDownloader 死链**这些"结构已完成、功能未接线"的骨架才是大头——它们是**负资产**（代码量增加而能力不变），正是 skill 说的「不接线的骨架」。说"别再清死代码"等于放过这 4 处。
3. **自证打脸**：交接文档自己的 §3 唯一卡点就是「419 条新用例从未实测」——即"加了大量测试却没跑过"，与"别再做事"清单的口气矛盾。

---

## 10. 一句话收尾

> 我不评价代码风格。我只报四组可复现数字（A：230 处调用/161 跨模块；B：≥5 组双实现；
> C：LaunchPreflight 生产零消费；D：51% 文件零触达），再对照项目自己写下的 9 条规则——
> **规则是它自己定的，违反是它自己干的**。脚本与每条证据的 grep 命令都在上文，
> 你可以重跑核对；若谁能证明上述数字不成立，我立刻撤回结论。
