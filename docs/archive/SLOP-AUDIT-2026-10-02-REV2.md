> 🗄️ **本文已归档（2026-10-05）**：内容为 SLOP-AUDIT-2026-10-02-REV2.md 撰写时点的历史快照/审计记录，
> 其中的行号、计数、现状描述**可能已失效**，勿据此判断当前代码。现状请以
> `ARCHITECTURE.md` / `HANDOVER.md` / `README.md` 及代码本身为准。

# 屎山取证复核：SLOP-AUDIT 修订版（2026-10-02 晚）

> **本文回答**：外部取证报告《为什么这是一个「屎山」项目》（下称「原报告」）的
> 逐条只读复核结论 + 修正后的可复现数字。原报告自身声明「谁能证明任一组数字
> 不成立，我立刻撤回结论」——复核按原报告自述口径重跑，**触碰了其两条推翻条件**，
> 本文就地修正，不把错误数字带进文档库。
>
> 取证全程只读（未改任何代码；仅新增本文档）。HEAD：`242093e`，分支
> `refactor/cleanup-dead-modules`。所有命令在 macOS 终端可重跑，输出与本文一致。
>
> 与旧 `docs/SLOP-AUDIT-2026-10-02.md`（HEAD `7fec44a`，写于 30 余个整改提交之前）
> 的关系：旧文档的 A 判据报「25 单例 / 230 调用 / 161 跨模块（70%）」——其中
> **230 调用、25 单例**与本次实测吻合（229/25，口径微差），**161 跨模块（70%）**
> 与本次实测（89 跨模块，39%）不符，原因见 §2。旧文档 D 判据报「51% 文件零触达、
> UI 100%」同样与本次实测（37.4%/50%）不符，见 §4。**以本文为准。**

---

## 0. 结论（含修正后的推翻条件）

**结构性问题成立**：A 跨模块 39% 且有分层倒置；B 曾存在五组双实现（已收口四组，
剩 3 套 UA）；C 真悬空 2 个、真代码级自陈死物 2 处；D 近四成生产文件零触达、
UI 层过半零触达；自证表 8 条中多数成立（文档全面过期确凿）。

**但原报告的判定数字有两处系统性夸大，触碰其自身推翻条件**：

| 原报告数字 | 复核实测 | 判定 |
|---|---|---|
| C 判据「`全库无引用\|零调用方\|待接线\|未接线\|从未执行\|保留待清理` → **23 处非注释命中**」 | 6 模式全库（含 qwqTests）**共 18 行命中，其中 16 行是注释；真代码命中仅 2 行**（均为 `@available(*, deprecated, message:)` 注解字符串）。原报告代表命令（3 模式：全库无引用/零调用方/待接线）实测仅 **10 处**、全部为注释 | ❌ **撤回**：原报告推翻条件 3 自定「非注释命中 < 23 即撤回」→ 实测 2 < 23，按原规则撤回 |
| D 判据「生产 235 文件，零触达 **137 = 58.3%**，UI **83%**」 | 按原报告自述口径（文件声明的**所有**顶层类型名在测试文本零出现）重跑：生产 235 文件、零触达 **88 = 37.4%**；UI 12 文件零触达 **6 = 50%**。点名反例：原报告称 `TaskPill`/`NoticeOverlay`「全裸」，实际各出现在 1 个测试文件（`LaunchPanelStateTests`/`NoticeCenterTests`） | ❌ **撤回**：原报告推翻条件 2 自定「零触达 < 137 即撤回」→ 实测 88 < 137，按原规则撤回 |

**修正后的推翻条件**：（任一成立即撤回本文结论）
1. 判据 A：`static let shared` 声明数 ≠ 25，或非注释 `.shared` 调用 ≠ 229，或跨模块 ≠ 89（39%）；
2. 判据 C：`LaunchArgumentBuilder` 出现任一 conformer/实例化点；或真代码级自陈死物命中 > 2；
3. 判据 D：按 §4 口径重算零触达文件 ≠ 88；
4. 自证表：`ARCHITECTURE.md:148` 不再含「21 文件 / 250 用例」，或实测测试文件数 = 21。

---

## 1. 判据 0：环境（一级，全符）

```
ls -d build*            → 9 个并行构建目录（build / build_asan / … / build_verify）
git ls-files | wc -l    → 437
du -sh .                → 2.7G
```

原报告：「9 个并行构建目录、437 跟踪文件、2.7G、30+ 截图、三套备份、6 个自动化工具目录」。
复核：目录级数字全符；截图/备份明细未逐项清点（属杂物堆事实），方向成立。

---

## 2. 判据 A 耦合度（一级，比例全符、绝对数修正）

```
grep -rn "static let shared" qwq --include=*.swift | grep -v "//" | wc -l   → 25（排除注释后的声明行）
python3 逐行 census（排除注释行/URL/声明行）：调用 229 次；跨模块 89 = 39%
```

- **单例 25 个**（原报告 24，差在 `ThemeManager.swift:79` 的 `LauncherSettings.shared` 是否计入，边界口径）；
- **非注释 `.shared` 调用 229 次**（原报告 199，差 30，口径未明示；用其口径重跑无法得 199）；
- **跨模块 89 = 39%**（原报告 78 = 39%）——**比例完全一致**，核心结论成立；
- 旧文档「161 跨模块（70%）」不成立：70% 应为把「App/UI/Features → SLCore」全部计入的旧口径，本次按「声明模块 ≠ 调用模块」结算为 39%。

**倒置三处（全部逐行命中）**：
- SLCore → UI ×3：`SLCore/Notices/Hint.swift:32`、`SLCore/Notices/Popup.swift:73,89` 调 `NoticeCenter.shared`（声明于 `UI/Notices/NoticeCenter.swift:127`）；
- UI → Features ×4：`UI/Shell/RootOverlays.swift:81,83,88`、`UI/Shell/PopupCardScaffold.swift:49` 调 `ThemeManager.shared`（声明于 `Features/Settings/ThemeManager.swift:40`）；
- Features → App：`LaunchPanelState.shared`（声明于 `App/ViewModels/LaunchPanelState.swift:21`）被 21 处调用、跨 9 文件（原报告说 16 处/6 文件，实测 21 处/9 文件）。

---

## 3. 判据 B 冗余度（一级，全符）

```
grep -rn "func unzip" qwq --include=*.swift
  → 仅 Util.swift:130 一处（+ PostProcess 的 unzipNatives 是 natives 专用，不算第二实现）
grep -rn "qwq-Launcher\|userAgent\|SL启动器/" qwq --include=*.swift
```

- unzip 已收口 ✅；
- **UA 剩 3 套 + 1 个假邮箱** ✅：
  1. `SharedConstants.swift:48` — `"Swim111Launcher/1.0 (Minecraft Launcher)"`
  2. `LocalModCatalog.swift:193` — `"qwq-Launcher/1.0 (qwq@example.com)"`（**假邮箱**）
  3. `NetSliceFetcher.swift:79` — `"SL启动器/\(SharedConstants.shared.version)"`

---

## 4. 判据 C 收敛性（二级，结构性成立、数字修正）

**真悬空 2 个（成立）**：
- `ContentView_Previews`（`App/ContentView.swift:159`）——PreviewProvider 自动生成，原报告排除正确；
- `LaunchArgumentBuilder`（`Features/Launch/LaunchArgumentBuilder.swift:18`，`public protocol`）——全库出现 5 次：1 次定义（:18）+ 1 次本文件头注释（:2）+ 1 次 `GameProcessController.swift:101` 注释引用 + **2 次测试自认**（`LaunchStateTests.swift:9,175` 明写「`LaunchService`/`LaunchArgumentBuilder`/`GameProcessController` 均为纯协议，未覆盖」）；**0 conformer、0 实例化、0 调用点** ✅ 确认悬空。

**自陈死物（数字修正——原报告「23 处非注释命中」无法复现）**：

```
grep -rn '全库无引用\|零调用方\|待接线' qwq --include=*.swift          → 10 处，全为注释
grep -rn '全库无引用\|零调用方\|待接线\|未接线\|从未执行\|保留待清理' qwq qwqTests --include=*.swift → 18 行
剔除注释行（行内注释、///、//）后真代码命中：→ 2 行
  qwq/Features/ModBrowser/ModDownloader.swift:343        @available(*, deprecated, message: "全库无引用，待清理")
  qwq/Features/Launch/GameProcessController.swift:55     @available(*, deprecated, message: "全库无引用，待清理")
```

即：**注释级自陈 16 处**（`GameSessionStore`/`MinecraftCrashHandler`/`InstallProgress`/
`MinecraftInstanceConfig`/`LoaderSupportVersionRules`/`LauncherError` 等，均为 `///` 或 `//`），
**真代码级（可执行）自陈仅 2 处**。原报告把注释命中也计为「非注释命中」且总数虚增到 23。

> 口径提示：注释级自陈是**二级证据**（作者自己承认），本身仍成立——「项目自陈死代码/待接线
> 16 处注释 + 2 处注解」这个结论**不变**；变的是原报告把它包装成「23 处非注释命中」。
> 引原文的说法收敛为：**真悬空 2 + @available 注解 2 + 注释自陈 16**。

---

## 5. 判据 D 测试覆盖面（一级，方向成立、数字修正）

```
ls qwqTests/*.swift | wc -l                                → 55
grep -rc "func test" qwqTests/*.swift | awk -F: '{s+=$2} END {print s}' → 709
生产文件（含声明类型名）                                   → 235
按原报告口径（文件声明的所有顶层类型名在测试文本零出现）   → 零触达 88 文件 = 37.4%
其中 UI 12 文件 → 零触达 6 = 50%
```

- 55 文件 / 709 用例 ✅（与原报告一致）；
- **零触达 88 = 37.4%**（原报告 137 = 58.3% ——按原报告自述口径重跑得不出 137）；
- UI **6/12 = 50%**（原报告 83% —— 它点名「TaskPill、NoticeOverlay 全裸」与事实现矛盾：
  `TaskPill` 在 `qwqTests/LaunchPanelStateTests.swift`、`NoticeOverlay` 在 `qwqTests/NoticeCenterTests.swift`
  各出现 1 次；`AppContext`/`ContentView`/`SLLaunchBridge`/`ProcessPool` 亦在测试注释/字符串中被提及）；
- 方向结论仍成立：核心枢纽（`CrashReporter`/`DataManager`/`LogManager`/`MultiFileDownloader` 等）
  确为零触达，最容易被改坏的地方缺测试——**幅度修正、方向不变**；
- 原报告 1559 XCTAssert 未单独复核（属计数旁证，不影响判据）。

---

## 6. 自证表（最重，多数成立，一条夸大）

| # | 规则出处 | 复核结果 | 判定 |
|---|---|---|---|
| 1 | `ARCHITECTURE.md:148`「21 文件 / 250 用例」| 实测 **55 / 709** | ✅ 确凿过期 |
| 2 | `ARCHITECTURE.md:155`「用例数不再手写进文档」| `:148` 自己手写且过期 | ✅ 成立（与 #1 同源） |
| 3 | `ARCHITECTURE.md:3`「只描述当前真实存在」| 同上 | ✅ 成立 |
| 4 | `HANDOVER.md:20,74`「234 文件/30,493 行、21 文件/250 用例」| 235 文件 / **55 / 709** | ✅ 成立 |
| 5 | `REFACTOR_PLAN.md:164`「净行数应 ≤ 0」| `dee01ef` **+481/−222 = +259**；`c99c346` **+97/−96 = +1**（原报告称该提交「净 0」——实测 +1，非 0） | ✅ 数字全符（原文微瑕：「净 0」实为 +1） |
| 6 | `ARCHITECTURE.md:44`「不要引入容器、统一构造器默认参数」| 25 个单例照常 `.shared` 取用 | ✅ 成立 |
| 7 | `docs/MODULE-INVENTORY.md` 头部 | 自标「⚠️ 部分作废」且覆盖全文 | ✅ 成立 |
| 8 | `ARCHITECTURE.md:176`「头部注释不宜超过 15 行」| `GameProcessController.swift` 共 104 行、注释 51 行，其中文件头注释 11 行（:1-11）、竞态考古注释约 20 行集中在文件中部（:37-60）——原报告称「头部约 55 行（13 文件头 + 40 考古）」**夸大**：13/40 均非实测值，实为 11 行文件头 + 全文件 51 行注释 | ⚠️ 方向成立、数字夸大 |
| 9 | 9+ 份互引治理文档 | `docs/` 现存 13 份文档、头部互引 | ✅ 成立（文档数量级压倒代码） |

---

## 7. 机制闭环（三级推断，未证伪）

原报告 §7 的死亡螺旋推断（工具链不可信 → 只能做形式改动 → 接线永远「欠一步」
→ 以拆分+文档推进）**未被复核证伪**，且与 §6 自证表一致：
- CI（`test.yml`）自述从未真正跑过、「typecheck.sh 会漏整类错误」自述在挡；
- 本次复核恰好又发现两处「数字与原文不符」的审计文档案例（旧 SLOP-AUDIT 的 70%/161
  与本次 39%/89；原报告的 23 处/137 文件）——**连「记录自己有多乱」的文档，数字也在漂**。

---

## 8. 公允之处（复核后仍成立）

- 10-02 当天 P0→P4 全部落地，五组双实现收口四组、LaunchPreflight 接线、死链删除、
  AppContext 归位——**是真整改**（§6 #5 的数字即整改提交本身，+259 是接线新增实现的行数，
  不是空转）；
- 注释密度高且与代码事实一致（自陈到 `@available(*, deprecated)` 程度）；
- 709 个测试真实存在，修过真缺陷；
- **最大屎山证据 = 自我认知**：文档、审计、整改、再审计循环把项目埋住——本次复核
  是这一循环的最新回合。

---

## 9. 一句话收尾

> 复核结论：**骨架全中、两处数字夸大**。A 39% 跨模块（89/229）、B 三套 UA 含假邮箱、
> C 真悬空 2 + 真代码自陈 2 + 注释自陈 16、D 37.4% 文件零触达（88/235，UI 6/12）、
> 自证表 9 条中 7 条成立 1 条夸大——这些与项目自己立下的 8 条规则对照，规则是它自己
> 定的、违反是它自己干的、连违反记录也由它自己登记。原报告的两处夸大数字
> （C「23 处非注释」、D「137 文件/58.3%/UI 83%」）按它自己的推翻条件撤回，以本文为准。
>
> 复核命令全部保留在 §1–§6，可逐条重跑。

---

## 附：与旧审计文档的数字对照（避免后续接手者被三个版本搞混）

| 指标 | 旧 SLOP-AUDIT（`7fec44a`） | 原报告（HEAD `242093e` 自证） | 本次复核实测（HEAD `242093e`） |
|---|---|---|---|
| A 跨模块 | 161 = 70% | 78 = 39% | **89 = 39%** |
| C 自陈死物 | （未单列） | 23 处非注释 | **真代码 2 + 注释 16** |
| D 零触达文件 | 51%（约 120/235）、UI 100% | 137 = 58.3%、UI 83% | **88 = 37.4%、UI 50%** |
| 依据 | `7fec44a` 时代 | 作者自述口径 | 本文 §2/§4/§5 命令 |