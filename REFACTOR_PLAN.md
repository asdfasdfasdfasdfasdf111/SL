# SL 重构计划表

> 分支：`refactor/modular`（项目本地副本 `~/Downloads/Swim111Launcher_副本`）
> 备份：你的 61 个维护改动在 `backup/local-wip-20260920`

## 验证手段（2026-09-22 修正：三级阶梯，缺一不可）

> ⚠️ **修正说明**：本表原先写的是「xcodebuild 在本机被系统沙箱拦截，统一用全量类型检查代替」。
> 这个前提**是错的**，并直接导致了一次真实回归：把 `MinecraftLauncher` 拆成 4 个文件时丢了
> `import SwiftyJSON`，裸 `swiftc -typecheck` 报 0 错误，而真实编译报 5 个 error ——
> 即「类型检查通过」并不等于「编译得过」。真实编译现在可以跑通（见 `scripts/verify-build.sh`，
> 关掉 xcodebuild 内层沙箱即可），**它才是判定标准**。

| 级别 | 命令 | 用途 | 何时必须跑 |
|---|---|---|---|
| 1 快速 | `./scripts/typecheck.sh` | 两口径类型检查，**已开启 MemberImportVisibility**，与真实编译对该类错误口径一致 | 每次改动后即时反馈 |
| 2 真实 | `./scripts/verify-build.sh` | 真实 `xcodebuild build`，最终判定 | **每拆一个文件就跑一次** |
| 3 测试 | `./scripts/verify-test.sh [run]` | 编译（→ 运行）单元测试 | 改动公共逻辑后 |

判定标准：`typecheck` 两口径 0 error 且告警数不超过基线（口径一 44 / 口径二 58）；
`verify-build.sh` 出现 `BUILD SUCCEEDED` 且 `error:` 计数为 0。
并行任务各自用 `SL_DERIVED=/tmp/SL-DD-<任务名>` 指定独立派生目录，避免互相破坏中间产物。


---

## 一、已完成

| # | 事项 | 提交 | 关键产出 | 风险 |
|---|---|---|---|---|
| 1 | 模块内核 | `35d9a61` | `SLModule` / `ModuleContext`（引用类型）/ `ModuleRegistry` / `AppModuleBootstrap` | 低 |
| 2 | 设置层收口 | `35d9a61` | `AppSettingsStore` 成为唯一存储点，复用原有 `UDK` 键名 | 低 |
| 3 | Java 模块 + 接线 | `35d9a61` `b281217` | 统一模型 / `JavaResolver` / `JavaResolverBridge`（同步桥接） | 中 |
| 4 | 下载模块抽象 + 适配器 | `c265f10` | 12 个领域文件 + 3 个适配器 + `MIGRATION.md` | 低 |
| 5 | 下载调用方切换 | `608803b` `364a087` | `ModFileDownloadTask`、`ForgeInstaller`（2 处） | 中 |
| 6 | 启动模块骨架 + 适配器 | `a5b5b19` | 10 个领域文件 + 3 个适配器 + `DUAL_FLOW.md` | 低 |
| 7 | 四模块骨架 | `f2a73fc` `4c631cb8` | ModBrowser / Minecraft / Skin / Theme（22 个文件） | 低 |
| 8 | 伪实现治理 | `f2a73fc` | `AccountError`、`AnyAccount` 明确标注未实现、`STUBS_AUDIT.md` | 低 |
| 9 | **提示通道修复** | `f2a73fc` | `NoticeCenter` + `NoticeOverlay`，修复 3 处"用户看不到提示" | 中 |
| 10 | 工程配置清理 | `5e410aa` | 删除 iOS/visionOS 残留，`SUPPORTED_PLATFORMS = macosx` | 低 |
| 11 | UI 收口（第一批） | `0c0fd53` | `ContentView` 297 → 216 行，抽出 3 个 ViewModel | 中 |
| 12 | 测试体系 | `35d9a61` | 65 个单元测试（Java 选择 / 下载校验 / 分片合并 / 状态边界） | 低 |
| 13 | **大文件按职责拆分** | `48ad4f4` `c7c3250` `a5f639b` `a6c0bed` | PCLCore 七个大文件与两个 UI 大文件按职责拆分（纯搬迁）。最大文件 889 → 487 行。**拆分后真机编译 BUILD SUCCEEDED** | 中 |
| 14 | **真实编译打通** | `d95064c` | 修掉拆分引入的 5 个编译错误，`verify-build.sh` 可用 | — |
| 15 | **qwqTests 接入工程** | `8172dbf` | 测试 target + scheme + `verify-test.sh`；**TEST BUILD SUCCEEDED**，14 文件 180 用例可编译 | 中 |
| 16 | 一批确认缺陷修复 | `6d0541f` `ade90b3` `ab02506` `2364ea4` `3c028fb` | 下载核心 3 条、加载器 4 条、清单 2 条、UI 2 条；弹入动画接线 | 中 |

---

## 二、待做（按风险从低到高）

| # | 事项 | 风险 | 状态 / 需要什么才能收尾 |
|---|---|---|---|
| A | 剩余下载调用方切换 | 低-中 | **进行中**：逐个切换 + `verify-build.sh`；遇到"切换会改变行为"的必须记录不切 |
| B | `qwqTests` 加入工程 target | 中 | ✅ **已完成**（`8172dbf`）：可编译；**运行**需在 Terminal（脱离 AI 沙箱）执行 `./scripts/verify-test.sh run`，AI 沙箱内 testmanagerd 的 XPC 连接会被阻断 |
| C | UI 剩余职责 | 中 | **进行中**：窗口壳/标题栏、`searchText`、`isDropTargeted`、画布手势与 spring 参数、按钮与详情页渲染 |
| D | 启动缺陷 D1–D6 | 中 | D7–D9 已修；D1（客户端 JAR 校验）是**行为变更**，需你拍板；其余逐条复核后修 |
| E | 旧兼容层清理（`PCLStubs` / `PCLLaunchBridge`） | 中-高 | **被 F 阻塞**：需先完成双流程合并，否则会断掉回退路径。`PCLStubs` 487 行，普查出 9 项无引用 |
| F | 双启动流程合并 | **高** | **必须真机启动游戏验证**：Java 扫描等待、日志 flush、进程退出与回调时序。AI 无法代跑 |


---

## 三、已确认的缺陷清单

| 编号 | 缺陷 | 状态 |
|---|---|---|
| D1 | 桥接启动路径**无客户端 JAR 校验**，缺文件照样启动，进游戏才崩 | 待决策（修 = 行为变更） |
| D2 | `MinecraftLauncher` 的 catch 走 `reportCompletion(1)`，"启动失败"与"崩溃退出"不可区分 | 待修 |
| D3 | `exitCode == 0` 时删除日志文件，但会话面板 / `LaunchResult.logURL` 仍指向它 | 待修 |
| D4 | 退管时先置 `readabilityHandler = nil` 再关句柄，管道残留数据丢失（日志尾部） | 待修 |
| D5 | Java 扫描等待是无人 signal 的信号量忙等 | 待修 |
| D6 | 桥接路径漏掉"未实现账号"告警 | 待修 |
| D7 | `PopupManager.show` 空实现导致 3 处安装失败提示不可见 | **已修** |
| D8 | `showAsync` 恒返回 0 导致「导出错误报告」分支永不执行 | **已修** |
| D9 | `hint()` 只写日志，下载完成/失败提示不可见 | **已修** |

---

## 四、每一类的收尾标准

- **模块骨架类**：协议 + 默认实现 + 模块注册 + README，且 `typecheck` 0 error
- **调用方切换类**：对外接口零变化；进度口径一致；错误文案逐字一致；切换后 `typecheck` 0 error
- **大文件拆分类**：新增**强制**条款 ——
  1. **每拆一个文件立刻跑一次 `./scripts/verify-build.sh`**（真实编译，不许只跑 typecheck）
  2. 核对方式：内容行多重集比对（父提交版本 vs 拆分后的文件集合），
     归一化行首尾空白、抹掉访问修饰符后再比，且**按「原文件 → 它拆出的新文件」分组**
  3. 明确记录「哪些块判断不该拆」（如嵌套私有类型不可跨文件、存储属性不能放 extension）
  4. 判定「不是纯搬迁」的差异必须逐条解释（放宽访问级别、换行重排…）
- **缺陷修复类**：修完必须说明"修前现象 / 修后现象 / 是否行为变更"
- **启动合并类**：必须真机启动至少一次游戏，确认：Java 选择成功、资源校验通过、进程启动、日志可见、正常退出无异常弹窗

---

## 六、踩过的坑（避免重犯）

| 坑 | 现象 | 教训 |
|---|---|---|
| 拆分丢 `import` | 拆 `MinecraftLauncher.swift` 时丢了 `import SwiftyJSON`，裸 `typecheck` 报 0 错误，真实编译报 5 个 error，**工程在 `a5f639b`→`d95064c` 之间编译不过** | `import` 是**按文件**生效的；搬移代码必须核对新文件 import 是否覆盖该段代码用到的所有定义模块。行比对查不出这一类（那一行还在别的文件里），**只有编译器能查** |
| 用类型检查代替真实编译 | 原计划表明文规定"统一用全量类型检查代替 xcodebuild" | 假阴性。已在本文档修正为三级阶梯验证 |
| 并行任务抢派生目录 | 并发跑 `xcodebuild` 互相破坏中间产物 | 用 `SL_DERIVED` 给每个任务独立的 `derivedDataPath` |
| 沙箱内跑测试 | `The test runner hung before establishing connection`（等 6 分钟才报错） | 宿主型 XCTest 依赖 testmanagerd 的 XPC，AI 沙箱内跑不了；编译可以在沙箱内完成，运行要在 Terminal |
| 沙箱内跑 git 写操作 | 留下 0 字节 `.git/index.lock`，后续 `git commit` 报 `File exists` | 出现时在沙箱外 `rm -f .git/index.lock` 再提交 |


---

## 五、不做什么

- 不做动态 Bundle 加载、`NSClassFromString`、XPC、插件市场、`Plugin.json` 清单
- 不实现微软登录 / Yggdrasil 登录（本轮范围外，只做"不再假装支持"）
- 不新增功能（主题、多目录、新动画一律冻结）
