# 施工移交：Swim111Launcher「屎山」修复作业指导书（2026-10-02）

> **本文写给接手修复的 AI/工程师**。配合《SLOP-AUDIT-2026-10-02.md》使用：
> 审计报告回答**哪里烂**（证据），本文回答**怎么改**（决策表 + 分级顺序 + 验收命令）。
> 本文所有「环境事实」均为 2026-10-02 当天实测，**已覆盖旧交接文档的过期结论**。
> 起点：commit `2d58c6a`，分支 `refactor/cleanup-dead-modules`。

---

## 0. 30 秒版

```
环境: xcodebuild 现在能跑（旧文档 §4.6「不可用」已过期，见 §1）
测试: 709 用例全量实测 53 秒，6 个断言失败（5 条用例，见 §2）
卡点: 6 条失败中有 2 条可能就是"修好了的回归守卫又红了"（MLL/CardTranslationStore）
顺序: §3 分级修复，零风险清理先行
验收: ./scripts/verify-test.sh run（必须真跑，不许只 typecheck）
```

**最重要的一件事**：环境恢复后，第一优先是把 §2 的 6 条断言失败修绿——
那是**当前唯一挡在"全绿基线"前的墙**，也是审计报告之外实测抓到的活证据。

---

## 1. 环境事实更新（2026-10-02 实测，取代旧文档结论）

### 1.1 xcodebuild 可用（重要更正）

旧交接文档 §4.6 断言「本机 xcodebuild 不可用（Mach 服务不可达），分工固定：用户跑、AI 读日志」。
**该结论已过期**。今日实测：

```bash
cd "/Users/apple/Downloads/Swim111Launcher_副本" && SL_DERIVED=/tmp/SL-DD-r8 ./scripts/verify-test.sh run
# 输出：** TEST BUILD SUCCEEDED ** → 709 用例 53 秒跑完
```

- 之前失败的真正原因：**DSH 文件策略曾限制写 `~/Library`**（SPM 缓存），
  不是 Mach 服务；本日策略放开后立刻跑通。
- **不要用 HOME 重定向**：`HOME=/tmp/sl-home` 会迫使 SPM 重新联网拉包，
  而 GitHub 不可达（见 1.3），会卡在 "Updating from ... ZIPFoundation" 后 exit 74。
  默认 HOME 下 SPM 缓存完整，直接跑即可。

### 1.2 验证命令（三级阶梯，缺一不可）

| 级别 | 命令 | 何时用 |
|---|---|---|
| 1 快 | `./scripts/typecheck.sh` | 每次改动后（两口径，0 error；告警数需与基线同口径比） |
| 2 真 | `./scripts/verify-build.sh` | 每拆/每改一个文件后（必须见 `BUILD SUCCEEDED`） |
| 3 测 | `./scripts/verify-test.sh run` | 改公共逻辑后（**判定标准，必须真跑**） |

⚠️ 各自用独立 `SL_DERIVED=/tmp/SL-DD-<任务名>`，避免并行任务抢派生目录。
⚠️ 已知工具链 abort（`pointer being freed`）约 1/4 概率，abort 后**换全新 SL_DERIVED 重试**，
   不要据此判定代码有问题；脚本已把「断言失败」与「abort」分开报。

### 1.3 网络边界（实测）

- ✅ `libraries.minecraft.net`（Mojang 库）可达——LWJGL 3.3.3 arm64 natives 实测 200。
- ❌ `github.com` **不可达**（000）——不要触发任何 SPM 重新拉包。
- 因此：依赖解析必须走本机缓存（已完整）；涉及 GitHub 的 CI 启用推迟。

---

## 2. 当前 6 个断言失败（全量实测抓到，逐个给修法）

> 来源：`/tmp/sl_test_r8.log`（全量 709 用例唯一一次真实运行）。
> 每个失败先定性「测试错 / 生产缺陷 / 待定」，再给修法与验收。

| # | 位置 | 现象 | 定性 | 修法 |
|---|---|---|---|---|
| F1 | `AssetIndexTests.swift:45` `testParseExtractsHashAndSize` | `[1234,56]` ≠ `[56,1234]` | **测试错** | 夹具两个对象 hash 为 aaaa…与 bbbb…，`sortedObjects` 按 hash 升序 → a 对象(size 1234)在前。**期望值应改成 `[1234, 56]`**（或并列断言 hash 排序） |
| F2 | `CardTranslationStoreTests.swift:91-92` `testMergeTrimsWhenCombinedOverLimit` | `v5` 未裁、count 1992≠4 | **测试错（夹具）** | 夹具用了 `(0..<1990)`=1990 条 + batch 2 条 = 1992 < 2000 上限 → **不触发裁剪**，断言自然全错。改成 `(0..<1999)`（1999+2=2001>2000 才触发）。注：此用例是「先裁后并」的回归守卫，修夹具即可 |
| F3 | `GameVersionHelperTests.swift:71` `testNonNumericIdComparesEqualToNumericVersion` | compare 返回 -1 ≠ 0 | **测试错（断言）** | `compare("23w33a","1.20")`：`"23w33a".split(".")` 无数字段 → pa=[]，pb=[1,20]；循环 `va(0) != vb(1)` → 返回 -1。**注释声称"退化成空数组判等 0"是手推错误**。修法：断言改为 `XCTAssertLessThan(compare("23w33a","1.20"), 0)` 并更正注释（空数组 < 任何非空版本），或钉住 -1 |
| F4 | `ItemFilterTests.swift:125` `testEmptyQueryMatchesEverything` | XCTAssertTrue 失败 | **测试错（对 Foundation 行为的手推错）** | 独立探针实测：macOS 上 `localizedCaseInsensitiveContains("")` 返回 **false**（不是注释声称的恒真）。修法：注释与断言改为「空查询**不**命中任何条目」= `XCTAssertFalse`，并把「上界行为」注释更正 |
| F5 | `MinecraftLauncherLogTests.swift:267` `testDrainPipeReturnsWithinDeadlineWhenWriterEndStaysOpen` | 内容 `""` ≠ `"tail data\n"` | **待定（高度疑似生产缺陷）** | 独立探针复现：写端未关 + 已写数据 → `poll` 返回 `ready=1 revents=POLLIN`，但 `read(upToCount:)` **抛 EAGAIN**（NSCocoaErrorDomain 256 / errno 35），第二次 poll 直接超时 break。`drainPipe` 于是**没读到已写入的数据**就返回。可能 root cause：`FileHandle.read` 与 O_NONBLOCK 组合在数据量小时读空，或 poll/read 竞态。**需要能跑测试的人先加打印二次确认**（本日已确认非偶发：全量与单测隔离均红，3.1s 走满 deadline） |
| F6 | `MinecraftLauncherLogTests.swift:267`（同 F5 用例的第二条断言 `elapsed < 5`） | 通过 | — | F5 用例两条断言：`elapsed<5` 通过（drainPipe 确实按时返回了），仅内容断言失败——**"按时返回"与"数据排空"两个性质分离，只有后者坏** |

**F5 的处置优先级最高**：它是「已修 bug 的回归守卫」（注释自称靶心用例），
现在变红 = 很可能 `drainPipe` 的实现本身就存在「写端未关时丢数据」缺陷，
**这直接关系到日志尾部缺行（D4 修复对象）**，不是普通测试错。

---

## 3. 分级修复顺序（按风险从低到高，每级给验收）

### P0 零风险清理（可立即做，不影响任何行为）

| # | 项 | 做法 | 验收 |
|---|---|---|---|
| P0-1 | 工作区根目录 `.o` 文件 ×4（ContentView.o 2.5MB 等） | `rm *.o` 并从 `.gitignore` 确认被忽略 | `git status` 干净、`verify-build.sh` 仍 BUILD SUCCEEDED |
| P0-2 | 源码副本目录 `qwq 2026-05-30 15-51-29 2/` + `15-51-29.zip` | 移到 /tmp 或删除 | `find qwq -name '*.swift' \| wc -l` 仍 = 234 |
| P0-3 | AppDelegate.swift:37-45「永不执行」的 `#unavailable` 兜底 | 删 9 行（部署目标 13.0，分支永不执行，代码与注释自认） | typecheck 0 error + 全量测试绿 |
| P0-4 | AppContext.swift:14 `downloadSession`、:52 `appSupportURL`（零消费者） | 删或注明保留理由（若删：确认无其它引用——已核实全库 ≤1 次） | grep 无引用 + 编译过 |

### P1 测试与低风险修正（直接改，需全量验证）

| # | 项 | 做法 | 验收 |
|---|---|---|---|
| P1-1 | F1/F2/F3/F4 四个断言失败 | 按 §2 修法改测试文件（只动测试） | `verify-test.sh run` 全绿，无 abort 重试一次 |
| P1-2 | F5 drainPipe 缺陷 | 先加打印二次确认 root cause；修 `drainPipe`（候选：read 空时尝试 `readabilityHandler` 摘钩前先 drain；或轮询等待数据落入缓冲） | 隔离跑 `-only-testing:qwqTests/MinecraftLauncherLogTests` 绿，且全量绿 |
| P1-3 | `ModpackDownloader` 死链（search→downloadLatest→downloadFirst） | **决策：接 or 删**。无 UI 入口、无测试 → 推荐**删除三条 public API 及不用的 `searchCache`**（若 Modpack 功能在路线图上，则改为删死链留 search 并补测试） | 编译过 + grep 零悬空 |
| P1-4 | `ThemeDefinition` 悬空（全库 1 次） | 删文件或并入 ThemeManager（已核实零引用） | 编译过 |

### P2 中风险（需读调用链后做，改动较大）

| # | 项 | 做法 | 验收 |
|---|---|---|---|
| P2-1 | `LaunchPreflight` 协议族零消费 | **决策：接 or 删**。推荐先接：`LaunchCoordinator` 启动路径注入 `DefaultLaunchPreflight` 并执行四类校验（client/library/asset/natives），这是 ARCHITECTURE.md §七宣称已交付的结构——**接上才算兑现**；若判定不接则删除并更新文档 | 注入后：启动仍正常（`SL_DEBUG_AUTO_LAUNCH=1` 真机冒烟）+ 全量测试绿 |
| P2-2 | `GameSessionStore` / `GameProcessController.terminate` 待接线 | 按 `MinecraftInstanceLaunchService.swift:57-70` 的 T1/T2/T8/T9 前置条件逐个解决；T2（onLauncherReady 拿 Launcher 引用）需先改 LaunchState | 接上后有测试的会话终止路径真正执行（`register/update/observe/terminate(sessionID:)` 非空转） |
| P2-3 | 双实现合并第一组：`ModLoader.assetName` vs `LoaderNameResolver.assetMap` | 删一份，统一走 `LoaderNameResolver`（保留 `ModLoader.assetName` 的 documented intent 注释） | grep 只剩一份数据源 |
| P2-4 | 双实现：`ModpackInstaller.unzip` vs `Util.unzip` | 删私有副本，改调 `Util.unzip`（注意签名差异：Bool vs throws） | 编译过 + ZIP 相关测试绿 |
| P2-5 | User-Agent 7 处 → 提为 `SharedConstants`（已在 SLCore/Utils/SharedConstants.swift） | 统一替换 | grep 只剩常量一处 |

### P3 高风险（涉及启动/架构，需真机验证，未解决前别动）

| # | 项 | 做法 | 验收 |
|---|---|---|---|
| P3-1 | **SLCore→Features 分层倒置**（SLLaunchBridge 直连 JavaManager/LauncherSettings） | 按 ARCHITECTURE.md §五已定方向：启动器只调用 `JavaResolver`。把 SLLaunchBridge 的 Java 选择收口到 JavaResolver + JavaResolverBridge | 启动 Java 选择路径不变（真机冒烟） |
| P3-2 | **Features→App 倒置**（24 处 `AppContext.shared`） | 决策：把 `AppContext` 沉到 `Core/`（它自称基础设施/DI 容器），或给 Features 提供协议接口 | 编译过 + 全量绿 + 启动正常 |
| P3-3 | `LaunchFix` 上帝对象拆分 | 按 ARCHITECTURE.md §十待办 1：按四类校验拆分（这是"接上 LaunchPreflight"的前置） | 拆分后 LAUNCH_FLOW 行为不变 |
| P3-4 | 下载双轨收口（NetManager 留 or 换） | ARCHITECTURE.md §十待办 2 明确「不要继续维持待接线」——做二选一 | 下载路径全量经单入口 |

### P4 可选 / 需用户拍板

| # | 项 | 说明 |
|---|---|---|
| P4-1 | **LWJGL 3.3.3 死守卫修一行**（ArtifactVersionMapper.swift:119 `lwjglPinnedVersion`→`library.version`） | 已确认上游 3.3.3 arm64 natives 存在（curl 200）。属行为改动，**修前问用户**；修后移除 `XCTExpectFailure` 标记（test 会报 "expected failure did not occur" 变红提醒） |
| P4-2 | CI 启用（test.yml / probe.yml 从未跑过） | 本地无 GitHub 出口，需用户环境；先手动跑 probe.yml 确认 token 有 workflow scope |
| P4-3 | 默认窗口尺寸 `defaultSize(900×660)` 恢复 | REFACTOR_PLAN §二 H 已记录，一行改动，属用户可见行为，先问 |

---

## 4. 修复后必须做的回归（防「假绿」）

1. **全量测试**：`SL_DERIVED=/tmp/SL-DD-final ./scripts/verify-test.sh run` → 断言失败 = 0。
2. **反证抽查（每处"删 X"都要）**：删前备份到 `/tmp/rp-backup/`，删后跑相关 suite 确认
   **只有预期用例变红或全绿**；还原后 grep 标记（如 `反向用例临时摘掉`）确认零残留。
3. **告警集合对照**：typecheck 0 error 且告警集合与基线 diff（口径一/二），不要只看数字。
4. **真机冒烟（改启动/下载/设置链路后）**：`SL_DEBUG_AUTO_LAUNCH=1` 跑真实 App
   （DebugAutoLaunch 已在代码里，Release 空实现），观察 app.log + 进程 + 日志落盘。

---

## 5. 纪律（从交接文档继承，防止再踩）

1. **heredoc 永远 `<<'EOF'`**（反引号会被 shell 执行，历史上写过 `uid=501` 进提交信息）。
2. **提交后必核对**：`git log --format=%B` 独立读一遍（数字反复写错）。
3. **`git add` 前清临时目录**：write 工具的 `.xxx.tmpdir/` 备份会混进提交（已发生一次）。
4. **计数用正确口径**：裸 `grep -c "error:"` 会把源码上下文行算进去（本工程有 `var error: Error?`）；
   用 `grep -cE '\.swift:[0-9]+:[0-9]+: error:'`。
5. **反证实验前先提交**（否则 `git checkout --` 会把修复一起回滚）。
6. 并行 xcodebuild 各自 `SL_DERIVED`。

---

## 6. 复核记录

| 日期 | HEAD | 做了什么 |
|---|---|---|
| 2026-10-02 | `2d58c6a` | 本移交文档创建。环境事实按当天实测更新（xcodebuild 可用、GitHub 不可达、6 条断言失败归属）。审计报告见 `docs/SLOP-AUDIT-2026-10-02.md` |