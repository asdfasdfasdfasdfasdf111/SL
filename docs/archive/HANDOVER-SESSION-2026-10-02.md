> 🗄️ **本文已归档（2026-10-05）**：内容为 HANDOVER-SESSION-2026-10-02.md 撰写时点的历史快照/审计记录，
> 其中的行号、计数、现状描述**可能已失效**，勿据此判断当前代码。现状请以
> `ARCHITECTURE.md` / `HANDOVER.md` / `README.md` 及代码本身为准。

# 会话交接：2026-10-02 一整晚的「降屎山」工作

> 本文是**一次长会话的压缩归档**，供下个会话接手时恢复状态。
> 事实数据以 git 为准（29 个提交都在 `refactor/cleanup-dead-modules` 分支上），
> 本文只回答「进行中状态、卡点、下一步、踩过的坑」。
> 生成时间：2026-10-02（会话中途）。

---

## 0. 30 秒版

```
分支: refactor/cleanup-dead-modules
HEAD: a545d21（工作区干净）
基线: f3ca5a5（本会话起点，全绿基线）
测试: 55 文件 / 709 用例（起点 253）
生产: 234 文件 / 30,567 行
卡点: 419 条新用例**从未实测** —— 见 §3「唯一卡点」
```

**最重要的一件事**：跑一次 `verify-test.sh run`，把 419 条新用例验证掉。
这一步必须由**能跑 xcodebuild 的人**做（本会话环境 Mach 服务不可达，跑不了）。

```bash
cd "/Users/apple/Downloads/Swim111Launcher_副本" && SL_DERIVED=/tmp/SL-DD-r5 ./scripts/verify-test.sh run
```

跑完不用贴：日志在 `/tmp/sl_test.log`，读它。

---

## 1. 本会话做了什么（29 个提交，按主题）

### 1.1 结构性删除（1 个提交）
- `cdf9dee`：删除**零消费方的模块内核**（`ModuleContext`/`SLModule`/`ModuleRegistry`+8 个注册入口）
  + 4 个死下载协议 + 3 个只为喂注册表而存在的服务 + 2 个"为不存在之物而写"的测试文件。
  净 **-1231 行**。理由与证据全在提交信息里。

### 1.2 缺陷修复（实测/读码驱动，4 个提交）
- `b73df40`：`InMemoryGameSessionStore` **三处缺陷**（多订阅者被覆盖、终态不 finish、无回放）。
  依据：同库 `NetDownloaderDownloadEngine` 的既有写法 + 独立探针复现（15/15）。
  该批 **6 条用例已实测全绿**（用户 01:10 跑过）。
- `bbf76c7`：**`CrashReporter` 信号路径实测有 5 次堆分配** —— 全部来自 `gmtime_r`
  的惰性时区初始化（`[1025, 41448, 18280, 1025, 41448]`）。已修：`install()` 里预热一次。
  修复后探针实测 **0 次**。**这是一个"文件自己声称零分配、实测打脸"的案例**，
  且暴露了上轮审计的对照臂假阴性（见 TESTING.md §4.22）。
- `fdb4371`：`verify-test.sh` 精确统计编译错误（裸 `grep -c "error:"` 会把源码上下文行算错，
  实测同一日志裸 grep=4、精确=0）+ 区分「断言失败」与「已知工具链 abort」。

### 1.3 实测复核（打假/修正声称，2 个提交）
- `e9cdcdb`：`LocalModCatalog` 注释声称「`JSONDecoder` 省 75MB(30%)」——
  **实测是 ~50MB(20%)**（Decoder 199.5 vs 声称 174.4；Serialization 250.2 vs 声称 249.6 吻合）。
  未覆盖原记录，追加复测注记。
- `2c0e592`：补记 §4.22 —— `gmtime_r` 缺陷为何躲过上轮实测（对照臂恰好同尺寸 → 假阴性）。

### 1.4 CI（2 个提交）
- `f15e971`：`test.yml` 门禁改为**只把断言失败当失败**（abort 只告警不失败），
  新增 `probe.yml`（只打印环境，手动触发）。
  ⚠️ **本工作流从未在 CI 上跑过**（本地无网络出口）。启用前先手动跑 probe，
  并确认 token 有 `workflow` scope。
- `fd1a34f`：移除误提交的工具备份文件（write 工具的 tmpdir 泄漏）。

### 1.5 测试（24 个提交，~456 条新用例）
覆盖：下载链（分片/预算/状态/速度/归档）、启动链（参数/规则/实例快照/日志写盘/语言注入）、
Game/ModBrowser（版本过滤/模型/项目/搜索分页/标签/高亮）、工具（Properties/离线用户名/加载器名）。
**每批都是"纯逻辑、加测试不改生产代码"**，夹具走公开入口。

### 1.6 文档
- `a40e79f`：`ARCHITECTURE.md` 改为**只描述现状**（删"目标结构"）；`CHANGELOG.md` 冻结。
- `ad3ec7c` 等：TESTING.md 持续登记（用例数、判据 D 前后对比、各 §4.x 发现）。

---

## 2. 判据 D 的实打实进展（本会话核心指标）

| 时点 | 文件零触达 | 行数零触达 |
| --- | --- | --- |
| 会话开始 `f3ca5a5` | 163/251 = **64%** | 66% |
| 当前 | 110/234 = **47%** | 52% |

口径：生产文件内**所有**顶层类型名都未在测试文本中出现 = 零触达；
只统计 `qwqTests/*.swift`（`TESTING.md` 自身是 .md 不会算进来，但**隐藏 tmpdir 会**）。
计数命令：`grep -h 'func test' qwqTests/*.swift | wc -l`（别用 `-r`）。

⚠️ 该指标是"类型名提及"的**上界**，会低估覆盖（例：`ClientManifestArguments` 已测
但测试写的是 `manifest.getArguments()`，`\bArguments\b` 匹配不到）。

---

## 3. 唯一卡点：419 条新用例从未实测

上次真实实测是 **01:32**：290 条、**4 条断言失败**（3 条是我的夹具错 + 1 条真缺陷）。

之后新增 419 条（当前 709）。**其中绝大多数只过了 `swiftc -typecheck`（0 错误），没跑过。**

**已验证不会因"手推算术"而红的**（用独立探针逐字复刻源码逻辑核对过）：
- NetDownloadState 分片/剩余量算术（8/8）
- ModSearchResult.hasMore 边界（8/8）
- ModProject.primaryFile（4/4）
- InstallStage 分段（0..7/1000+/2000+）
- GameVersionHelper.compare 差值
- toPath/parse 正则（ForgeInstallProfile、ModProject 里的路径断言）
- ForgeInstallProfile.isAvailableOnClient 五种 sides 组合
- MinecraftLauncherLog 字节写入（**12 项里发现 2 处我的断言错，已修正提交 a545d21**）

**仍然只能靠跑**的：ZIPFoundation 夹具（ArchiveUtilTests）、真实网络/时序、UI 相关。

### 已知会红的（有意为之）
- `testArm64DoesNotDowngradeLWJGL333`（ArtifactVersionMapper）用 `XCTExpectFailure`
  标记**真缺陷**：`.arm64` natives 循环里 `!= 3.3.3` 守卫被下一行硬编码 `lwjglPinnedVersion`
  作废 → 3.3.3 的 natives 被降到 3.3.2，而核心 jar 保持 3.3.3（版本不一致）。
  **修法一行**：把该行 `lwjglPinnedVersion` 换成 `library.version`。修好后该用例会
  报 "expected failure did not occur" 变红 → 提醒移除标记。**待用户决定是否修。**

---

## 4. 踩过的坑（下个会话别再踩）

1. **heredoc 不带引号 = 灾难**：`git commit -F - <<MSG` 里的反引号会被 shell 当命令替换执行
   （曾把 `` `id` `` 执行成 `uid=501...` 写进提交信息）。**永远用 `<<'EOF'`。**
2. **提交后必核对**：`git log --format=%B` 独立读一遍（提交信息数字反复写错 5-6 次，
   根因是先写信息再算数）。
3. **`git add` 前清理工具 tmpdir**：write/edit 工具会在目标目录留 `.xxx.tmpdir/` 备份，
   `git add .github/` 时会把 `.probe.yml.41722...tmpdir/probe.yml.tmp` 提交进 git（已发生一次）。
4. **判据 D 口径**：见 §2（两次算错，都往"说轻了"方向）。
5. **裸 `grep -c "error:"` 数编译错误是错的**：源码上下文行会被算进去（本工程有
   `var error: Error?`）。用 `grep -cE '\.swift:[0-9]+:[0-9]+: error:'`。
6. **本机 xcodebuild 不可用**：`confstr(DARWIN_USER_CACHE_DIR)` EIO、
   `sysmond service not found`、`pgrep: Cannot get process list` —— 都是 **Mach/XPC 服务不可达**
   （不是文件沙箱，`sandbox_permissions` 与 `sandbox-exec` 都救不了）。所以**分工固定：
   用户跑 xcodebuild，读 `/tmp/sl_test.log`**。
7. **写"不可测"结论前先测最小事实**（E1 教训：xcodebuild 崩溃原因走了三轮弯路）。
8. **有 `xcodebuild-in-sandbox` 这类 skill 就先加载再动手**。

---

## 5. 下一步（按优先级）

1. **[必须] 用户跑一次 `verify-test.sh run`**（§3），读日志，按断言失败逐批修。
2. **[决策] LWJGL 3.3.3 死守卫**：修不修生产代码（一行），修了移除 XCTExpectFailure 标记。
3. **[可选] 剩余可测文件**：重算后只剩 ~15 个"零硬依赖"文件，其中一半是已知差目标
   （协议壳/适配器/死骨架）。值得补的纯逻辑基本挖完了。
4. **[可选] CI 启用**：先手动跑 probe.yml，确认 token 有 workflow scope。
5. **[可选] 更多实测复核**：离线可复核的"实测声称"已基本挖完（CrashReporter、LocalModCatalog、
   nonisolated-Decodable、GameLogWriter tab）。剩余声称都依赖网络/Minecraft 运行期，本环境测不了。

---

## 6. 环境备注

- DSH 用户级 skills 已装：`apple-swift-reference`、`xcodebuild-in-sandbox`、`codebase-slop-audit`、
  `apple-hig-review`、`subagent-delegation-protocol`、`book-to-skill`、`github`；
  手动调用级：`signal-handler-alloc-audit` 等 5 个（`disable-model-invocation: true`，
  模型不能 skill 加载，但可直接读 `~/.dsh/skills/<名>/SKILL.md`）。
- `/tmp/deps`（SwiftyJSON/ZIPFoundation .swiftmodule）会被清理；回填方法：
  `cp -R build/Build/Products/Debug/{SwiftyJSON,ZIPFoundation}.swiftmodule /tmp/deps/`
  （来源在 `build/` 下，不是 `/tmp`）。
- 自建 typecheck 辅助脚本 `/tmp/tc.sh`（两口径 + 告警集合 diff）也会被清，内容见 §7。

---

## 7. 自建 typecheck 脚本内容（若 /tmp 被清，重写即可）

```bash
#!/bin/bash
cd /Users/apple/Downloads/Swim111Launcher_副本 || exit 1
DEV=$(xcode-select -p)
FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"
LIB="$DEV/Platforms/MacOSX.platform/Developer/usr/lib"
COMMON=(-typecheck -target arm64-apple-macosx13.0 -I /tmp/deps -F "$FW" -I "$LIB"
        -enable-upcoming-feature MemberImportVisibility -D DEBUG)
SOURCES=$(find qwq -name "*.swift")
xcrun swiftc "${COMMON[@]}" -module-name qwq $SOURCES qwqTests/*.swift > /tmp/tc1.raw 2>&1
echo "口径一: 错误 $(grep -c 'error:' /tmp/tc1.raw) / 告警 $(grep -c 'warning:' /tmp/tc1.raw)"
xcrun swiftc "${COMMON[@]}" -module-name qwq -default-isolation MainActor $SOURCES > /tmp/tc2.raw 2>&1
echo "口径二: 错误 $(grep -c 'error:' /tmp/tc2.raw) / 告警 $(grep -c 'warning:' /tmp/tc2.raw)"
```

（基线：口径一 ~112 告警行 / 口径二 24，0 错误。判据用「告警集合逐条 diff」不看数字。）


---

## 8. 环境新变化 + 给接手的人的建议（2026-10-02 15:20 追加）

### 8.1 环境已恢复：xcodebuild 现在能跑了

写本文档时的「Mach 服务不可达、xcodebuild 跑不了」**已不再是障碍**：

- **网络现在通了**（`github.com` / SPM 依赖都能拉取，之前解析不了是临时问题）；
- xcodebuild 能执行，唯一报错是 SwiftPM 的 manifest 诊断写到
  `~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/` 被沙箱拒绝
  （`Operation not permitted`）。

**解法（已验证思路，完整跑通在验证中）**：重定向 HOME，让 SwiftPM 缓存落到可写处：

```bash
mkdir -p /tmp/sl-home
cd "/Users/apple/Downloads/Swim111Launcher_副本"
HOME=/tmp/sl-home SL_DERIVED=/tmp/SL-DD-r7 SL_LOG=/tmp/sl_test_r7.log \
  ./scripts/verify-test.sh run
```

⚠️ 注意：HOME 重定向会改变 `NSHomeDirectory()`，**CrashReporter 的日志路径、
GameSession 的日志等会写到 /tmp/sl-home/... 而不是真实家目录** —— 这只影响测试过程，
不影响被测逻辑的正确性。跑真实 App 时用正常 HOME。

### 8.2 给接手的人的建议（按顺序）

1. **先跑通 §8.1 的全量验证**（709 用例 / 55 文件）。这是本会话最大悬而未决项：
   419 条新用例从没实测过。日志在 `SL_LOG` 指向的文件里，新 verify-test.sh 会
   区分「断言失败」与「已知 abort」——**先修断言失败，别被 abort 带偏**。
2. **跑完立刻用真实日志复核我的判据**：`grep -cE 'error: -\[qwqTests\.'` = 断言失败数，
   `grep -c "Restarting after unexpected exit"` = 已知工具链 abort（约 1/4 概率，非代码问题，
   见 TESTING.md §五）。当前 `verify-test.sh` 已把这些分开报。
3. **已知会红但属"有意"的用例**：`ArtifactVersionMapperTests.testArm64DoesNotDowngradeLWJGL333`
   用 `XCTExpectFailure` 标记了 LWJGL 3.3.3 死守卫缺陷 —— 它报 "expected failure did not occur"
   才说明有人修好了缺陷。**修法一行**：`qwq/SLCore/Minecraft/Download/ArtifactVersionMapper.swift:119`
   把 `lwjglPinnedVersion` 换成 `library.version`（我已确认上游 3.3.3 的 arm64 natives 真实存在）。
4. **别再做的事**：清死代码（判据 C 已 1.9%）、写目标结构文档、加无实现协议、
   用裸 `grep -c "error:"` 数编译错误（会算进源码上下文行）。
5. **纪律**：提交信息先算好数字再写、`git add` 前清 `.*.tmpdir`、提交后 `git log --format=%B` 核对、
   heredoc 永远 `<<'EOF'`。
6. **判据 D 现状**：文件零触达 64% → 47%，行 66% → 52%。口径见 §2。
7. **剩余高价值方向**（纯逻辑测试井已近干涸）：离线实测复核「源码注释里的实测声称」
   （已查 CrashReporter/LocalModCatalog/GameLogWriter/nonisolated-Decodable），
   或读高风险代码找缺陷（启动链、下载链）。网络恢复后也可复核 Modrinth 相关的声称。
