# 伪实现与假功能审计报告

审计范围：`qwq/PCLCore/` 与 `qwq/Features/` 全量 Swift 源码。
审计分支：`refactor/modular`。
审计目标：找出「类型/接口上看似支持、运行期实际不生效」的能力，并作出治理处置。
治理原则：**不实现缺失功能，只消除静默降级**——未实现的能力必须显式表达为未实现，
而非伪装成可用或默默退化为其它行为。

## 0. 结论摘要

- 本次治理共改动 5 个文件，新增 1 个报告文件，全部为「标注 / 显式告警」级改动，不含功能实现。
- 已确认无任何 UI 入口构造 `.microsoft` / `.yggdrasil` 账号，故**未改动任何 UI 布局**。
- 任务书中列出的 `NetworkTest.hasNetworkConnection()` **在当前分支已不存在**（详见 §2.1）。
- 离线账号链路（`PCLLaunchBridge.pclLaunch` → `AnyAccount.offline`）未受影响，功能照常。

## 1. 账号系统

### 1.1 `.microsoft` / `.yggdrasil` 伪实现（高）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/PCLCore/PCLStubs.swift:193`（`case microsoft`）、`qwq/PCLCore/PCLStubs.swift:195`（`case yggdrasil`） |
| 当前行为 | 两个 case 均以 `OfflineAccount` 承载，未实现任何 OAuth / Yggdrasil 认证。`account` 计算属性 `case .offline/.microsoft/.yggdrasil` 统一返回离线账号；`putAccessToken` 写入的是「UUID 本身」这一离线令牌规则。 |
| 实际行为 | 完全等同离线登录：不请求 Microsoft 设备码流、不交换 XBL/XSTS、不访问会话服务器；Yggdrasil 仅额外预置 `authlib-injector`（`MinecraftInstance.swift:305`），但**不产生任何认证会话**。 |
| 影响 | **会误导用户**。类型层面存在 `microsoft` / `yggdrasil` case，任何依据 case 名称分支的消费方都会误判「该账号已联网认证」，实际进服为离线身份。 |
| 已完成处置 | ① 保留 case 名称不变（`CodableAppStorage("accounts")` 以 JSON 持久化，删除 case 会导致旧数据解码失败），改写注释为显式「尚未实现」；② 新增 `AnyAccount.isFullyImplemented`（`PCLStubs.swift:210`，offline 为 true，其余 false）；③ 新增 `AnyAccount.accountKindDescription`（`PCLStubs.swift:219`，如「微软账号（尚未实现，当前按离线账号处理）」）；④ 新增 `AnyAccount.unimplementedError`（`PCLStubs.swift:229`），返回对应 `AccountError`；⑤ 新增 `AccountError` 枚举（`PCLStubs.swift:161`），`errorDescription` 为中文且直述「尚未实现」，不写「登录失败」；⑥ 启动路径 `MinecraftInstance.swift:288` 对未实现账号输出 `warn` 级显式告警。 |
| 建议处置 | **标注**（已完成）。后续若要实现，需独立立项完成完整 OAuth 流程，本次不实现。 |

### 1.2 `.microsoft` / `.yggdrasil` 调用点清单（全量）

| 位置 | 用途 | 是否构造 | 处置 |
| --- | --- | --- | --- |
| `qwq/PCLCore/PCLStubs.swift:193` / `:195` | 枚举 case 定义 | — | 保留 + 标注 |
| `qwq/PCLCore/PCLStubs.swift:197` | `account` 计算属性模式匹配 | 否 | 保留 |
| `qwq/PCLCore/Minecraft/MinecraftInstance.swift:305` | `if case .yggdrasil = account` 预置 authlib-injector | 否 | 加注释说明「不代表已完成外置登录」 |
| `qwq/PCLCore/PCLLaunchBridge.swift:120` | `options.account = .offline(account)` — **全库唯一账号构造点** | 仅 `.offline` | 无改动 |

**结论：全库不存在任何 `.microsoft(...)` / `.yggdrasil(...)` 的构造点。**
搜索 `microsoft` / `yggdrasil` / `微软` / `外置登录` / `正版登录` 的全部命中均为
Java JDK 下载源（`aka.ms`、`Microsoft JDK`）与离线账号 UUID 算法注释，与账号登录无关。

### 1.3 UI 入口核查（未改动 UI）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/Features/ModBrowser/CategoryContentView.swift:230`（`TextField("离线模式用户名", ...)`）、`:272`（`offlineUsernameHint`） |
| 实际行为 | 全应用**只有离线用户名输入框，没有任何「微软登录」「外置登录」按钮或账号选择器**。 |
| 影响 | 不存在「点击后被静默降级」的入口，用户不会被诱导去点一个假按钮。 |
| 处置 | **未改动 UI**（无入口可改，且无必要）。 |

### 1.4 账号持久化层实际未被使用（中）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/PCLCore/PCLStubs.swift:238`（`AccountManager`）、`:240`（`@CodableAppStorage("accounts")`）、`:241`（`accountId`） |
| 当前行为 | 提供多账号的增删查与持久化接口。 |
| 实际行为 | **`AccountManager` 在全代码库无任何引用**（除自身定义外 0 处调用）。真实启动链路 `PCLLaunchBridge.swift:118-120` 每次直接 `OfflineAccount(safeUsername)` 新建账号，不读不写 `accounts`。 |
| 影响 | 不影响用户，但会误导维护者以为存在账号管理能力。同时说明 §1.1 中「保留 case 以兼容持久化数据」目前缺乏实际数据支撑（仍按任务要求保留）。 |
| 建议处置 | **标注**。保留 `AnyAccount` 结构不动；后续如继续重构可评估移除整个账号持久化层。 |

## 2. 网络探测

### 2.1 `NetworkTest.hasNetworkConnection()` —— 已不存在（需澄清）

| 项 | 内容 |
| --- | --- |
| 当前位置 | **当前分支不存在该符号**。`qwq/PCLCore/PCLStubs.swift` 及全库 `.swift` 文件中均无 `NetworkTest` / `hasNetworkConnection`。 |
| 历史位置 | 仅存在于初始提交 `5d5769d:qwq/PCLCore/PCLStubs.swift:174-178`，实现为 `hasNetworkConnection() -> Bool { true }`。 |
| 验证方式 | `grep -rn "NetworkTest\|hasNetworkConnection" --include="*.swift" .` → 0 命中；`git show HEAD:qwq/PCLCore/PCLStubs.swift` → 无该内容；`git log -S"NetworkTest"` 显示其在 `08e83d0` 已被移除。 |
| 影响 | 无。当前无调用方，也不存在恒真的伪网络判断。 |
| 处置 | **无需处置（已移除）**。若后续确有网络可用性需求，应新增真实探测（`URLSession` + 短超时 HEAD 请求），而非恢复恒真桩。 |

说明：本次为遵循「不实现缺失功能」与「不引入并发风险」，**未新增任何网络探测代码**。

## 3. 弹窗系统

### 3.1 `PopupManager.show(_:)` 为空实现（高）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/PCLCore/PCLStubs.swift:289` |
| 当前行为 | `public func show(_ model: PopupModel) async {}` —— 空函数体。 |
| 实际行为 | **弹窗从不显示**。调用方 `await` 后立即返回，界面上无任何反馈。 |
| 影响 | **严重误导**。三类安装失败（Minecraft / Fabric / Forge·NeoForge）均依赖它向用户报错，实际用户只会看到「安装无响应 / 详情页无后续」，无法获知失败原因。 |
| 调用点 | ① `qwq/PCLCore/Minecraft/Download/InstallTask.swift:240` —— Minecraft 安装失败提示（期望：弹出错误弹窗，按钮 `[确定]`）<br>② `qwq/PCLCore/Minecraft/Download/InstallTask.swift:304` —— Fabric 安装失败提示（同上）<br>③ `qwq/PCLCore/Minecraft/Download/InstallTask.swift:355` —— Forge / NeoForge 安装失败提示（同上） |
| 已完成处置 | 方法签名保持不变；补充文档注释明确「空实现、弹窗不会显示、调用方无法得知提示是否送达」；新增 `PopupManager.isAvailable`（`PCLStubs.swift:282`，恒 `false`）供调用方做能力探测。 |
| 建议处置 | **实现**（后续）：接入真实弹窗通道。当前先以 `isAvailable` + 注释暴露真相，避免调用方误以为已提示用户。 |

### 3.2 `PopupManager.showAsync(_:)` 恒返回 0（高）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/PCLCore/PCLStubs.swift:295` |
| 当前行为 | `public func showAsync(_ model: PopupModel) async -> Int { 0 }` —— 不展示 UI，恒返回 0。 |
| 实际行为 | 等价于「**永远点击第 0 个按钮**」，用户从未参与选择。 |
| 影响 | **严重误导**。调用方以返回值分支，非 0 分支为死代码。 |
| 调用点 | ① `qwq/PCLCore/Minecraft/MinecraftInstance.swift:336` —— 游戏非 0 退出码时弹出「Minecraft 出现错误」，按钮 `[.ok, .init(label: "导出错误报告", style: .accent)]`；期望：用户点「导出错误报告」时返回 `1` 并进入导出流程。**实际恒返回 0，「导出错误报告」分支永远不会被执行**——这是本项目中危害最直接的伪功能。 |
| 已完成处置 | 补充文档注释，明确说明返回值语义为「恒为 0，即第 0 个按钮」以及调用方分支会永久走 index == 0。签名不变。 |
| 建议处置 | **实现**（后续）：接入真实弹窗并按用户点击返回索引；或临时将调用方改为「不做分支假设」。 |

## 4. 启动取消

### 4.1 `MinecraftLauncher.isCancelled` 为 no-op（中）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/PCLCore/PCLLaunchBridge.swift:11` |
| 当前行为 | `get { false }`，`set { /* no-op */ }` —— 读恒 false，写被静默忽略。 |
| 实际行为 | 无法通过该标志取消启动；同步 `launch` 调用不支持中途取消。 |
| 影响 | 会误导调用方以为可以取消启动。**当前全代码库无任何调用点**（`grep "\.isCancelled"` 排除 `Task.isCancelled` 后 0 命中），故暂无实际用户影响。 |
| 已完成处置 | 改写注释，明确「读恒 false / 写无效果 / 不得据此判断已取消」，并指向真实可用的 `terminate()`。 |
| 建议处置 | **标注**（已完成）。如需取消能力应基于 `terminate()` 实现，本次不做。 |
| 对比 | `isUserTerminated` / `terminate()`（`PCLLaunchBridge.swift:16-24`）为**真实实现**，非桩。 |

## 5. 其他扫描发现

### 5.1 `hint()` 只写日志、不显示任何界面（高）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/PCLCore/PCLStubs.swift:26` |
| 当前行为 | `public func hint(_ message: String, _ type: HintType = .info) { log("[Hint] \(message)") }` |
| 实际行为 | PCL2 中 hint 是界面瞬时提示条；此处退化为一条日志，**用户看不到任何提示**。 |
| 影响 | **会误导用户**：关键状态变化静默化。 |
| 调用点 | ① `qwq/PCLCore/Minecraft/MinecraftInstance.swift:333` —— 「检测到 Minecraft 出现错误，错误分析已开始……」（用户看不到）<br>② `qwq/PCLCore/Minecraft/Download/InstallTask.swift:416` —— 文件下载失败（`.critical`，用户看不到）<br>③ `qwq/PCLCore/Minecraft/Download/InstallTask.swift:420` —— 文件下载完成（`.finish`，用户看不到） |
| 已完成处置 | 补充文档注释，明确「只写日志、不显示界面元素、调用后用户无感知」。 |
| 建议处置 | **实现**（后续）：接入真实提示通道。当前先标注。 |

### 5.2 `Theme` 桩实现（低）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/PCLCore/PCLStubs.swift:329` |
| 当前行为 | 只保存 `id`；`load(id:)` 仅 `Theme(id: id)`，不读主题文件、不解析配色/字体。 |
| 实际行为 | 不参与任何渲染；切换主题不产生视觉变化。 |
| 影响 | 当前**无调用方**（全库除定义外 0 处引用），暂无用户影响。真实主题由 `qwq/Features/Settings/ThemeManager.swift` 提供。 |
| 已完成处置 | 注释改写为显式「桩实现」，并指明真实主题渲染位置，避免维护者误用。 |
| 建议处置 | **移除或标注**。建议后续清理时整类删除。 |

### 5.3 `AppRouter` 路由栈无入栈点（中）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/PCLCore/PCLStubs.swift:47`（`AppRouter`）、`:37`（`DataManager.router`） |
| 当前行为 | 提供 `append` / `getLast` / `removeLast` 路由栈。 |
| 实际行为 | **全库无任何 `router.append(...)` 调用**，栈恒为空，`getLast()` 恒返回 `.other`。因此 `InstallTask.swift:120` 的 `if case .installing(_) = router.getLast()` 判断**永远不会成立**，其中的 `removeLast()`（`:121`）是死代码。真实页面切换由 `DownloadDetailManager` 负责。 |
| 影响 | 不影响用户；误导维护者以为存在路由系统。 |
| 建议处置 | **标注 / 移除**。本次未改动（涉及 `InstallTask.complete()` 逻辑，改动收益低于风险），仅记录于此。 |

### 5.4 `AppSettings` 部分字段恒为默认值（低）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/PCLCore/PCLStubs.swift:65`（`currentMinecraftDirectory`） |
| 当前行为 | 声明为可配置项，默认 `.default`。 |
| 实际行为 | **全库无任何写入点**（`grep "currentMinecraftDirectory ="` → 0 命中），恒为 `.default`。 |
| 影响 | 用户无法切换 Minecraft 目录，但界面上也无对应入口，暂无欺骗性。 |
| 说明 | 同类的 `fileDownloadSource` / `versionManifestSource` 有真实写入与读取（`qwq/PCLCore/Download/DownloadSourceManager.swift:40,49,69,132`），为**真实实现**。 |
| 建议处置 | **标注**。 |

### 5.5 `InstallTask` 基类三个空/常量默认实现（低）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/PCLCore/Minecraft/Download/InstallTask.swift:46`（`start() { }`）、`:48`（`getInstallStates() { [:] }`）、`:50`（`getTitle() { "" }`） |
| 当前行为 | 基类默认空实现。 |
| 实际行为 | 可独立启动的任务（`MinecraftInstallTask:234`、`CustomFileDownloadTask:409`、`ModFileDownloadTask:39`）均已覆写 `start()`；`FabricInstallTask` / `LoaderInstallTask` 及其子类**不覆写 `start()`**，因为它们由 `MinecraftInstaller.swift:376-380` 通过 `install(_:)` 驱动，**从不经过 `start()`**。`getInstallStates` / `getTitle` 在各具体任务中均已覆写。 |
| 影响 | 当前无缺陷。但若未来有人对加载器任务直接调用 `start()`，将静默无动作。 |
| 已完成处置 | 补充注释，说明「子任务经 `install(_:)` 驱动、调用 `start()` 不会生效」。 |
| 建议处置 | **标注**（已完成）。 |

### 5.6 `DownloadSource.getAssetURL` 协议默认返回 `nil`（可接受，非缺陷）

| 项 | 内容 |
| --- | --- |
| 位置 | `qwq/PCLCore/Download/DownloadSource.swift:24` |
| 实际行为 | 默认 `nil`；`OfficialDownloadSource:56`、`BMCLAPIDownloadSource:90` 均已覆写，行为正确。 |
| 处置 | **无需处置**。属合法协议默认值。 |

### 5.7 TODO 清单（非伪实现，仅记录）

| 位置 | 内容 | 影响 |
| --- | --- | --- |
| `qwq/Features/Download/ModpackInstaller.swift:143` | `// TODO: 后续集成 PCL 核心的 InstallTask` | 整理包安装当前不走统一任务系统，进度展示可能与整数包下载不一致。 |
| `qwq/PCLCore/Minecraft/ClientManifest.swift:248` | `// TODO: 处理 arch（官方 macOS JSON 基本不含 arch 规则，风险低）` | 影响面低，已知并接受。 |

### 5.8 形似伪实现、实为用户可见占位（排除）

以下两项名称含「占位」，但均为**真实可用的 UI/状态**，不属于伪实现，特此排除：

- `qwq/Features/ModBrowser/CategoryCanvasPlaceholder.swift` —— 分类切换时的静态中间页视图，被真实渲染。
- `qwq/PCLCore/Minecraft/Mod/Loader/LoaderSupportChecker.swift:246` —— `.checking` 为「尚未定论」状态，UI 有对应展示，且代码显式禁止将其当作结论。

## 6. 改动文件清单

| 文件 | 改动性质 |
| --- | --- |
| `qwq/PCLCore/PCLStubs.swift` | 新增 `AccountError`；`AnyAccount` 新增 `isFullyImplemented` / `accountKindDescription` / `unimplementedError`（case 名称不变）；`hint` / `PopupManager` / `Theme` 补齐显式桩说明；`PopupManager` 新增 `isAvailable`。 |
| `qwq/PCLCore/Minecraft/MinecraftInstance.swift` | 启动路径对未实现账号输出显式告警；Yggdrasil 预置 authlib-injector 处补注释澄清。 |
| `qwq/PCLCore/PCLLaunchBridge.swift` | `isCancelled` 注释明确 no-op 语义与正确替代（`terminate()`）。 |
| `qwq/PCLCore/Minecraft/Download/InstallTask.swift` | 基类 `start` / `getInstallStates` / `getTitle` 补充语义注释。 |
| `qwq/PCLCore/STUBS_AUDIT.md` | 本报告。 |

## 7. 验证结果

命令：

```
cd /Users/apple/Downloads/Swim111Launcher_副本
xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps $(find qwq -name "*.swift")
```

结果：`exit = 0`，`grep -c "error:"` = **0**，`warning` 16 条均为改动前既有告警
（Swift 6 并发严格模式相关，与本次改动无关）。

## 8. 需人工决策的遗留项

以下各项未在本次改动（改动面超出「标注」范畴或存在回归风险）：

1. **`PopupManager` 接入真实弹窗** —— 需确定弹窗承载方式（SwiftUI sheet / `NSAlert`）与全局挂载点，影响 `MinecraftInstance.swift:336` 的错误报告导出分支。
2. **`hint()` 接入真实提示通道** —— 需先确定提示 UI 形态。
3. **`AnyAccount.microsoft` / `.yggdrasil` 是否长期保留** —— 本次按要求保留 case；但 §1.4 表明持久化账号层当前无任何调用点，保留理由暂无实据，需人工确认历史数据是否真实存在。
4. **`AppRouter` 与 `AccountManager` 是否删除** —— 均为无引用死代码，删除可减小误导面，但超出本次治理范围。
5. **`AppSettings.currentMinecraftDirectory` 是否补 UI 入口** —— 属新功能，本次不做。
