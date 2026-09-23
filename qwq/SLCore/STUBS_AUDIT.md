# 伪实现与假功能审计报告

审计范围：`qwq/SLCore/` 与 `qwq/Features/` 全量 Swift 源码。
审计分支：`refactor/modular`。
审计目标：找出「类型/接口上看似支持、运行期实际不生效」的能力，并作出治理处置。
治理原则：**不实现缺失功能，只消除静默降级**——未实现的能力必须显式表达为未实现，
而非伪装成可用或默默退化为其它行为。

## 0. 结论摘要

- 本次治理共改动 5 个文件，新增 1 个报告文件，全部为「标注 / 显式告警」级改动，不含功能实现。
- 已确认无任何 UI 入口构造 `.microsoft` / `.yggdrasil` 账号，故**未改动任何 UI 布局**。
- 任务书中列出的 `NetworkTest.hasNetworkConnection()` **在当前分支已不存在**（详见 §2.1）。
- 离线账号链路（`SLLaunchBridge.slLaunch` → `AnyAccount.offline`）未受影响，功能照常。

**第二轮（兼容层引用普查，2026-09）**：对 `qwq/SLCore/Stubs.swift` 的 65 项声明逐项统计全库引用，
结果为 **有引用 56 项 / 无引用 9 项 / 语义可疑 3 项**。9 项无引用声明已加
`@available(*, deprecated, message: "全库无引用，待清理")` 标注，**本轮不执行删除**；完整表格见 §9。
本轮同时更正了 §1.4、§5.3、§8 中关于 `AccountManager` / `AppRouter` 的两处误判。

**第三轮（死代码清理，2026-09）**：第二轮标注的 9 项无引用声明**已全部删除**（记录见 §9.3）。
同轮另删除五处经全库核实「零调用方」的代码：

| # | 删除对象 | 位置 | 零调用方的核实方式 |
| --- | --- | --- | --- |
| 1 | 旧启动流程 `MinecraftInstance.launch(_:)`（含 `setup()` 之外的全部实现） | `SLCore/Minecraft/MinecraftInstance.swift` | `grep -rn "\.launch(" qwq qwqTests` 的全部命中都是 `MinecraftLauncher.launch` / `LaunchService.launch` / `MinecraftInstanceLaunchService.launch(_:)`，无一是它 |
| 2 | `MinecraftLauncher.isCancelled`（no-op 桩，读恒 false、写被丢弃） | `SLCore/SLLaunchBridge.swift` | 排除 `Task.isCancelled` 后 0 命中 |
| 3 | `MinecraftLauncher.resolveGameDirURL()` | `SLCore/SLLaunchBridge.swift` | 0 命中 |
| 4 | `NoasyncBridge.swift`（`LockCompat.swift` 拆分后剩下的空壳：仅一个零调用方自由函数 `semaphoreWait(_:)`） | `SLCore/Utils/`（整个文件） | 0 命中 |
| 5 | `LoaderSupportState.supportedLoaders(for:)` 及其驱动的缓存读侧 API | `SLCore/Minecraft/Mod/Loader/` | 0 命中（同文件的写侧由 `LoaderSupportProbe` 调用，已保留） |

另删除 `AnyAccount.isFullyImplemented`、`AppRouter` 类整体与 `InstallTask` 中依赖它的不可达分支
（`if case .installing(_) = DataManager.shared.router.getLast()`，因全库无 `append` 调用点而恒为假）。

同轮把 `Stubs.swift` 等文件里失效的「文件:行号」引用标注统一改为「文件 + 符号/场景」形式：
行号会随任何一次编辑漂移，经过前两轮改动后其中大量标注已指向错误位置甚至已删除的代码。

> **阅读须知**：§1–§9 的表格是**第二轮普查当时的快照**。表中的 `文件:行号` 与
> 「已标注 deprecated、待清理」等结论均描述**改动前**的状态；被标为「保留」的
> `AppRouter` / `Theme` / `ColorSchemeOption` / `URL.parent()` 等项，在第三轮已按本表 §9.3
> 的清单删除。各表行号不再逐个回改——回改本身又会立刻产生新的漂移，
> 第三轮的处置结果以本节与 §9.3 为准。

## 1. 账号系统（快照，行号已失效，按符号检索）

### 1.1 `.microsoft` / `.yggdrasil` 伪实现（高）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/SLCore/Stubs.swift`（`case microsoft`）、`qwq/SLCore/Stubs.swift`（`case yggdrasil`） |
| 当前行为 | 两个 case 均以 `OfflineAccount` 承载，未实现任何 OAuth / Yggdrasil 认证。`account` 计算属性 `case .offline/.microsoft/.yggdrasil` 统一返回离线账号；`putAccessToken` 写入的是「UUID 本身」这一离线令牌规则。 |
| 实际行为 | 完全等同离线登录：不请求 Microsoft 设备码流、不交换 XBL/XSTS、不访问会话服务器；Yggdrasil 仅额外预置 `authlib-injector`（`MinecraftInstance.swift`），但**不产生任何认证会话**。 |
| 影响 | **会误导用户**。类型层面存在 `microsoft` / `yggdrasil` case，任何依据 case 名称分支的消费方都会误判「该账号已联网认证」，实际进服为离线身份。 |
| 已完成处置 | ① 保留 case 名称不变（`CodableAppStorage("accounts")` 以 JSON 持久化，删除 case 会导致旧数据解码失败），改写注释为显式「尚未实现」；② 新增 `AnyAccount.isFullyImplemented`（`Stubs.swift`，offline 为 true，其余 false）；③ 新增 `AnyAccount.accountKindDescription`（`Stubs.swift`，如「微软账号（尚未实现，当前按离线账号处理）」）；④ 新增 `AnyAccount.unimplementedError`（`Stubs.swift`），返回对应 `AccountError`；⑤ 新增 `AccountError` 枚举（`Stubs.swift`），`errorDescription` 为中文且直述「尚未实现」，不写「登录失败」；⑥ 启动路径 `MinecraftInstance.swift` 对未实现账号输出 `warn` 级显式告警。 |
| 建议处置 | **标注**（已完成）。后续若要实现，需独立立项完成完整 OAuth 流程，本次不实现。 |

### 1.2 `.microsoft` / `.yggdrasil` 调用点清单（全量）

| 位置 | 用途 | 是否构造 | 处置 |
| --- | --- | --- | --- |
| `qwq/SLCore/Stubs.swift` / `:195` | 枚举 case 定义 | — | 保留 + 标注 |
| `qwq/SLCore/Stubs.swift` | `account` 计算属性模式匹配 | 否 | 保留 |
| `qwq/SLCore/Minecraft/MinecraftInstance.swift` | `if case .yggdrasil = account` 预置 authlib-injector | 否 | 加注释说明「不代表已完成外置登录」 |
| `qwq/SLCore/SLLaunchBridge.swift` | `options.account = .offline(account)` — **全库唯一账号构造点** | 仅 `.offline` | 无改动 |

**结论：全库不存在任何 `.microsoft(...)` / `.yggdrasil(...)` 的构造点。**
搜索 `microsoft` / `yggdrasil` / `微软` / `外置登录` / `正版登录` 的全部命中均为
Java JDK 下载源（`aka.ms`、`Microsoft JDK`）与离线账号 UUID 算法注释，与账号登录无关。

### 1.3 UI 入口核查（未改动 UI）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/Features/ModBrowser/CategoryContentView.swift`（`TextField("离线模式用户名", ...)`）、`:272`（`offlineUsernameHint`） |
| 实际行为 | 全应用**只有离线用户名输入框，没有任何「微软登录」「外置登录」按钮或账号选择器**。 |
| 影响 | 不存在「点击后被静默降级」的入口，用户不会被诱导去点一个假按钮。 |
| 处置 | **未改动 UI**（无入口可改，且无必要）。 |

### 1.4 账号持久化层的引用核实（**结论已更正**）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/SLCore/Stubs.swift`（`AccountManager`、`@CodableAppStorage("accounts")`、`accountId`） |
| 当前行为 | 提供账号的持久化读取接口。 |
| 实际行为（**第二轮更正**） | 原报告称「`AccountManager` 在全代码库无任何引用」，该结论**有误**。`AccountManager.shared.getAccount()` 在 `qwq/SLCore/SLLaunchBridge.swift` 被活跃调用，用于读取持久化账号并在 `:125-127` 对未实现种类显式告警。真实启动链路 `SLLaunchBridge.swift` 另用 `OfflineAccount(username)` 新建离线账号，两条路径并存。 |
| 影响 | 无用户影响。`accounts` / `accountId` 由本类型自身读写，外部只经 `getAccount()` 读取。 |
| 建议处置 | **保留**（第二轮已核实有引用，不得删除）。 |
| 附注 | 由于该读取路径存在，§1.1 中「保留 `.microsoft` / `.yggdrasil` case 以兼容持久化数据」现在具备实际数据通道支撑。 |

## 2. 网络探测

### 2.1 `NetworkTest.hasNetworkConnection()` —— 已不存在（需澄清）

| 项 | 内容 |
| --- | --- |
| 当前位置 | **当前分支不存在该符号**。`qwq/SLCore/Stubs.swift` 及全库 `.swift` 文件中均无 `NetworkTest` / `hasNetworkConnection`。 |
| 历史位置 | 仅存在于初始提交 `5d5769d:qwq/SLCore/Stubs.swift`，实现为 `hasNetworkConnection() -> Bool { true }`。 |
| 验证方式 | `grep -rn "NetworkTest\|hasNetworkConnection" --include="*.swift" .` → 0 命中；`git show HEAD:qwq/SLCore/Stubs.swift` → 无该内容；`git log -S"NetworkTest"` 显示其在 `08e83d0` 已被移除。 |
| 影响 | 无。当前无调用方，也不存在恒真的伪网络判断。 |
| 处置 | **无需处置（已移除）**。若后续确有网络可用性需求，应新增真实探测（`URLSession` + 短超时 HEAD 请求），而非恢复恒真桩。 |

说明：本次为遵循「不实现缺失功能」与「不引入并发风险」，**未新增任何网络探测代码**。

## 3. 弹窗系统（快照，行号已失效，按符号检索）

### 3.1 `PopupManager.show(_:)` 为空实现（高）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/SLCore/Stubs.swift` |
| 当前行为 | `public func show(_ model: PopupModel) async {}` —— 空函数体。 |
| 实际行为 | **弹窗从不显示**。调用方 `await` 后立即返回，界面上无任何反馈。 |
| 影响 | **严重误导**。三类安装失败（Minecraft / Fabric / Forge·NeoForge）均依赖它向用户报错，实际用户只会看到「安装无响应 / 详情页无后续」，无法获知失败原因。 |
| 调用点 | ① `qwq/SLCore/Minecraft/Download/InstallTask.swift` —— Minecraft 安装失败提示（期望：弹出错误弹窗，按钮 `[确定]`）<br>② `qwq/SLCore/Minecraft/Download/InstallTask.swift` —— Fabric 安装失败提示（同上）<br>③ `qwq/SLCore/Minecraft/Download/InstallTask.swift` —— Forge / NeoForge 安装失败提示（同上） |
| 已完成处置 | 方法签名保持不变；补充文档注释明确「空实现、弹窗不会显示、调用方无法得知提示是否送达」；新增 `PopupManager.isAvailable`（`Stubs.swift`，恒 `false`）供调用方做能力探测。 |
| 建议处置 | **实现**（后续）：接入真实弹窗通道。当前先以 `isAvailable` + 注释暴露真相，避免调用方误以为已提示用户。 |

### 3.2 `PopupManager.showAsync(_:)` 恒返回 0（高）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/SLCore/Stubs.swift` |
| 当前行为 | `public func showAsync(_ model: PopupModel) async -> Int { 0 }` —— 不展示 UI，恒返回 0。 |
| 实际行为 | 等价于「**永远点击第 0 个按钮**」，用户从未参与选择。 |
| 影响 | **严重误导**。调用方以返回值分支，非 0 分支为死代码。 |
| 调用点 | ① `qwq/SLCore/Minecraft/MinecraftInstance.swift` —— 游戏非 0 退出码时弹出「Minecraft 出现错误」，按钮 `[.ok, .init(label: "导出错误报告", style: .accent)]`；期望：用户点「导出错误报告」时返回 `1` 并进入导出流程。**实际恒返回 0，「导出错误报告」分支永远不会被执行**——这是本项目中危害最直接的伪功能。 |
| 已完成处置 | 补充文档注释，明确说明返回值语义为「恒为 0，即第 0 个按钮」以及调用方分支会永久走 index == 0。签名不变。 |
| 建议处置 | **实现**（后续）：接入真实弹窗并按用户点击返回索引；或临时将调用方改为「不做分支假设」。 |

### 3.3 状态更新（第二轮普查时复核）

§3.1 与 §3.2 描述的空实现 / 恒返回 0 **已不成立**：当前代码中
`PopupManager.show(_:)` 已改为 `NoticeCenter.shared.post(Notice(model))`，
`showAsync(_:)` 已改为 `await NoticeCenter.shared.presentAndWait(Notice(model))`
（`Stubs.swift`，`NoticeCenter.swift` 提供 `hasPresenter` / `presentAndWait(_:)`）。
即弹窗已接入真实提示通道，`MinecraftInstance.swift` 的「导出错误报告」分支可被真实点击触发。
本项遗留问题关闭；第二轮改为关注 `PopupManager.isAvailable`（全库无引用，已标注待清理）。

## 4. 启动取消

### 4.1 `MinecraftLauncher.isCancelled`（原 no-op 桩，第三轮已删除）（中）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/SLCore/SLLaunchBridge.swift` |
| 当前行为 | `get { false }`，`set { /* no-op */ }` —— 读恒 false，写被静默忽略。 |
| 实际行为 | 无法通过该标志取消启动；同步 `launch` 调用不支持中途取消。 |
| 影响 | 会误导调用方以为可以取消启动。**当前全代码库无任何调用点**（`grep "\.isCancelled"` 排除 `Task.isCancelled` 后 0 命中），故暂无实际用户影响。 |
| 已完成处置 | 改写注释，明确「读恒 false / 写无效果 / 不得据此判断已取消」，并指向真实可用的 `terminate()`。 |
| 建议处置 | ~~**标注**（已完成）~~ → **第三轮已删除**。该属性是 no-op 桩且全库零调用方（排除 `Task.isCancelled` 后 0 命中），删除时一并移除了**只为它存在**的 objc 关联对象 key。如需取消能力应基于 `terminate()` 实现，本次不做。 |
| 对比 | `isUserTerminated` / `terminate()`（`SLLaunchBridge.swift`）为**真实实现**，非桩，且仍有活跃调用，已保留。 |

## 5. 其他扫描发现（快照，行号已失效，按符号检索）

### 5.1 `hint()` 只写日志、不显示任何界面（高）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/SLCore/Stubs.swift` |
| 当前行为 | `public func hint(_ message: String, _ type: HintType = .info) { log("[Hint] \(message)") }` |
| 实际行为 | PCL2 中 hint 是界面瞬时提示条；此处退化为一条日志，**用户看不到任何提示**。 |
| 影响 | **会误导用户**：关键状态变化静默化。 |
| 调用点 | ① `qwq/SLCore/Minecraft/MinecraftInstance.swift` —— 「检测到 Minecraft 出现错误，错误分析已开始……」（用户看不到）<br>② `qwq/SLCore/Minecraft/Download/InstallTask.swift` —— 文件下载失败（`.critical`，用户看不到）<br>③ `qwq/SLCore/Minecraft/Download/InstallTask.swift` —— 文件下载完成（`.finish`，用户看不到） |
| 已完成处置 | 补充文档注释，明确「只写日志、不显示界面元素、调用后用户无感知」。**第二轮状态更新：该描述已过时**——`hint()` 现已在函数体内把消息按级别转成 `Notice` 投递到 `NoticeCenter`，用户可在界面顶部看到横幅，不再是「只写日志」。 |
| 建议处置 | **已实现（后续已完成）**：接入真实提示通道。 |

### 5.2 `Theme` 桩实现（低）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/SLCore/Stubs.swift` |
| 当前行为 | 只保存 `id`；`load(id:)` 仅 `Theme(id: id)`，不读主题文件、不解析配色/字体。 |
| 实际行为 | 不参与任何渲染；切换主题不产生视觉变化。 |
| 影响 | 当前**无调用方**（全库除定义外 0 处引用），暂无用户影响。真实主题由 `qwq/Features/Settings/ThemeManager.swift` 提供。 |
| 已完成处置 | 注释改写为显式「桩实现」，并指明真实主题渲染位置，避免维护者误用。 |
| 建议处置 | ~~**移除或标注**~~ → **第三轮已整类删除**（含 `load(id:)`）。指向该桩的描述已在 `Features/Theme/README-Theme.md` 与 `Features/Theme/ThemeDefinition.swift` 中同步修正。 |

### 5.3 `AppRouter` 路由栈无入栈点（中）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/SLCore/Stubs.swift`（`AppRouter`）、`:37`（`DataManager.router`） |
| 当前行为 | 提供 `append` / `getLast` / `removeLast` 路由栈。 |
| 实际行为 | **全库无任何 `router.append(...)` 调用**，栈恒为空，`getLast()` 恒返回 `.other`。因此 `InstallTask.swift` 的 `if case .installing(_) = router.getLast()` 判断**永远不会成立**，其中的 `removeLast()`（`:121`）是死代码。真实页面切换由 `DownloadDetailManager` 负责。 |
| 影响 | 不影响用户；误导维护者以为存在路由系统。 |
| 建议处置 | ~~**仅记录，不改**~~ → **第三轮已删除**。第二轮核实：`AppRouter` 类及 `getLast()` / `removeLast()` 有引用（`InstallTask.swift`，经 `DataManager.shared.router`），故当时结论是「不得整体删除，真正的退化点是『无入栈点』」。第三轮改判的依据是：该引用**本身恒不成立**——全库不存在任何 `append(...)` 调用点，栈恒为空、`getLast()` 恒返回 `.other`，因此 `if case .installing(_) = ...` 运行期永不成立，其 `removeLast()` 是不可达分支。删掉该分支（控制流与「条件不成立」那条路等价，已逐行核对）后，`AppRouter` 与 `DataManager.router` 即失去唯一引用，整类删除。真实页面切换由 `DownloadDetailManager` 承担，未受影响。 |

### 5.4 `AppSettings` 部分字段恒为默认值（低）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/SLCore/Stubs.swift`（`currentMinecraftDirectory`） |
| 当前行为 | 声明为可配置项，默认 `.default`。 |
| 实际行为 | **全库无任何写入点**（`grep "currentMinecraftDirectory ="` → 0 命中），恒为 `.default`。 |
| 影响 | 用户无法切换 Minecraft 目录，但界面上也无对应入口，暂无欺骗性。 |
| 说明 | 同类的 `fileDownloadSource` / `versionManifestSource` 有真实写入与读取（`qwq/SLCore/Download/DownloadSourceManager.swift`），为**真实实现**。 |
| 建议处置 | **标注**。 |

### 5.5 `InstallTask` 基类三个空/常量默认实现（低）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/SLCore/Minecraft/Download/InstallTask.swift`（`start() { }`）、`:48`（`getInstallStates() { [:] }`）、`:50`（`getTitle() { "" }`） |
| 当前行为 | 基类默认空实现。 |
| 实际行为 | 可独立启动的任务（`MinecraftInstallTask:234`、`CustomFileDownloadTask:409`、`ModFileDownloadTask:39`）均已覆写 `start()`；`FabricInstallTask` / `LoaderInstallTask` 及其子类**不覆写 `start()`**，因为它们由 `MinecraftInstaller.swift` 通过 `install(_:)` 驱动，**从不经过 `start()`**。`getInstallStates` / `getTitle` 在各具体任务中均已覆写。 |
| 影响 | 当前无缺陷。但若未来有人对加载器任务直接调用 `start()`，将静默无动作。 |
| 已完成处置 | 补充注释，说明「子任务经 `install(_:)` 驱动、调用 `start()` 不会生效」。 |
| 建议处置 | **标注**（已完成）。 |

### 5.6 `DownloadSource.getAssetURL` 协议默认返回 `nil`（可接受，非缺陷）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/SLCore/Download/DownloadSource.swift` |
| 实际行为 | 默认 `nil`；`OfficialDownloadSource:56`、`BMCLAPIDownloadSource:90` 均已覆写，行为正确。 |
| 处置 | **无需处置**。属合法协议默认值。 |

### 5.7 TODO 清单（非伪实现，仅记录）

| 位置 | 内容 | 影响 |
| --- | --- | --- |
| `qwq/Features/Download/ModpackInstaller.swift` | `// TODO: 后续集成 PCL 核心的 InstallTask` | 整理包安装当前不走统一任务系统，进度展示可能与整数包下载不一致。 |
| `qwq/SLCore/Minecraft/ClientManifest.swift` | `// TODO: 处理 arch（官方 macOS JSON 基本不含 arch 规则，风险低）` | 影响面低，已知并接受。 |

### 5.8 形似伪实现、实为用户可见占位（排除）

以下两项名称含「占位」，但均为**真实可用的 UI/状态**，不属于伪实现，特此排除：

- `qwq/Features/ModBrowser/CategoryCanvasPlaceholder.swift` —— 分类切换时的静态中间页视图，被真实渲染。
- `qwq/SLCore/Minecraft/Mod/Loader/LoaderSupportChecker.swift` —— `.checking` 为「尚未定论」状态，UI 有对应展示，且代码显式禁止将其当作结论。

## 6. 改动文件清单

| 文件 | 改动性质 |
| --- | --- |
| `qwq/SLCore/Stubs.swift` | 新增 `AccountError`；`AnyAccount` 新增 `isFullyImplemented` / `accountKindDescription` / `unimplementedError`（case 名称不变）；`hint` / `PopupManager` / `Theme` 补齐显式桩说明；`PopupManager` 新增 `isAvailable`。 |
| `qwq/SLCore/Minecraft/MinecraftInstance.swift` | 启动路径对未实现账号输出显式告警；Yggdrasil 预置 authlib-injector 处补注释澄清。 |
| `qwq/SLCore/SLLaunchBridge.swift` | `isCancelled` 注释明确 no-op 语义与正确替代（`terminate()`）。 |
| `qwq/SLCore/Minecraft/Download/InstallTask.swift` | 基类 `start` / `getInstallStates` / `getTitle` 补充语义注释。 |
| `qwq/SLCore/STUBS_AUDIT.md` | 本报告。 |

第二轮（兼容层引用普查）改动仅限两个文件：

| 文件 | 改动性质 |
| --- | --- |
| `qwq/SLCore/Stubs.swift` | 9 项无引用声明加 `@available(*, deprecated, message: "全库无引用，待清理")`；对 20 余项有引用声明补齐「使用方 / 调用点」注释；更正 `AnyAccount` 文档中关于 `isFullyImplemented` 的表述。**未删除任何代码**。 |
| `qwq/SLCore/STUBS_AUDIT.md` | 新增 §9 逐声明引用普查表；更正 §1.4 / §5.3 / §8 的误判；补记 §3.3 与 §5.1 的状态更新。 |

其余源码文件（含 `qwqTests/`）**一律未改动**；本轮未发现需要同步修改的调用点。

## 7. 验证结果

命令（类型检查，不跑完整 `xcodebuild`）：

```
cd /Users/apple/Downloads/Swim111Launcher_副本
DEV=$(xcode-select -p)
xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps \
  -F "$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
  -I "$DEV/Platforms/MacOSX.platform/Developer/usr/lib" -module-name qwq \
  $(find qwq -name "*.swift") qwqTests/*.swift
```

第一轮结果：`exit = 0`，`grep -c "error:"` = **0**，`warning` 16 条均为改动前既有告警。

第二轮结果：`exit = 0`，`error:` **0** 条，`warning:` **44** 行（与改动前基线完全一致），
其中 `DeprecatedDeclaration` 告警 **0** 条——即本次新增的 `@available(*, deprecated)` 标注
未产生任何新告警（被标注声明在本文件内均无使用点，且经隔离用例实测确认同文件内
「类型引用自身成员」与「switch 匹配自身 deprecated case」不触发弃用告警）。
告警仍为并发严格模式相关的既有项。

## 8. 需人工决策的遗留项

以下各项未在本次改动（改动面超出「标注」范畴或存在回归风险）：

1. ~~**`PopupManager` 接入真实弹窗**~~ —— **已关闭**：`show` / `showAsync` 现已走 `NoticeCenter`（见 §3.3）。
2. ~~**`hint()` 接入真实提示通道**~~ —— **已关闭**：`hint()` 现已投递 `NoticeCenter`（见 §5.1）。
3. **`AnyAccount.microsoft` / `.yggdrasil` 是否长期保留** —— 本次按要求保留 case；§1.4 已更正为「持久化读取路径真实存在」，保留理由成立，需人工确认线上是否确有此类历史数据。
4. **`AppRouter` 与 `AccountManager` 是否删除** —— **此条已在第二轮修正**：两者均有活跃引用
   （`AccountManager.shared.getAccount()` → `SLLaunchBridge.swift`；
   `DataManager.shared.router.getLast()` / `removeLast()` → `InstallTask.swift`），
   **不得删除**。可再评估的是二者内部的无引用成员（`Route.versionList`、`AppRouter.append(_:)`）。
5. **`AppSettings.currentMinecraftDirectory` 是否补 UI 入口** —— 属新功能，本次不做。
6. ~~**9 项「全库无引用」声明是否执行删除**~~ —— **已关闭**：第三轮已全部删除（记录见 §9.3）。
   原前置条件「需确认无跨 target / 运行时反射 / 条件编译引用，且工程侧确认编译与测试通过」已逐项核实：
   工程用文件夹同步组（`project.pbxproj` 无 `.swift` 条目，不存在跨 target 单独引用）、
   全库 `grep` 0 残留、类型检查两口径 0 错误且告警集合等于基线、真实 `xcodebuild` 通过。

## 9. 附录：`Stubs.swift` 逐声明引用普查（第二轮）

### 9.1 口径

- 统计范围：`qwq/**/*.swift`（生产）与 `qwqTests/*.swift`（测试）；`build*/SourcePackages/` 等构建产物与
  `未命名文件夹/` 下的历史副本**不计入**。
- 「引用数」= 除声明行本身以外的使用点行数；仅出现在文档注释中的符号名不计引用。
- 分类规则：**无引用**（生产与测试均为 0）→ 加 `@available(*, deprecated, message: "全库无引用，待清理")`；
  **有引用** → 保留并补「使用方」注释；**语义可疑** → 仅记录，不改代码。
- 本轮**未执行任何删除**：无引用项占 9 / 65，未构成多数，按保守原则仅标注。

### 9.2 完整表

| 声明名 | 引用数（生产/测试） | 引用位置 | 处置结论 |
| --- | --- | --- | --- |
| `URL.parent()` | 13 / 0 | `Minecraft/Mod/Loader/Fabric/FabricInstaller.swift:24`；`Minecraft/Mod/Loader/Forge/ForgeInstaller.swift:175,237,253`；`Minecraft/Launch/MinecraftLauncher.swift:110,114`；`Minecraft/Download/MinecraftInstaller.swift:373`；`Java/JavaVirtualMachine.swift:82,83,111`；`Storage/CacheStorage.swift:80,109`；`Temp/TemperatureDirectory.swift:26`；`FileManagerExtension.swift:17` | 已删除（第三轮：调用点已换原生 `deletingLastPathComponent()`，扩展随删，见 §9.3） |
| `URL.init(fileURLWithUserPath:)` | 0 / 0 | — | **无引用 → 已标注 deprecated** |
| `Optional.unwrap(_:file:line:)` | 4 / 0 | `Minecraft/Download/InstallTask.swift:349`；`Download/DownloadSource.swift:49`；`Download/DownloadSourceManager.swift:109`；`Features/ModBrowser/ModDownloader.swift:156` | 保留（真实现） |
| `hint(_:_:)` | 5 / 0 | `Minecraft/Download/InstallTask.swift:441,445`；`Minecraft/MinecraftInstance.swift:338,345`；`SLLaunchBridge.swift:127` | 保留（已接 `NoticeCenter`） |
| `HintType`（含 3 case） | 1 / 3 | `UI/Notices/NoticeCenter.swift:71`；`qwqTests/NoticeCenterTests.swift:291-293` | 保留 |
| `DataManager`（类） | 30+ / 0 | `VersionManifest.swift:86`；`MinecraftVersion.swift:60`；`DownloadSource.swift:37`；`InstallTask.swift:118-121`；`MinecraftInstaller.swift:451,453,455`；`MinecraftDirectory.swift:77`；`SLLaunchBridge.swift:195-256`；`Java/JavaManager.swift:124,143`；`DownloadDetailManager.swift:57`；`MinecraftInstance.swift:164,182,246` | 保留（真实现） |
| ├ `DataManager.shared` | 25+ / 0 | 同上各处 | 保留 |
| ├ `javaVirtualMachines` | 10 / 0 | `MinecraftInstance.swift:164,182,246`；`SLLaunchBridge.swift:195,202,206,253`；`JavaManager.swift:124,143` | 保留 |
| ├ `versionManifest` | 3 / 0 | `VersionManifest.swift:86`；`MinecraftVersion.swift:60`；`DownloadSource.swift:37` | 保留 |
| ├ `inprogressInstallTasks` | 6 / 0 | `DownloadDetailManager.swift:57`；`InstallTask.swift:118,119`；`MinecraftInstaller.swift:451,453,455` | 保留 |
| └ `router` | 2 / 0 | `InstallTask.swift:120,121` | 已删除（第三轮，随 `AppRouter` 删除，见 §9.3） |
| `AppRouter`（类） | 2 / 0 | `InstallTask.swift:120,121`（经 `DataManager.shared.router`） | 已删除（第三轮，见 §5.3/§9.3） |
| ├ `Route`（枚举） | 1 / 0 | `InstallTask.swift:120` | 已删除（随 `AppRouter` 第三轮删除） |
| ├ `Route.versionList(directory:)` | 0 / 0 | — | **无引用 → 已标注 deprecated** |
| ├ `Route.installing(_:)` | 1 / 0 | `InstallTask.swift:120` | 已删除（随 `AppRouter` 第三轮删除） |
| ├ `Route.other` | 1 / 0 | 本文件 `getLast()` 空栈兜底 | 已删除（随 `AppRouter` 第三轮删除） |
| ├ `getLast()` | 1 / 0 | `InstallTask.swift:120` | 已删除（随 `AppRouter` 第三轮删除） |
| ├ `removeLast()` | 1 / 0 | `InstallTask.swift:121` | 已删除（随 `AppRouter` 第三轮删除） |
| └ `append(_:)` | 0 / 0 | — | **无引用 → 已标注 deprecated** |
| `DownloadSourceOption` | 6 / 4 | `DownloadSourceManager.swift:40,49,69,132`；`Core/Download/Adapters/DefaultDownloadSourceResolver.swift:41`；`MultiFileDownloader.swift:27`；`qwqTests/DownloadAdapterTests.swift:49,53,182,192` | 保留（真实现） |
| `ColorSchemeOption` | 0 / 0 | — | **无引用 → 已标注 deprecated** |
| `AppSettings`（类）/`.shared` | 12 / 4 | `CategoryContentView.swift:133`；`LaunchCoordinator.swift:52`；`OfflineSkinService.swift:70,128,165`；`MinecraftRepository.swift:76`；`SLLaunchBridge.swift:94`；`DefaultDownloadSourceResolver.swift:41`；`MultiFileDownloader.swift:27`；`DownloadSourceManager.swift:40,49,69,132`；`DownloadAdapterTests.swift:49,53,182,192` | 保留 |
| ├ `currentMinecraftDirectory` | 6 / 0（写入 0） | 同上的读取点 | 保留；**语义可疑**（见 §9.4） |
| ├ `fileDownloadSource` | 4 / 4 | `DownloadSourceManager.swift:40,49,69`；`DefaultDownloadSourceResolver.swift:41`；`MultiFileDownloader.swift:27`；`DownloadAdapterTests.swift:49,53,182,192` | 保留（真实现） |
| └ `versionManifestSource` | 1 / 0 | `DownloadSourceManager.swift:132` | 保留 |
| `Account`（协议） | 3 / 0 | `OfflineAccount` / `AnyAccount` 遵循；`AnyAccount.account` 以 `any Account` 承载 | 保留 |
| `OfflineAccount`（类）及 `id`/`uuid`/`name` | 2 / 0 | `SLLaunchBridge.swift:113`（构造）、`:116`（`uuid`） | 保留（真实现，**不得删**） |
| ├ `init(_:_:)` | 2 / 0 | `SLLaunchBridge.swift:113`；`AnyAccount` case 关联值 | 保留 |
| ├ `legacyUuidHex(for:)` | 1 / 0 | 本文件 `init` 内 | 保留（真实现，**不得删**；无外部直接调用） |
| ├ `leftPad(_:to:)` | 2 / 0 | 本文件 `legacyUuidHex` 内 | 保留（真实现，**不得删**） |
| ├ `formatUuid(_:)` | 1 / 0 | 本文件 `init` 内 | 保留（真实现，**不得删**） |
| └ `putAccessToken(options:)` | 2 / 0 | `SLLaunchBridge.swift:191`；`MinecraftInstance.swift:301`（经 `AnyAccount`） | 保留 |
| `validateOfflineUsername(_:)` | 3 / 0 | `LaunchCoordinator.swift:27`；`Features/Launch/Adapters/MinecraftInstanceLaunchService.swift:291`；`MinecraftInstance.swift:293` | 保留（真实现，**不得删**） |
| `AccountError`（枚举） | 2 / 0 | `SLLaunchBridge.swift:125-127`；`MinecraftInstance.swift:288-289` | 保留 |
| ├ `microsoftLoginNotImplemented` | 1 / 0 | 本文件 `unimplementedError` | 保留 |
| ├ `yggdrasilLoginNotImplemented` | 1 / 0 | 本文件 `unimplementedError` | 保留 |
| ├ `networkUnavailable` | 0 / 0 | — | **无引用 → 已标注 deprecated** |
| └ `popupNotAvailable` | 0 / 0 | — | **无引用 → 已标注 deprecated** |
| `AnyAccount`（枚举） | 4 / 0 | `LaunchOptions.swift:17`；`SLLaunchBridge.swift:117,125,126`；`MinecraftInstance.swift:285,288,289,293,298,299,301,302` | 保留 |
| ├ `offline(_:)` | 1 / 0 | `SLLaunchBridge.swift:117`（全库唯一构造点） | 保留（真实现） |
| ├ `microsoft(_:)` | 0 构造 | — | 保留（类型层兼容；语义可疑，见 §9.4） |
| ├ `yggdrasil(_:)` | 0 构造 / 1 模式匹配 | `MinecraftInstance.swift:302`（`if case .yggdrasil`） | 保留（同上） |
| ├ `id`/`uuid`/`name`/`==` | 3 / 0 | `MinecraftInstance.swift:293,299` | 保留 |
| ├ `putAccessToken(options:)` | 1 / 0 | `MinecraftInstance.swift:301` | 保留 |
| ├ `isFullyImplemented` | 0 / 0 | — | **无引用 → 已标注 deprecated** |
| ├ `accountKindDescription` | 2 / 0 | `SLLaunchBridge.swift:126`；`MinecraftInstance.swift:289` | 保留 |
| └ `unimplementedError` | 2 / 0 | `SLLaunchBridge.swift:125`；`MinecraftInstance.swift:288` | 保留 |
| `AccountManager`（类）/`.shared` | 1 / 0 | `SLLaunchBridge.swift:124`（`getAccount()`） | 保留（**曾被误判为死代码**） |
| ├ `accounts` / `accountId` | 本文件内读写 | `AccountManager.getAccount()` | 保留 |
| └ `getAccount()` | 1 / 0 | `SLLaunchBridge.swift:124` | 保留 |
| `PopupButton`（及 `ok`） | 4 / 7 | `InstallTask.swift:240,304,355`；`MinecraftInstance.swift:348`；`NoticeCenter.swift:15`；`NoticeCenterTests.swift:321,322,336,346,347,351,352` | 保留（真实现） |
| `PopupButtonStyle` | 2 / 1 | `NoticeCenter.swift:19,21`；`NoticeCenterTests.swift:347`（`.danger`） | 保留 |
| `PopupType` | 1 / 3 | `NoticeCenter.swift:62`；`NoticeCenterTests.swift:284-286` | 保留 |
| `PopupModel` | 3 / 4 | 本文件 `show`/`showAsync`；`NoticeCenter.swift:92`；`NoticeCenterTests.swift:318,336,345,350` | 保留 |
| `PopupManager`（类）/`.shared` | 4 / 0 | `InstallTask.swift:240,304,355`；`MinecraftInstance.swift:348` | 保留（已接 `NoticeCenter`） |
| ├ `isAvailable` | 0 / 0 | — | **无引用 → 已标注 deprecated** |
| ├ `show(_:)` | 3 / 0 | `InstallTask.swift:240,304,355` | 保留（真实现） |
| └ `showAsync(_:)` | 1 / 0 | `MinecraftInstance.swift:348` | 保留（真实现） |
| `CodableAppStorage` | 2 / 0 | 本文件 `AccountManager.accounts` / `accountId` | 保留（有引用，仅本文件内） |
| `Theme`（类）/`load(id:)`/`id`/`init` | 0 / 0 | 仅注释：`Features/Theme/ThemeDefinition.swift:8-13` | **无引用 → 已标注 deprecated** |

### 9.3 无引用清单（第二轮已标注 → 第三轮已全部删除）

下表 9 项于第二轮加 `@available(*, deprecated, message: "全库无引用，待清理")` 标注，
**第三轮全部实际删除**。删除前的核实结果记录如下，便于复核：

| # | 声明 | 原位置 | 删除前核实 |
| --- | --- | --- | --- |
| 1 | `URL.init(fileURLWithUserPath:)` | `Stubs.swift`（`URL` 扩展） | 0 引用；仅把 `~` 展开后转交 `init(fileURLWithPath:)` |
| 2 | `ColorSchemeOption` | `Stubs.swift` | 0 引用；配色由 `Features/Settings/AppSettingsStore.swift` 的 `accentColor` 承担 |
| 3 | `AppRouter.Route.versionList(directory:)` | `Stubs.swift` | 0 构造点 |
| 4 | `AppRouter.append(_:)` | `Stubs.swift` | 0 调用点（路由栈无入栈来源） |
| 5 | `AccountError.networkUnavailable` | `Stubs.swift` | 0 构造点 |
| 6 | `AccountError.popupNotAvailable` | `Stubs.swift` | 0 构造点 |
| 7 | `AnyAccount.isFullyImplemented` | `Stubs.swift` | 0 引用；消费方实际走 `unimplementedError` |
| 8 | `PopupManager.isAvailable` | `Stubs.swift` | 0 引用，属治理访问器 |
| 9 | `Theme`（含 `load(id:)` / `id` / `init`） | `Stubs.swift` | 0 引用；历史遗留主题模型，不参与渲染 |

**同轮一并删除的相邻项**（原在 §9.2 表中被标为「保留」，因第三轮重新核实而改判）：

| 声明 | 改判依据 |
| --- | --- |
| `URL.parent()`（连同整个 `extension URL`） | 它是兼容层语法糖，语义等价于系统原生 `deletingLastPathComponent()`。第三轮**先把 14 处调用点全部换成原生 API**、确认 `grep -rn "\.parent()"` 0 残留后，才删除该扩展 |
| `AppRouter` 类整体（含 `Route` 三个 case、`getLast()`、`removeLast()`） | 第 3、4 项删除后，其唯一剩余引用（`InstallTask` 的 `if case .installing(_) = DataManager.shared.router.getLast()`）**本身恒不成立**，先删该不可达分支、再删类与 `DataManager.router` / `routerCancellable`，详见 §5.3 |

删除前置条件（第二轮提出）与第三轮的落实方式：确认无跨 target / 运行时反射 / 条件编译引用——
工程使用 `PBXFileSystemSynchronizedRootGroup`，`project.pbxproj` 内既无 `.swift` 条目也无 `PCL`，
不存在跨 target 单独引用；全库 `grep` 逐项核实 0 残留；`./scripts/typecheck.sh` 两口径 **0 错误**、
告警**集合逐条等于基线**（口径一 44 / 口径二 56）；真实 `xcodebuild` **编译通过，0 错误**。

### 9.4 语义可疑项（仅记录，未改动）

| 项 | 位置 | 可疑点 |
| --- | --- | --- |
| `AppRouter` 路由栈无入栈来源 | `Stubs.swift`（`AppRouter`） | 全库无 `append` 调用，栈恒空 → `getLast()` 恒返回 `.other`，`InstallTask.swift:120` 的 `if case .installing(_)` 运行期永不成立，`:121` 的 `removeLast()` 实际为不可达分支。真实页面切换由 `Features/Download/DownloadDetailManager.swift` 承担。**注意：该类本身有活跃引用，不可整体删除。** |
| `AppSettings.currentMinecraftDirectory` 恒为默认值 | `Stubs.swift` | 6 处读取，全库无写入点，读到的始终是 `.default`。表面上支持「切换 Minecraft 目录」，实际不支持；UI 亦无对应入口。 |
| `AnyAccount.microsoft` / `.yggdrasil` 退化实现 | `Stubs.swift` | 两个 case 均以 `OfflineAccount` 承载，无 OAuth / 无 Yggdrasil 认证；`.yggdrasil` 仅在 `MinecraftInstance.swift:302-305` 预置 authlib-injector，不产生认证会话。详见 §1.1。 |

### 9.5 依据条目

本轮唯一涉及语法/API 的改动是新增 `@available(*, deprecated, message: "...")` 标注。

| 依据条目 | 官方链接 | 结论 |
| --- | --- | --- |
| `@available` 属性：声明生命周期；参数以平台名（`macOS` 等）或 `swift` 开头，`*` 表示「在上述所有平台可用」 | https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/ | `@available(*, deprecated, message:)` 合法 |
| `deprecated` 参数：可省略版本号，省略时同时省略冒号；`message` 为**独立参数**，语义为「编译器在标记了 `deprecated`、`obsoleted` 或 `noasync` 的声明被使用时显示的文本」 | 同上 | 本写法（`deprecated` 不带版本号 + 独立 `message:`）属官方定义范围 |
| 本地依据库条目 | `.workbuddy/skills/apple-swift-reference/references/swift-language/attributes.md`（`@available` 小节及其"常见误解"段） | 与本轮结论一致 |

`@available` 自 Swift 4.1 / Xcode 9.3 起可用，远早于本项目目标部署版本 macOS 13.0，
不存在部署版本可用性风险；本轮 `-target arm64-apple-macosx13.0` 类型检查通过（`exit = 0`）亦予佐证。
