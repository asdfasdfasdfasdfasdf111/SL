> 🗄️ **本文已归档（2026-10-05）**：内容为 SLOP-AUDIT-2026-10-02-REV3-SOURCE.md 撰写时点的历史快照/审计记录，
> 其中的行号、计数、现状描述**可能已失效**，勿据此判断当前代码。现状请以
> `ARCHITECTURE.md` / `HANDOVER.md` / `README.md` 及代码本身为准。

# 源码级取证复核与处置：SLOP-AUDIT-2026-10-02-REV3

> 2026-10-02 深夜。本文回答：源码取证报告《只看 `.swift` 文件的取证》的每一条
> 指控是否成立、已如何处置。与 REV2（宏观数字）互补——REV2 讲耦合/冗余/覆盖的
> 统计，本文逐条落到**文件与行号**，并记录「已修 / 判定非问题」两类结论。
>
> 处置原则：凡「自证死代码」（源码注释自己写明全库无引用/从未执行/零调用方）
> 且删除不影响行为的——删除并把必要结论归档到代码注释；凡「复核后判定非问题」
> 的——如实说明为什么不动，避免下一轮审计重复立案。

---

## 1. 处置总账（提交 `07a43c2`）

| 项 | 报告指控 | 复核实测 | 结论 |
|---|---|---|---|
| ① | `GameProcessController.waitForTermination()` 从未执行 | 方法带 `@available(*, deprecated, message: "全库无引用，待清理")`，自陈依赖未接线的 `InMemoryGameSessionStore`；全库（含测试）零引用 | **已删**；竞态结论（先挂 handler 再补检状态、一次性门控恰好 resume 一次）归档到文件头注释 |
| ② | `LauncherError` 5 个 case 零抛出点 | 文件头自陈：`noJavaFound` / `noGameDirectoryFound` / `noVersionsFound` / `versionJsonMissing` / `versionJarMissing` 只活在 `errorDescription` 的 switch 里；对应场景已由 `JavaResolver` / `hint()` 提示 | **已删**（case + 文案分支），文件头说明同步更新 |
| ③ | `MinecraftCrashHandler.exportErrorReport` 零调用方 | 全库 grep 只命中本定义；其私有依赖 `copyGameLogs` 只被它调；"导出错误报告"能力未接线（`PopupManager.showAsync` 自陈） | **已删**（exportErrorReport + copyGameLogs）；保留 `lastLaunchCommand`（`MinecraftLauncher.swift:78` 在写） |
| ④ | `InstallState.getImageName()` 零调用方 | 注释自陈 2026-09-23 起零调用方；UI 走 `DownloadDetailView.iconName(for:)`（SF Symbol）；`inprogress`/`failed` 返回占位串 `"Missingno"` | **已删** + 同步删 `InstallProgressTests` 中 2 个测死方法的用例（10→8） |
| ⑤ | `LoaderSupportVersionRules.displayName(for:)` 无调用方 | 零调用方（`key(for:)` 是显示名→key 正向映射，被 `LoaderSupportProbe.swift:53` 使用；反向映射无消费点） | **已删**；文件头职责说明同步 |
| ⑥ | `ModDownloader.ModError.invalidURL` 全库无引用 | 注释自陈「无任何构造点」（`downloadMod` 解析主文件地址失败时改抛 `noDownloadableFile`）；`ModpackDownloader.invalidURL` 是**独立枚举**不受影响 | **已删**（case + 文案分支） |
| ⑦ | 假邮箱 UA `qwq@example.com` | `LocalModCatalog.swift:193` 是唯一写死假邮箱处；全库其余 6 处请求头统一用 `SharedConstants.shared.userAgent` | **已修**：改为 `SharedConstants.shared.userAgent`（`"Swim111Launcher/1.0 (Minecraft Launcher)"`） |

## 2. 复核后判定「非问题」的指控（不删，说明理由）

| 项 | 报告指控 | 复核发现 | 为什么不改 |
|---|---|---|---|
| A | `TemperatureDirectory.swift` 是死工具，「唯一使用点是 CrashHandler（未接线）所以跑不到」 | **误判**：`ForgeInstaller.swift:35` 是活使用方（Forge 安装链用它做工作目录）；头注释第 3 条确实过时（记录的是 CrashHandler 接线前的旧事实） | 活代码不删；改其头注释为如实描述（活使用方 = ForgeInstaller；原 CrashHandler 用法已随 ③ 删除） |
| B | `MinecraftConfig.additionalLibraries` 死字段「勿删，保留兼容 .SL.json」 | 注释自陈：有写入方（CodingKeys + `init(_ json:)` 自编解码），**无读取方**，但删除会破坏既有 `.SL.json` 字段解析 | **有意兼容保留**：删除会让旧配置解码丢字段/失败。保留但这是「兼容债」不是死代码——如实记录，不改 |
| C | 假功能：AnyAccount 三账号全是离线，UI 能选微软/外置「静默退化」 | 复核后发现两点与报告不符：① 工程**没有**账号选择 UI（全库无 Picker/选项入口，只有离线账号持久化）；② 非「静默」——`AnyAccount.unimplementedError` 会区分未实现种类并给出 `AccountError`（文案「尚未实现…请使用离线模式」），`SLLaunchBridge` 的未实现账号告警分支消费它（先 `warn` 再 `hint(.critical)`） | 枚举保留 `.microsoft`/`.yggdrasil` 形状是**为了历史持久化数据解码兼容**（注释自述）——删 case 旧数据解码失败。已实现部分已是「显式告警 + 明确文案」，不属「静默假装支持」，本轮不动；实现 OAuth 属新功能超出清理范畴 |
| D | 字符串判类型：`NoticeCenter.swift:107` 按钮文字决定业务行为 | 属实（`model.buttons.contains { $0.label.contains("导出") }`），但它是旧 `PopupModel` → `Notice` **迁移桥**（注释自陈「保持 PopupManager 调用点语义不变」）；活调用方（MinecraftInstallTask/LoaderInstallTasks）只用 `.ok` 按钮，无「导出」文字，该判断在活路径返回 false | 行为无影响；改动需动 PopupModel/Notice 构造链，影响面 > 收益。记入「后续可改」 |
| E | 字符串判加载器：`MinecraftInstanceInfo.swift:49` `contains("neoforged")`，自认无法识别 quilt | 属实（`manifestText.contains("neoforged") → .neoforge`） | 这是**加载器探测**的既有决策（识别 quilt 需要额外规则），改它改变探测行为，超出「清理死代码」范畴；记入后续 |

## 3. 报告路径/数字勘误

1. `MinecraftInstanceInfo.swift` 实际在 `qwq/Core/Minecraft/Module/`（报告写 `qwq/SLCore/Minecraft/`）——文件搬家后报告路径未更新，行号 `:49` 与内容一致。
2. 「自陈死代码 13 处」→ 实测 12 处 grep 命中（含 2 处真代码 `@available(*, deprecated)`：`ModDownloader.swift:343`、`GameProcessController.swift:55`；其余为注释自陈）。
3. 「Application Support 路径构造 24 处」→ 字面 grep `"Application Support"` 10 处（口径差异：报告可能计入间接构造；方向成立）。
4. 「`SL启动器/Skins` 5 文件手工拼」→ 实测 4 处（方向成立，少 1 处）。
5. 「生产 `Task.sleep/asyncAfter` 16+ 文件」→ 实测 **27 个文件**（比报告更强）。
6. 「3 套 UA」→ 复核实测 3 套形态存在，其中假邮箱已在本次处置中消除（见 §1⑦）。

## 4. 验证（全部可重跑）

- `./scripts/typecheck.sh`：两口径 **0 错误**，告警 112/24 与基线一致（逐条 diff 无新增）。
- 真实编译：`xcodebuild build`（fresh derived data）**BUILD SUCCEEDED**。
- 全量测试：**705 passed + 2 skipped + 0 failed，TEST EXECUTE SUCCEEDED**
  （基线 707 passed + 2 skipped，删除 2 个死代码用例后精确减 2）。
  前两轮触发已知工具链 abort（`pointer being freed was not allocated`，Xcode 26.2
  隔离析构缺陷，与本次改动无关，既有处置是换 fresh derived data 重试），第三轮全绿。
- `InstallProgressTests` 单跑：8/8 通过。

## 5. 仍存续的「认知 100 分、闭环 0 分」部分

### 5.1 已闭环（提交 `2af498f` / `380ab06`，2026-10-02 续轮）

- ✅ 错误分类靠中文文案 `contains`（`NetDownloaderDownloadEngine` 的 4 个 contains 分支
  ——HTTP 状态码 / 哈希校验失败 / 磁盘空间不足 / 超时）**全部删除**：
  `NetDownloadError` 增加 `checksumMismatch`/`diskFull`/`httpStatus`/`timeout` 精确 case；
  NetSliceFetcher / NetMerger / NetDownloader 抛点直接抛精确 case；
  `FileRecord.failureKind` 在失败落地为文案的同一刻置位（`sliceFailed` / `merge` catch 经
  `NetManager.failureKind(of:)`），`waitForCompletion` / `download` 经 `structuredError`
  按类别抛出；适配层 switch 直达 `DownloadError`，`unknown` 只收容真正未知的失败。
- ✅ `syntheticTotalBytes = 1000` 假进度分母（`:32`/`:239-240`）**删除**：
  `DownloadProgress` 新增 `fractionOverride` 轨道——总大小未知时旧引擎直传的 0…1
  比例走独立轨道，字节字段保持诚实（`bytesWritten = 0` / `totalBytes = -1`，不再伪造）；
  已知大小时字节推导优先，`fractionOverride` 被忽略。`DownloadStateTests` 新增
  `testFractionFallsBackToOverrideWhenTotalBytesIsUnknown` 钉优先序与钳制。
- ✅ 字符串契约补盲：`Category` 新增 `CategoryKind` 枚举，`CategoryContentView` 分派改按
  `kind` switch（`name` 退化为纯文案，改文案不再静默落空、switch 穷尽由编译器保证）；
  `PopupModel` 新增显式 `allowsReportExport` 字段，删除 `Notice.init(from:)` 里
  「按钮 label 含『导出』」的推导；`MinecraftLauncher.init?` 去可失败签名、
  `process.arguments!` ×3 与 `MinecraftLauncher(instance)!` 强解包全部消除。

### 5.2 仍存续（旧清单中未动的部分）

- `VersionUtils.normalizeVersionFolderNames` 是「本文件唯一会写磁盘的方法」
  （重命名版本目录 + 改写 json 的 id），本职是列版本列表，兜底动用户真实文件。
- 测试层：`GameSessionStoreTests` 睡等（`Task.sleep 120/220ms` ×5）、
  `LaunchStateTests` 自陈纯协议未覆盖（已补 `LaunchPreflightTests`；`LaunchService`/
  `GameProcessController`/`LaunchArgumentBuilder` 仍无实现）、CrashReporter/DataManager/
  MultiFileDownloader 测试零触达。
- 注释文化病：考古注释（GameProcessController 竞态史）、哲学辩论注释
  （GameSessionStore「待接线不是待清理」）、自证注释（DownloadCategoryViewModel
  文件头 30 行）、认错注释（VersionUtils「横跨三层」）——保留原样，记录在案。