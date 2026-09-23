# Adapters 迁移说明

本目录只放**适配器**：把 `qwq/Core/Download/` 的协议接到现有实现上，不改变任何下载行为，也不切换调用方。
当前状态：`NetDownloader.swift`（`NetManager`）仍是唯一实际生效的下载路径；`DownloadEngine` 已由
`Features/Download/ModFileDownloadTask.swift` 首个接入，并由
`SLCore/Minecraft/Mod/Loader/Forge/ForgeInstaller.swift` 的两处**单文件**下载第二个接入，
再由 `FabricInstaller`、`MinecraftInstaller` 的三个前置单文件、`CustomFileDownloadTask`、
`downloadAuthlibInjector` 第四个批次接入（均见「六、切换记录」）；
**批量调用方（`MultiFileDownloader` 各调用点）与绕过引擎的 `URLSession` 直连路径仍走旧链路**。

## 一、新增文件与职责

| 文件 | 职责 |
| --- | --- |
| `DefaultDownloadSourceResolver.swift` | 实现 `DownloadSourceResolver`，委托 `DownloadSourceManager` 判定主源/互补源与 `.both` 模式 |
| `DefaultDownloadVerifier.swift` | `DownloadVerifier` 的 CryptoKit 实现复用 + 与旧 `FileChecker.check` 逐字等价的重载入口 |
| `NetDownloaderDownloadEngine.swift` | 实现 `DownloadEngine`，后端为 `NetManager`，把回调式进度转换成 `AsyncStream<DownloadState>` |

### 旧引擎的真实对外入口

```swift
// NetManager.download(_:progress:)
NetManager.shared.download(_ file: SLNetFile, progress: ((Double) -> Void)? = nil) async throws
// NetManager.downloadAll(_:overallProgress:onFileCompleted:)
NetManager.shared.downloadAll(_ files: [SLNetFile], overallProgress: ((Double, Int) -> Void)?, onFileCompleted: (() -> Void)?) async throws
```

关键事实：

- 进度是 **0…1 的比例**（不是字节），且在「已存在且校验通过 → 跳过」分支同样回调 `1.0`；
- 进度回调由 `NetManager` 自行切到 `@MainActor`（`NetDownloader.swift`）；
- **取消以 Swift Task 取消表达**：`waitForCompletion` 内 `Task.checkCancellation()`（`NetDownloader.swift`）
  会在取消时抛出，`download` 的 `catch` 随即取消全部分片任务并清理临时文件（`NetDownloader.swift`）；
- 输入类型 `SLNetFile(urls:destination:checker:replaceMethod:)`，覆盖率策略（`.skip` / `.replace` / `.throw`）与
  校验参数（`FileChecker`），`DownloadRequest` 中都没有对应字段。

### 适配器的对接方式

1. `DownloadRequest` → `SLNetFile`
   - `urls`：`DefaultDownloadSourceResolver.candidateURLs(for:)`（请求主源优先，`.both` 模式下补镜像）；
   - `checker`：`DefaultDownloadVerifier.checker(for:)`，`sha256` → `sha1` 取非空者，`expectedSize` → `actualSize`；
   - `replaceMethod`：`submit(_:)` 用引擎级缺省 `.skip`，需要 `.replace` / `.throw` 的调用方走
     `submit(_:replaceMethod:)` 重载（该重载不在 `DownloadEngine` 协议内）。
2. 进度 → `AsyncStream<DownloadState>`
   - 一次 `download` 调用对应一次 `preparing → downloading* → (completed | cancelled | failed)`；
   - `observe` 立即回放当前状态；终态发布后任务从台账移除并进入 256 条上限的终态回放缓存，
     任务结束后再 `observe` 仍能拿到终态，未知 taskID 返回已结束的空流；
   - 未丢事件：`AsyncStream` 用无界缓冲，终态先 `yield` 后 `finish`；旧引擎把进度节流到约 200ms 一次，
     不存在积压风险；
   - 未泄漏：任务结束即从台账移除（散列资源可达数万项，不能无界保留）；`run` 持有 `self` 强引用，
     循环引用随台账移除解除；事件流在取消与失败路径上同样 `finish`。
3. 取消：`cancel(taskID:)` 置位标记并取消承载下载的 Task，旧引擎自行清理，无需重复实现。

## 二、现有调用方清单与切换改动

直接触达 `NetManager` 的只有两个薄封装，其余调用方全部经由它们：

- `qwq/SLCore/Download/SingleFileDownloader.swift` → `NetManager.shared.download(file) { p in ... }`
- `qwq/SLCore/Download/MultiFileDownloader.swift` → `NetManager.shared.downloadAll(...)`

上层调用方（行号为实际调用点）：

| # | 调用方 | 形态 | 切换需要改什么 |
| --- | --- | --- | --- |
| 1 | `Features/Download/ModFileDownloadTask.swift` | 单文件 `SingleFileDownloader.download(task:url:destination:replaceMethod:.replace)` | 只换提交方式；进度写入 `currentStagePercentage`、成功 `completeOneFile()/complete()`、失败 `failureReason` 需分别由 `observe` 流与 `DownloadHandle` 承担（**已切换**） |
| 2 | `SLCore/Minecraft/Download/MinecraftInstaller.swift` | 单文件（客户端清单），`.replace` | 同上；`.replace` 必须显式传 `replaceMethod:`（**已切换**） |
| 3 | `MinecraftInstaller.swift` | 单文件（客户端 jar），`expectedSHA1` + `stage: .clientJar` | `expectedSHA1` → `request.sha1`；`stage` 的 `beginParallelStage/finishParallelStage` 需在流的终态处配对，否则并行阶段计数不归零（**已切换**） |
| 4 | `MinecraftInstaller.swift` | 单文件（资源索引），`expectedSHA1` | 同上（**已切换**） |
| 5 | `MinecraftInstaller.swift` | 批量 `MultiFileDownloader(task:items:stage:)`（散列资源 / 依赖库 / natives） | 需把批次拆成每文件一个 `submit`，批进度与 `onFileCompleted` 由各任务状态聚合；这一组与 `InstallTask` 的总文件数/剩余文件数耦合最深 |
| 6 | `SLCore/Minecraft/Launch/LaunchFix.swift` | 批量 `MultiFileDownloader(items:concurrentLimit:32)` | 同 5，且并发上限 32 在旧链路由 `NetManager.config.maxSlices` 统一兜底，新链路需确认调度器等价 |
| 7 | `SLCore/Minecraft/Mod/Loader/Forge/ForgeInstaller.swift` | 单文件（mappings / installer） | 同 2、3；`ForgeInstaller.swift` 的进度回调按 `progress * 0.2` 折算，需在状态流上做同样折算（**已切换**） |
| 8 | `ForgeInstaller.swift` | 批量 `MultiFileDownloader(urls:destinations:replaceMethod:.skip)` | 同 5；`.skip` 为缺省值，可不传 |
| 9 | `SLCore/Minecraft/Mod/Loader/Fabric/FabricInstaller.swift` | 单文件，`.replace` | 同 2（**已切换**） |
| 10 | `SLCore/Minecraft/Launch/MinecraftLauncher.swift` | 单文件（authlib-injector） | 同 2；`MinecraftLauncher.swift` 的 `FileChecker(sha256).check` 预检**保持原样**（移入请求会改变校验时机与文案，**已切换**） |
| 11 | `SLCore/Minecraft/Download/InstallTask.swift` | 单文件 + 进度 | 同 1（**已切换**） |
| 12 | `SLCore/Download/DownloadSourceManager.swift` | 测速自用（内部 `SingleFileDownloader`） | **保持旧链路**。若改为 `DownloadEngine`，resolver 委托 `DownloadSourceManager` 会形成「测速 → 下载 → 解析源 → 测速」递归 |
| 13 | `Features/Download/ModpackDownloader.swift`、`Features/ModBrowser/ModDownloader.swift` | 绕过引擎直接用 `URLSession.download` + `FileChecker` 校验 | 未纳入本轮适配面；若统一，需补 `expectedSize` + `sha1` 请求，并保留「校验失败删除已落盘文件」的行为 |

间接编排（无直接下载调用，仅需跟随上游改动）：
`Features/Game/GameVersionDownloadStarter.swift`、`Features/Download/ModFileDownloadStarter.swift`。

## 三、建议切换顺序

按「影响面 × 耦合度」从低到高，每步可独立回滚：

1. **`ModFileDownloadTask`（#1）**——单文件、单 URL、无哈希、固定 `.replace`，失败与进度已由自身 UI 明确承载，
   不参与 `InstallTask` 的并行阶段计数与总文件数统计。切换后唯一受影响的功能就是详情页的单文件下载。
2. `FabricInstaller`（#9）、`ForgeInstaller`（#7）的单文件下载：语义简单，失败即抛。
3. `MinecraftInstaller` 的三个**前置小文件**（#2/#3/#4）：单文件、有 sha1，但处在安装关键路径，
   需连同 `stage` 计数一起验证。
4. `ForgeInstaller` 的批量依赖（#8）：第一条批量路径，用来验证多点提交下的全局并发与批进度聚合。
5. `LaunchFix`（#6）：批量 32 并发 + `FileChecker` 预检，数据量大，用来压测吞吐不回退。
6. `MinecraftInstaller` 的散列资源 / 依赖库 / natives（#5）：与并行阶段计数耦合最深，放最后。
7. 统一 #13 的两处 `URLSession` 绕过路径。
   `DownloadSourceManager.testSpeed`（#12）不迁移。

第一个目标是 `ModFileDownloadTask`：单文件、无批处理、无 checksum、无阶段计数，且已有明确的成功/失败呈现，
是唯一一个「切换后行为变化可被用户直接观察到、出了问题也只影响一个下载」的调用方。

## 四、切换时必须保持一致的行为

以下每一条被破坏，都会表现为「下载看起来成功但文件是坏的」或「原本能成功现在失败」：

1. **校验失败必须删除目标文件再抛错**。旧 `merge` 在校验不过时先 `removeItem` 再抛（`NetDownloader.swift`）。
   若只抛不删，文件残留后下次 `.skip` 预检会命中并跳过（无 checker 时永远跳过），坏文件被永久固化。
2. **哈希算法按长度自动判定且大小写不敏感**：`<35` 用 MD5、`==64` 用 SHA256、其余用 SHA1，比较前统一小写
   （`NetDownloader.swift`）。`CryptoKitDownloadVerifier` 只支持 SHA1/SHA256，32 位 MD5 场景若走协议方法
   （`sha1`/`sha256` 都传 nil）会**静默不做校验**。迁移阶段必须走 `DefaultDownloadVerifier.verify(fileAt:checker:)`，
   或先补 MD5 支持。
3. **预检语义**：`.skip` + 文件存在 + 校验通过 → 跳过且不重下；存在但校验不过 → 删除重下；
   完全没有校验要求 → 存在即跳过。若新链路默认变成「总是重下」或「存在即不校验」，离线/断网场景会从成功变失败。
4. **`expectedSize` 是「必须相等」，`minSize` 是「至少」**，两者语义不同不可互相取代。`DownloadRequest` 只有前者，
   旧链路带 `minSize` 的调用方在迁移前需先确认是否仍有此约束。
5. **服务端忽略 Range 的降级路径必须保留**：分片请求返回 200 时判定该源不支持断点续传并拉黑（只准单线程）
   （`NetDownloader.swift`）。丢失该判定会继续按 Range 语义拼接 200 的全量响应，文件长度错乱。
6. **分片合并只拼「有数据」的分片且必须按 offset 升序**（`NetDownloader.swift`）；
   传输提前断流仍有剩余时必须判失败走断点续传，不能当作完成（`NetDownloader.swift`）。
7. **资源保护参数**：全局分片上限 16、单文件 >4MB 才分片、>50MB 时做磁盘空间预检、
   慢速检测（间隔 >1s 且 <1KB/s）与分片 5 分钟总超时、单源失败 3 次阈值、连接层错误直接淘汰该源
   （`NetDownloader.swift`）。这些决定「不会把磁盘写满 / 不会无限重试」。
8. **取消与失败必须清理临时分片**（`SharedConstants.temperatureURL` 下的 `.tmp`，`NetDownloader.swift`），
   否则缓存目录持续膨胀。
9. **进度口径是 0…1 比例而非字节**，且跳过分支回调 `1.0`；调用方依赖该回调完成计数（旧 `progress(1.0)` 在
   `NetDownloader.swift`）。
10. **`.both` 模式才追加互补源**，用户手动限定「仅官方 / 仅镜像」时不得跨源兜底（`DownloadSourceManager.swift`）；
    候选列表顺序以请求主源为第一位。
11. **`MultiFileDownloader` 的批进度 `(Double, Int)` 已是全批 0…1**（`MultiFileDownloader.swift` 的注释），
    聚合新链路进度时不得再次除以文件总数。

## 五、已知能力缺口（迁移前需补齐）

- `DownloadRequest` 不携带覆盖策略与 `minSize` / `isJson`，需靠 `submit(_:replaceMethod:)` 与调用方预检补齐；
- 镜像主源场景无法从裸 URL 反推官方备用地址，解析器只能给出单源（官方 URL 由 version_manifest 动态提供）；
  调用方若持有 provider，应在构造请求前自行解析成多个候选，或在后续迭代把 provider 语义上提到 resolver；
- 每文件速度旧引擎按全局统计，适配器一律填 0，`DownloadProgress.estimatedRemaining` 在迁移完成前恒为 nil；
- 总大小未知时适配器用固定分母 1000 承载比例（`syntheticTotalBytes`），仅保证 `fraction` 口径不变，
  不等价于真实字节数。

## 六、切换记录

### 2026-09-20 · 第 1 步：`ModFileDownloadTask`（#1）

**改动文件**

- `qwq/Features/Download/ModFileDownloadTask.swift`（唯一调用方改动）
- `qwq/Core/Download/Adapters/NetDownloaderDownloadEngine.swift`（补「旧文案回放」能力，见下）

**改动要点**

1. 对外接口不变：`init(url:destination:title:)`、`getTitle()`、`getProgress()`、`start()`、
   `getInstallStates()`、`failureReason`、`onComplete(_:)` 全部保持原样，调用方
   `ModFileDownloadStarter` 与 `DownloadDetailView` 无需改动。
2. 内部改为：构造 `DownloadRequest(url:destinationURL:)` → `engine.submit(_:replaceMethod:.replace)`
   → `for await` 消费 `engine.observe(taskID:)` → 按状态更新进度并映射终态。
3. 引擎实例为任务私有属性；其 `run` 仍调用 `NetManager.shared.download`，全局分片额度、
   慢速检测、磁盘预检、临时文件清理等调度状态不变。
4. 适配器新增 `legacyFailureReason(taskID:)`：终态发布时一并保留旧链路原始描述
   （`(error as? LocalizedError)?.errorDescription ?? error.localizedDescription`），
   与终态回放缓存同生命周期（上限 256）。原因是结构化 `DownloadError` 会归一化文案，
   见下一条。

**行为一致性：已确认等价**

- **提交形态**：单 URL + 固定 `.replace`。`DefaultDownloadSourceResolver` 仅在 host 属官方
  域名族且 `fileDownloadSource == .both` 时追加互补源；本任务 URL 来自 Modrinth / CurseForge CDN
  （`DownloadFileResolver` → `ModDownloader` / `ModpackDownloader`），候选列表恒为单元素，
  与旧 `SingleFileDownloader` 的单 URL 传参一致。
- **覆盖与校验**：旧链路 `checker: nil` + `.replace`；新链路 `DefaultDownloadVerifier.checker(for:)`
  在无 `expectedSize` / 哈希时返回 `FileChecker(actualSize: -1, hash: nil)`。`.replace` 下
  `precheck` 恒为 `.download`，合并后的 `checker.check` 对空期望值返回 `nil`，两者均不产生
  跳过、删除或校验失败分支，行为等价。
- **进度口径**：旧回调为 0…1 比例；`DownloadProgress.fraction` 在无 `expectedSize` 时以
  `syntheticTotalBytes = 1000` 为分母，`fraction` 即同一比例（适配器已 clamp）。进度节流
  （旧 `reportProgress` 约 200ms 一次）与回调节流位置（`NetManager` 内切 `@MainActor`）均未改变。
- **进度终值**：旧链路成功前固定回调 `progress(1.0)`；新链路在 `.completed` 分支显式
  `currentStagePercentage = 1`，终值一致。
- **成功路径**：`.completed` → `state = .finished` → `completeOneFile()` → `complete()`，
  与原实现的调用与顺序一致。差异仅为 `completeOneFile()` 的调用次数由 2 次降为 1 次
  （旧 `SingleFileDownloader` 内部还会再调一次），`remainingFiles` 由 `max(0, …)` 兜底，
  1 → 0 的结果不变，仅少一次无值变化的 `objectWillChange`。
- **失败文案**：旧实现取 `error.localizedDescription`。`NetManager.download` 在本任务可达的
  失败仅两类：`NetDownloadError.fileFailed(x)`（`x` 为 "所有下载源均不可用" / "远程服务器返回了 NNN" /
  "分片下载超时（5 分钟）" / "磁盘空间不足，需要至少 A B，当前仅剩余 B B" / 底层错误描述）与
  `CancellationError`。新链路通过 `legacyFailureReason(taskID:)` 回放同一描述，逐字一致。
  **这是本次唯一需要补能力的地方**：适配器原有的 `map(_:)` 会把 http 状态码、超时、磁盘不足
  归一化为 `DownloadError.httpStatus` / `.timeout` / `.diskFull`，其 `errorDescription`
  （如「远程服务器返回了 404。」）与旧文案（「下载失败：远程服务器返回了 404」）不同，且
  `.diskFull` / `.timeout` 已丢失原始字节数与超时类型，无法反向还原；若直接使用结构化文案，
  404、磁盘不足、慢速三类失败的用户可见文案会发生变化。故以原始描述为准，结构化错误仅在
  原始描述缺失时兜底。`map(_:)` 自身的分类规则未改动，`DownloadState.failed` 仍是结构化错误。
- **失败即上报**：两类路径都在终态调用 `complete()`，与旧实现一致（失败也会触发 `onComplete`
  → 关闭详情页 + 弹窗，`failureReason` 非 nil）。

**行为一致性：无法完全确认**

- `observe` 与 `submit` 之间存在并发窗口（下载可能在 `observe` 调用前已终结）。适配器以
  终态回放缓存覆盖该窗口，理论上不会漏终态；未做运行时压测验证。
- `.cancelled` 分支在本任务不可达（新旧均无对外取消入口），仅作兜底：映射为失败呈现，
  `failureReason` 取旧文案或「下载已取消。」。缺少旧链路对照，属新增行为，但无触发路径。

**取消路径**

- `ModFileDownloadTask` 改造前后均**未提供**对外取消入口，调用方 `ModFileDownloadStarter`
  也未持有取消能力，因此本次不存在需要保持的取消路径，接口未新增 `cancel`。
- 代码路径层面确认穿透成立：`NetDownloaderDownloadEngine.cancel(taskID:)` → `markCancelRequested`
  + 取消承载下载的 `Task` → `NetManager.waitForCompletion` 内 `try Task.checkCancellation()`
  抛出 → `download` 的 `catch` 执行 `cancelRecords`（取消全部分片 + `cleanupTemps`）后重抛 →
  适配器 `catch` 判定 `isCancellation` → 发布 `.cancelled`。**未做运行时验证**（无调用入口）。

**验证**

- `xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps $(find qwq -name "*.swift")`
  → `exit=0`，`grep -c "error:"` = 0（改造前基线同为 0）。
- `git diff` 仅涉及上述两个 Swift 文件与本节文档，未改动 `NetDownloader.swift`、其它调用方或无关代码。

**下一个建议切换目标**

- 按第三节顺序，第 2 步为 `FabricInstaller`（#9）与 `ForgeInstaller`（#7）的**单文件**下载：
  同为「单文件 + `.replace`」形态，可直接复用本步模式，但需注意 `ForgeInstaller.swift`
  的进度回调按 `progress * 0.2` 折算，须在状态流上做同样折算。
- `MinecraftInstaller` 的前置小文件（#2/#3/#4）顺延其后，原因是需与 `stage` 计数配对。

### 2026-09-20 · 第 2 步：`ForgeInstaller` 的单文件下载（#7）

**改动文件**

- `qwq/SLCore/Minecraft/Mod/Loader/Forge/ForgeInstaller.swift`（唯一调用方改动，+45/-2）
- 适配器未改动：`legacyFailureReason(taskID:)`（第 1 步补齐）已足够覆盖本调用方的错误文案回放。

**本次排除的调用方**

- `Features/Download/ModpackDownloader.swift`（`downloadLatest`）与
  `Features/Download/ModpackInstaller.swift`（`downloadMod`）经确认**均不调用 `NetManager`**：
  二者走 `URLSession.download`（`AppContext.shared.apiSession`），属第二节 #13 已登记的绕过路径。
  按「只切换确实直接调用 `NetManager` 的调用方」的约束，本轮不切换——改走 `DownloadEngine` 会由
  直连 URLSession 变为多源分片引擎，覆盖策略、错误文案与「校验失败删除已落盘文件」三点都无法保持等价。
- 同文件内的批量依赖下载（第二节 #8，原 `ForgeInstaller.swift` 的 `MultiFileDownloader`）仍走旧链路，不在「单文件」范围内。

**改动要点**

1. 对外接口零变化：`install(minecraftVersion:forgeVersion:)`、`updateProgress` 回调、
   子类 `NeoforgeInstaller`（仅覆写下载 URL 与 groupId，自动继承本改动）均无需改动，
   调用方 `LoaderInstallTask` / `ForgeInstallTask` / `InstallTask` 全部零改动。
2. 新增私有方法 `downloadSingleFile(from:to:replaceMethod:progress:)`：
   `DownloadRequest(url:destinationURL:)` → `engine.submit(_:replaceMethod:)` → `for await` 消费
   `observe(taskID:)`，`.downloading` → 进度回调、`.completed` → 回调 `1.0`、`.failed` / `.cancelled` → 抛错。
3. 两个单文件调用点逐点替换：
   - `patchMojangMappingsDownloadTask`（原 `ForgeInstaller.swift`，mappings）：`.replace`，无进度回调；
   - `downloadInstaller`（原 `ForgeInstaller.swift`，installer）：`.skip`（沿用旧调用未显式传 `replaceMethod` 的缺省值）。
4. 引擎实例为方法内局部变量，其 `run` 仍调用 `NetManager.shared.download`，全局分片额度与调度状态不变。

**行为一致性：已确认等价**

- **×0.2 折算已保住**：`downloadInstaller` 的闭包体逐字保留
  `Task { @MainActor in self.setProgress(progress * 0.2) }`，仅把上游进度源由 `SingleFileDownloader` 的
  `((Double) -> Void)` 换成 `DownloadProgress.fraction`。两者同为 0…1 比例（无 `expectedSize` 时适配器以
  `syntheticTotalBytes = 1000` 承载比例），因此 `progress * 0.2` 在每个采样点上的取值均不变，下载仍占整体进度的 20%；
  其后的固定 `await setProgress(0.2)` 亦未改动。
- **进度终值**：旧链路在成功路径末尾固定回调 `progress(1.0)`；新链路在 `.completed` 分支显式回调 `1.0`，
  折算后同为 `setProgress(0.2)`，且「已存在且校验通过而跳过」同样产生 `.completed`，与旧链路一致。
- **覆盖策略**：两处分别为 `.replace` / `.skip`，与旧调用逐点对应。`installer` 目标位于每次安装新建的
  `TemperatureDirectory`，`.skip` 正常不触发跳过分支；一旦文件已存在，旧链路 `checker == nil` 走「存在即跳过」，
  新链路 `DefaultDownloadVerifier.checker(for:)` 返回 `FileChecker(actualSize: -1, hash: nil)`，
  `canUseExistsFile == true` 且 `check` 返回 `nil`，同样跳过并回调 `1.0`。
- **候选源——本次唯一显式指定项**：旧调用 `SingleFileDownloader.download(url:)` 只传一个 URL，
  `SLNetFile.urls` 恒为单元素。新链路显式注入 `SequentialDownloadSourceResolver()`（备用源为空），
  候选列表同样恒为 `[request.url]`。若沿用引擎缺省的 `DefaultDownloadSourceResolver`，mappings 的 URL
  一旦落在 `launcher.mojang.com` 等官方域名族，就会在 `fileDownloadSource == .both` 时追加 BMCLAPI 备用源，
  构成旧链路不存在的兜底路径，故不采用。`installer` 的 URL 为 `bmclapi2.bangbang93.com`，不在官方域名族内，
  两种解析器结果相同。
- **错误语义**：旧调用失败时向上抛 `NetDownloadError.fileFailed(reason)`，其 `localizedDescription` 为
  「下载失败：\(reason)」。新链路 `.failed` 分支抛 `MyLocalizedError(reason:)`，reason 取
  `engine.legacyFailureReason(taskID:)`（按第 1 步的实现，即同一原始描述，逐字一致），
  `error.localizedDescription` 结果不变。唯一消费者 `LoaderInstallTask.install`（`InstallTask.swift`）
  只读取 `error.localizedDescription` 用于弹窗与日志，不做错误类型匹配，故更换错误类型无行为差异。

**行为一致性：无法完全确认**

- 进度回调的到达时机多一次调度跳步：旧链路由 `NetManager` 直接派发到 `@MainActor`（调用方闭包再跳一次），
  新链路多经一次 `AsyncStream` 转发（无界缓冲、FIFO，不丢事件、不乱序），采样点与顺序不变，
  但未做运行时逐点比对。
- 取消路径不可达：`ForgeInstaller.install` 由 `LoaderInstallTask.install` 直接 `await`，全链路无取消入口
  （`InstallTask.swift` 的 `cancel()` 作用于 Combine `cancellables`，与 Task 取消无关），
  故 `.cancelled` → `CancellationError` 分支仅为兜底，缺少旧链路对照。

**验证**

- `xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps $(find qwq -name "*.swift")`
  → `exit=0`，`grep -c "error:"` = 0（改造前基线同为 0）；警告数 16 → 16，未新增。
- `git diff --stat` 仅 `ForgeInstaller.swift`（+45/-2）与本记录文档，未改动 `NetDownloader.swift`、
  `ModpackDownloader.swift`、`ModpackInstaller.swift` 或其它调用方。

**下一个建议切换目标**

- 第 3 步仍按第三节顺序：`FabricInstaller`（#9）与本次形态完全一致（单文件 + `.replace` + 单一 URL），
  可直接复用 `downloadSingleFile` 的写法，建议与 `MinecraftInstaller` 的三个前置小文件（#2/#3/#4）合并为一批；
  后者带 `sha1`，需连同 `stage` 的 `beginParallelStage` / `finishParallelStage` 配对一起验证。
- `ForgeInstaller` 的批量依赖（#8，现 `ForgeInstaller.swift`）顺延至第一条批量路径（第 4 步）一并处理。
- 整合包两处 `URLSession` 直连（#13）仍是独立一步，需先补齐 `expectedSize` / `sha1` 与
  「校验失败删除已落盘文件」的语义才能保证等价。

### 2026-09-20 · 第 3 步：`FabricInstaller`、`MinecraftInstaller` 前置单文件、`CustomFileDownloadTask`、`downloadAuthlibInjector`

**改动文件**（4 个调用方，共 +180/-7；适配器与 `NetDownloader.swift` 均未改动）

- `qwq/SLCore/Minecraft/Mod/Loader/Fabric/FabricInstaller.swift`（#9）
- `qwq/SLCore/Minecraft/Download/MinecraftInstaller.swift`（#2 客户端清单 / #3 客户端 jar / #4 资源索引）
- `qwq/SLCore/Minecraft/Download/InstallTask.swift`（#11 `CustomFileDownloadTask.start()`）
- `qwq/SLCore/Minecraft/Launch/MinecraftLauncher.swift`（#10 `downloadAuthlibInjector`）

第 1 步补齐的 `legacyFailureReason(taskID:)` 已足以覆盖本批全部调用方的错误文案回放，适配器无需再补能力。

**本次排除的调用方**

- **批量路径（#5 / #6 / #8）**：`MinecraftInstaller.swift` 的散列资源 / 依赖库 / natives、
  `LaunchFix.swift`、`ForgeInstaller.swift` 的批量依赖。全部经 `MultiFileDownloader` →
  `NetManager.downloadAll`。切换需要把批次拆成「每文件一次 `submit`」并自行复刻 `downloadAll` 的两项语义：
  (a) 批进度由 `overallProgressValue(for:)` 以 200ms 采样聚合，已是全批 0…1；
  (b) `onFileCompleted` 在 `precheck` 跳过分支也会被调用一次，用于 `completeOneFile()` 计数。
  这两点在「每文件一条独立状态流」下必须自建聚合器才能逐点对齐；另 `LaunchFix` 的
  `concurrentLimit: 32` 在旧链路只是构造参数，真实并发由 `NetManager` 全局 16 分片池兜底，
  新链路需先确认调度等价。按第三节计划它们属第 4–6 步，应单独成批处理，本轮不切换。
- **#12 `DownloadSourceManager.testSpeed`**：保持旧链路。resolver 委托 `DownloadSourceManager`，
  改走引擎会形成「测速 → 下载 → 解析源 → 测速」递归。
- **绕过引擎的 `URLSession` 直连（#13 及同类）**：`ModpackDownloader.swift`、
  `ModpackInstaller.swift`、`ModBrowser/ModDownloader.swift`、`JavaDownloader.swift`。
  这些调用点**不在 `NetManager` 调用图上**（不直接调用 `download` / `downloadAll`，也不经两个薄封装），
  按「只切换确实直接调用 `NetManager` 的调用方」的约束不切换：改走 `DownloadEngine` 会由直连 URLSession
  变为多源分片引擎，覆盖策略、错误文案与「校验失败删除已落盘文件」三点都无法保持等价。
  其中 `ModDownloader.downloadMod` 还需注意其校验走 `FileChecker(hash: sha1)`（算法按长度自动判定）。

**改动要点**

1. 4 个文件对外接口零变化：`FabricInstaller.installFabric`、`MinecraftInstaller` 的六个
   `downloadXxx`（`createTask` / `createCompleteTask` 的编排不变）、`CustomFileDownloadTask.start()`、
   `MinecraftLauncher.downloadAuthlibInjector` 的签名与调用方均无需改动。
2. 内部统一为 `DownloadRequest` → `engine.submit(_:replaceMethod:)` → `for await` 消费
   `engine.observe(taskID:)` → 按状态映射进度与终态；引擎实例为方法内局部变量，
   其 `run` 仍调用 `NetManager.shared.download`，全局分片额度等调度状态不变。
3. `MinecraftInstaller` 新增私有 `downloadSingleFile(task:urls:destination:replaceMethod:expectedSHA1:stage:progress:)`，
   三个前置下载点逐点替换；`FabricInstaller` / `MinecraftLauncher` 各新增一个私有包装方法。

**行为一致性：已确认等价**

- **候选源——本批唯一需要逐点指定的地方**。两类场景必须分开处理：
  - 单 URL 调用（#9 / #10 / #11）：注入 `SequentialDownloadSourceResolver()`（备用源为空），
    候选列表恒为 `[request.url]`。若用缺省 `DefaultDownloadSourceResolver`，
    `FabricInstaller` 的 URL 一旦落在官方域名族就会在 `.both` 下追加镜像源，构成旧链路不存在的兜底路径；
    `#9`（`meta.fabricmc.net`）与 `#10`（`bmclapi2.bangbang93.com`）实际都不在 `officialHosts` 内，
    但显式注入可让候选源与用户设置项彻底解耦，故一律采用。
  - 多 URL 调用（#2 / #3 / #4）：调用方已用 `DownloadSourceManager.downloadURLs` 解析出
    「主源 + 互补源」有序数组，helper 以 `SequentialDownloadSourceResolver(fallbacks: urls.dropFirst())`
    逐字保留列表内容与顺序。**尤其不能用缺省解析器**：当主源是镜像时 `officialHosts` 不匹配，
    缺省解析器会丢掉官方备用源（把 2 个候选降为 1 个），而旧链路 `SLNetFile.urls` 是完整的 2 个。
- **覆盖策略**与旧调用点逐一对应：#2 `.replace`；#3 / #4 旧调用未显式传 `replaceMethod`（缺省 `.skip`）,
  现显式写出 `.skip`；#9 `.replace`；#10 / #11 `.skip`。
- **校验参数**：`expectedSHA1` → `DownloadRequest.sha1`；`DefaultDownloadVerifier.checker(for:)`
  在只有 `sha1` 时产出 `FileChecker(actualSize: -1, hash: sha1)`，与旧 `FileChecker(hash: expectedSHA1)`
  的参数逐项相同（旧链路哈希算法按长度自动判定，SHA1 为 40 位，走 SHA1 分支）。#2 / #9 / #10 / #11 无校验要求：
  旧链路 `checker == nil`，新链路为空期望 `FileChecker`；在 `.skip` 下两者对已存在文件都返回「跳过」，
  在 `.replace` 下 `precheck` 恒为 `.download`，合并后的 `check` 均无期望值，均不产生跳过、删除或校验失败分支。
- **进度口径**：本批全部未设置 `expectedSize`，适配器以 `syntheticTotalBytes = 1000` 承载比例，
  `DownloadProgress.fraction` 与旧回调的 0…1 比例逐点相等。
- **进度终值**：`#3` / `#4` 旧链路在成功路径末尾固定回调 `progress(1.0)`（`updateParallelStage(stage, 1.0)`），
  `#11` 回调 `progress(1.0)` 写入 `currentStagePercentage`；新链路均在 `.completed` 分支显式写终值，
  且「已存在且校验通过而跳过」同样产生 `.completed`，与旧链路一致。
- **进度路由**：`#3` / `#4` 沿用旧 `SingleFileDownloader` 的分支语义——传了 `stage` 就写
  `updateParallelStage(stage, progress:)`，否则写 `currentStagePercentage`。旧链路的 `task?.` 可为 nil
  （`CustomFileDownloadTask` 即如此），新链路同样以可选 `task` 承接。
- **文件计数**：旧 `SingleFileDownloader` 在下载返回后固定调用一次 `task?.completeOneFile()`（跳过分支同样计数），
  新链路的 `downloadSingleFile` 在 `.completed` 分支调用一次，位置与次数一致。
  `CustomFileDownloadTask` 旧链路 `task` 为 nil（该调用是 no-op），且其 `getProgress()` 被覆写为读
  `currentStagePercentage`、不依赖 `totalFiles` / `remainingFiles`，故新链路不承载文件计数不产生差异。
- **失败文案**：旧实现取 `error.localizedDescription`。新链路抛 `MyLocalizedError(reason:)`，
  reason 取 `engine.legacyFailureReason(taskID:)`（第 1 步实现，即 `NetManager` 抛出错误的原始描述，
  逐字一致），结构化错误仅在原始描述缺失时兜底。各调用方消费者：
  `FabricInstallTask.install` 与 `MinecraftInstallTask.start()` 用于弹窗与 `failureReason`
  （仅读 `localizedDescription`，不做错误类型匹配）；`createCompleteTask` 只写日志；
  `CustomFileDownloadTask` 额外做 `replacingOccurrences(of: "\n", with: "")`，该处理原样保留；
  `downloadAuthlibInjector` 的唯一调用方 `MinecraftInstance.swift` 以 `try?` 吞掉错误。
- **`#10` 不把 sha256 塞进请求**：旧链路是「先下载、再在调用方用 `FileChecker(hash: sha256)` 校验、
  失败则删除文件并抛 `authlib-injector 哈希校验失败：…`」。若把 sha256 交给引擎，
  校验会提前到引擎内部、删除与文案归属改变（变成 `NetDownloadError.fileFailed("文件哈希校验失败：…")`），
  故请求不带校验参数，调用方的下载后校验段保持原样。
- **`#11` 的调用顺序**：`hint(...)` 与 `complete()` 原本就在非 MainActor 上下文执行（`SingleFileDownloader`
  返回后继续），新实现保持同一位置与顺序；仅进度写入改为 `await MainActor.run`。

**行为一致性：无法完全确认**

- 进度回调到达时机多一次调度跳步：旧链路由 `NetManager` 直接派发到 `@MainActor`，
  新链路多经一次 `AsyncStream` 转发（无界缓冲、FIFO，不丢事件、不乱序）。`#3` / `#4` 的
  `updateParallelStage` / `finishParallelStage` 与进度写入的相对先后未做运行时逐点比对。
- `observe` 与 `submit` 之间存在并发窗口（下载可能在 `observe` 调用前已终结）。适配器以终态回放缓存
  （上限 256）覆盖该窗口，理论上不会漏终态；本批未做运行时压测。
- `.cancelled` 分支在本批全部调用方均**不可达**（无对外取消入口）：`MinecraftInstallTask.start()` 创建
  `Task {}` 后不持有句柄、`InstallTask.cancel` 类接口作用域为 Combine `cancellables`；
  `downloadAuthlibInjector` 的调用方用 `try?` 亦无取消。该分支仅为兜底（抛 `CancellationError`）。
- 引擎以 `Task.detached(priority: .utility)` 承载下载，不再继承调用方 Task 的优先级与取消；
  旧链路是直接在调用方 Task 上 `await NetManager.download`。本批无取消入口，优先级差异无用户可见影响。

**验证**

- 逐步验证：每个文件改完立即执行
  `xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps $(find qwq -name "*.swift")`，
  四次均为 `exit=0`、`grep -c "error:"` = 0、警告数 16（改造前基线同为 16，未新增）。
  无中途回退（4 个文件均一次通过，`/tmp/dlbackup/` 下的改前副本未启用）。
- `git diff --stat` 仅上述 4 个 Swift 文件；`git status` 除本次改动外仅有既有的未跟踪 `REFACTOR_PLAN.md`。
  未改动 `NetDownloader.swift`，未触碰已切换的 `ModFileDownloadTask.swift` 与 `ForgeInstaller.swift`。

**下一个建议切换目标**

- **批量路径的第一条**：#8 `ForgeInstaller` 的批量依赖（现 `ForgeInstaller.swift`）。它是单 URL 组、批内文件数不大、
  且 `replaceMethod: .skip` 为缺省值，最适合用来验证「多点提交 + 全局并发 + 批进度聚合 +
  跳过分支完成计数」这四件事在新链路上是否与 `downloadAll` 等价。
- 其后按第三节顺序：#6 `LaunchFix`（批量 32 并发 + `FileChecker` 预检，数据量大，用来压测吞吐不回退），
  最后是 #5 `MinecraftInstaller` 的三组批量（与并行阶段计数耦合最深）。
- #12 测速自用与 #13 两处 `URLSession` 直连保持不迁移。

### 2026-09-20 · 批量路径（#5 / #6 / #8）评估：**本轮不切换**

**结论**

三处批量调用点（`MinecraftInstaller.swift`、`LaunchFix.swift`、
`ForgeInstaller.swift`）**全部保持旧链路**。本目录未新增 `BatchDownloadEngine.swift`，
也未在 `MultiFileDownloader.swift` 上加薄封装层——在没有等价聚合器的前提下加一层包装只会制造
「批量路径已就绪」的假象，后续接手者会把「已实现」误读为「已验证」。

**改动文件**：仅本记录文档。`git diff --stat` 无 Swift 改动；未触碰 `NetDownloader.swift`、
`DownloadEngine.swift` 与三处调用方。

**卡点：批进度聚合的分子/分母定义在引擎内部状态上，`DownloadEngine` 边界不可观察**

旧批进度是 `NetManager.downloadAll` 的**内部服务**，不是可被上层重算的量：

1. **分母的值与集合都由引擎内部事件决定。** `overallProgressValue(for:)`
   （`NetDownloader.swift`）的分母是 `Σ r.fileSize`，`r.fileSize` 来自**首片响应头**的
   `expectedContentLength`（`NetDownloader.swift`），且只对
   `state != .done && fileSize > 0` 的记录求和；分子是同集合上的 `Σ slice.done`（采样瞬时值）。
   于是分母的集合是「首片响应头已到达、且尚未 `.done`」——一个纯引擎内部事件集。
2. **适配器对外只有一条被节流、且信息有损的状态流。** `DownloadProgress` 在调用方未提供
   `expectedSize` 时以 `syntheticTotalBytes = 1000` 合成（`NetDownloaderDownloadEngine.swift`），
   拿不到每文件真实字节数；批量调用点的 `DownloadItem`（`MultiFileDownloader.swift`）
   只有 `url / destination / sha1`，同样不携带 size。
3. **用 `expectedSize` 运输权重会改变校验语义。** `expectedSize` 经
   `DefaultDownloadVerifier.checker(for:)` 变成 `FileChecker.actualSize`
   （`DefaultDownloadVerifier.swift`），由此多出两处旧链路不存在的判定：
   `establishFileSize` 的「文件大小不一致 → 直接失败」（`NetDownloader.swift`），
   以及 `.skip` 预检由「仅哈希」变为「大小 + 哈希」（`NetDownloader.swift`）。
4. **不运输权重则口径直接退化。** 只能退回固定分母的**等权口径**（Σ 各文件 fraction ÷ 文件数），
   把旧的**字节加权**换成按文件平均；一个 50MB 的 jar 与一个 20KB 的 asset 权重相同，
   数值序列与旧实现完全不同。这是 `MultiFileDownloader.swift` 注释与第四节第 11 条要防的反面。
5. **即使权重由调用方另行提供（清单侧确有 size：`AssetIndex.Object.size`、
   `ClientManifest.DownloadInfo.size?`），分母集合仍无法对齐**：
   - 旧集合的纳入判据是「首片响应头到达」；新链路最近似的可观测量是「收到该文件的第一次
     200ms 节流上报」。`reportProgress` 每 5 个 tick 触发一次、间隔 40ms，即 200ms 一次，
     且 `record.isTerminal` 后不再上报（`NetDownloader.swift`）。
     对每个文件存在最多一个节拍的不一致窗口；窗口内新链路的分子与分母**同时**都不含该文件，
     因此中间百分比序列既不相等、也不构成单调变换（方向不固定），无法逐点对齐。
   - `fileSize == -1`（服务端未给 Content-Length，例如分块响应）的文件旧链路**永久不计入分母**，
     但仍计入 `doneCount`（`NetDownloader.swift`）；新链路无从区分该分支。
6. **跳过分支在边界上不可分辨，完成计数的「集合」无法对齐。** 旧 `downloadAll` 在**开始任何下载前**
   对整批做一次 `precheck`：跳过项立即调用 `onFileCompleted` 且**不进入 pending**
   （`NetDownloader.swift`），因此既不进分母、也不进返回的 `count`（`count` 只统计
   pending 中到达 `.done` 的文件）。新链路里「已存在且校验通过」与「实际下载完成」都只产生
   `.completed`（`NetDownloaderDownloadEngine.swift` 已注明该不可分辨性）。
   要在调用方复刻 `precheck` 才能分离两者，但旧 `precheck` 是 actor 内的原子步骤、并且会在
   「存在但校验不过」时**删除目标文件**（`NetDownloader.swift`），搬到调用方会改变
   它与并发下载的交错顺序，边界上仍不逐点一致。
7. **进度非单调，复刻时不能"顺手修正"。** `MultiFileDownloader` 在 `downloadAll` 返回后会再回放一次
   最后采样值（`MultiFileDownloader.swift`），该值可能因采样窗口而陈旧；且全部文件 `.done`
   时 `totalSize == 0`，聚合式直接返回 `0`（`NetDownloader.swift`），末次上报可能为 0。
   这类"跳动"属于既有表现，任何自建聚合器都必须原样复现，而它恰恰依赖第 5 条的集合语义。

**为什么必须按逐字一致的门槛判定：批进度在三处调用点都是用户可见量**

- `MinecraftInstaller` 的三组经 `updateParallelStage` 写入 `parallelStageProgress`，
  由 `DownloadDetailView.swift` 以 `progressForStage(stage) * 100` 渲染成百分比；
  `stage == nil`（`createCompleteTask` 路径）时写 `currentStagePercentage`。
- `LaunchFix.swift` 直接把批进度交给 `onProgress(progress)`（与前面按文件数算出的
  0…0.5 预扫描进度混用同一回调）。
- `ForgeInstaller.swift` 映射为 `setProgress(0.3 + progress * 0.3)`。

即三处都会把批进度的**数值序列**直接呈现在界面上，属于「不要改变安装进度表现」的保护范围。
按本轮约定（宁可少切也不要改变进度表现），不切换。

**已核实、可保留的结论（供后续实现直接复用）**

- `MultiFileDownloader.concurrentLimit` 是**死参数**：仅赋值、无任何读取
  （`MultiFileDownloader.swift`）。旧链路真实并发由 `NetManager.config.maxSlices = 16`
  的全局分片池兜底（`NetDownloader.swift`，且按 tick 逐文件开首片，
  两次开片之间 `sleep 40ms`）。故 `LaunchFix` 的 `concurrentLimit: 32` **不是**需要复刻的语义；
  「每文件一次 `submit`」仍然共用同一 `NetManager` 全局分片池，并发上限本身会自动保持一致。
- `count`（`overallProgress` 的第二个参数）在三处调用点均被丢弃
  （`LaunchFix` / `ForgeInstaller` 写 `{ progress, _ in }`；`MinecraftInstaller` 走
  `MultiFileDownloader` 的 `onFileCompleted` 而非 `count`）。用户可见的文件计数来自
  `onFileCompleted → completeOneFile()`（`InstallTask.swift`）与
  `getProgress()` 读 `remainingFiles / totalFiles`（`InstallTask.swift`），
  与批进度 `p` 是两条独立通道，**切换批进度不影响总进度条**——只影响阶段内百分比。
  这一条缩小了后续切换的风险面，但不能消解上面的卡点。
- 三处调用点均**无对外取消入口**：`MinecraftInstallTask.start()` 创建 `Task {}` 后不持有句柄
  （`InstallTask.swift`）、`LaunchFix.perform` 由启动链直接 `await`、
  `ForgeInstaller.downloadDependencies` 由 `LoaderInstallTask.install` 直接 `await`
  （`InstallTask.swift`）。故「取消穿透」在本轮**无触发路径可供验证**，
  即使实现也必须以静态路径推断为准，不能声称已运行时验证。
- 旧链路另有两处仅因调用方未触发而不可达的边界，实现时需对齐：`.throw` 覆盖策略
  （`NetDownloader.swift`，三处调用点均未使用，实际为 `.skip`），以及
  `precheck` 抛错路径不回滚已 append 的 `records`（`NetDownloader.swift` 的 `defer`
  注册在循环之后）。

**解除卡点的前置条件（建议下一步先做，再回来切批量）**

1. **把批聚合下沉到引擎侧**：给 `DownloadEngine`（`Core/Download/DownloadEngine.swift`）补一个
   批量入口，或让 `DownloadProgress` 直接携带引擎侧的真实字节数（由 `NetManager` 的
   `fileSize` / `slices.done` 直出），使「分母集合 = 引擎内部判定」可被逐字复刻。
   该改动落在 `Adapters/**` 之外，超出本轮允许的改动面。
2. **让状态机区分「跳过」与「下载完成」**（新增 `.skipped` 或等价的附加标记），
   使 `count` 与 `onFileCompleted` 的计入集合可与旧的 pending/precheck 语义对齐。
3. 上述两项落地后，再按 #8（单 URL 组）→ #6 → #5 的顺序切换，并在切换时逐点比对
   `progressForStage` 的输出序列。

**验证**

- `xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps $(find qwq -name "*.swift")`
  → `exit=0`，`grep -c "error:"` = 0。警告数 **20**（上一节记录的 16 为改前基线；本次未改 Swift 代码，
  差异来自并行进行的 `ContentView.swift` / `qwq/UI/Shell/` 改动，非本次引入）。
  因本轮无代码改动，未执行任何回退操作。
- `git diff --stat`：仅 `qwq/Core/Download/Adapters/MIGRATION.md`。

**下一个建议切换目标**

- 先完成本节「解除卡点的前置条件」第 1、2 项（引擎侧批进度与跳过标记），再切批量。
- 若必须在本轮继续推进下载模块，可切换的对象只剩 #13 两处 `URLSession` 直连
  （`ModpackDownloader.swift`、`ModpackInstaller.swift`、`ModBrowser/ModDownloader.swift`、
  `JavaDownloader.swift`），但同样需要先补齐 `expectedSize` / `sha1` 与
  「校验失败删除已落盘文件」的语义。
- #12 `DownloadSourceManager.testSpeed` 保持不迁移。

