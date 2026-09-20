# Adapters 迁移说明

本目录只放**适配器**：把 `qwq/Core/Download/` 的协议接到现有实现上，不改变任何下载行为，也不切换调用方。
当前状态：`NetDownloader.swift`（`NetManager`）仍是唯一实际生效的下载路径；`DownloadEngine` 已由
`Features/Download/ModFileDownloadTask.swift` 首个接入（见「六、切换记录」），其余调用方仍走旧链路。

## 一、新增文件与职责

| 文件 | 职责 |
| --- | --- |
| `DefaultDownloadSourceResolver.swift` | 实现 `DownloadSourceResolver`，委托 `DownloadSourceManager` 判定主源/互补源与 `.both` 模式 |
| `DefaultDownloadVerifier.swift` | `DownloadVerifier` 的 CryptoKit 实现复用 + 与旧 `FileChecker.check` 逐字等价的重载入口 |
| `NetDownloaderDownloadEngine.swift` | 实现 `DownloadEngine`，后端为 `NetManager`，把回调式进度转换成 `AsyncStream<DownloadState>` |

### 旧引擎的真实对外入口

```swift
// NetDownloader.swift:253
NetManager.shared.download(_ file: PCLNetFile, progress: ((Double) -> Void)? = nil) async throws
// NetDownloader.swift:286
NetManager.shared.downloadAll(_ files: [PCLNetFile], overallProgress: ((Double, Int) -> Void)?, onFileCompleted: (() -> Void)?) async throws
```

关键事实：

- 进度是 **0…1 的比例**（不是字节），且在「已存在且校验通过 → 跳过」分支同样回调 `1.0`；
- 进度回调由 `NetManager` 自行切到 `@MainActor`（`NetDownloader.swift:256`、`439`）；
- **取消以 Swift Task 取消表达**：`waitForCompletion` 内 `Task.checkCancellation()`（`NetDownloader.swift:831`）
  会在取消时抛出，`download` 的 `catch` 随即取消全部分片任务并清理临时文件（`NetDownloader.swift:274`）；
- 输入类型 `PCLNetFile(urls:destination:checker:replaceMethod:)`，覆盖率策略（`.skip` / `.replace` / `.throw`）与
  校验参数（`FileChecker`），`DownloadRequest` 中都没有对应字段。

### 适配器的对接方式

1. `DownloadRequest` → `PCLNetFile`
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

- `qwq/PCLCore/Download/SingleFileDownloader.swift:45` → `NetManager.shared.download(file) { p in ... }`
- `qwq/PCLCore/Download/MultiFileDownloader.swift:106` → `NetManager.shared.downloadAll(...)`

上层调用方（行号为实际调用点）：

| # | 调用方 | 形态 | 切换需要改什么 |
| --- | --- | --- | --- |
| 1 | `Features/Download/ModFileDownloadTask.swift:43` | 单文件 `SingleFileDownloader.download(task:url:destination:replaceMethod:.replace)` | 只换提交方式；进度写入 `currentStagePercentage`、成功 `completeOneFile()/complete()`、失败 `failureReason` 需分别由 `observe` 流与 `DownloadHandle` 承担 |
| 2 | `PCLCore/Minecraft/Download/MinecraftInstaller.swift:46` | 单文件（客户端清单），`.replace` | 同上；`.replace` 必须显式传 `replaceMethod:` |
| 3 | `MinecraftInstaller.swift:73` | 单文件（客户端 jar），`expectedSHA1` + `stage: .clientJar` | `expectedSHA1` → `request.sha1`；`stage` 的 `beginParallelStage/finishParallelStage` 需在流的终态处配对，否则并行阶段计数不归零 |
| 4 | `MinecraftInstaller.swift:108` | 单文件（资源索引），`expectedSHA1` | 同上 |
| 5 | `MinecraftInstaller.swift:145 / 177 / 214` | 批量 `MultiFileDownloader(task:items:stage:)`（散列资源 / 依赖库 / natives） | 需把批次拆成每文件一个 `submit`，批进度与 `onFileCompleted` 由各任务状态聚合；这一组与 `InstallTask` 的总文件数/剩余文件数耦合最深 |
| 6 | `PCLCore/Minecraft/Launch/LaunchFix.swift:79 / 100` | 批量 `MultiFileDownloader(items:concurrentLimit:32)` | 同 5，且并发上限 32 在旧链路由 `NetManager.config.maxSlices` 统一兜底，新链路需确认调度器等价 |
| 7 | `PCLCore/Minecraft/Mod/Loader/Forge/ForgeInstaller.swift:134 / 172` | 单文件（mappings / installer） | 同 2、3；`:172` 的进度回调按 `progress * 0.2` 折算，需在状态流上做同样折算 |
| 8 | `ForgeInstaller.swift:236` | 批量 `MultiFileDownloader(urls:destinations:replaceMethod:.skip)` | 同 5；`.skip` 为缺省值，可不传 |
| 9 | `PCLCore/Minecraft/Mod/Loader/Fabric/FabricInstaller.swift:28` | 单文件，`.replace` | 同 2 |
| 10 | `PCLCore/Minecraft/Launch/MinecraftLauncher.swift:327` | 单文件（authlib-injector） | 同 2；`:332` 的 `FileChecker(sha256).check` 预检改用 `verifier.verify(fileAt:checker:)` |
| 11 | `PCLCore/Minecraft/Download/InstallTask.swift:412` | 单文件 + 进度 | 同 1 |
| 12 | `PCLCore/Download/DownloadSourceManager.swift:108` | 测速自用（内部 `SingleFileDownloader`） | **保持旧链路**。若改为 `DownloadEngine`，resolver 委托 `DownloadSourceManager` 会形成「测速 → 下载 → 解析源 → 测速」递归 |
| 13 | `Features/Download/ModpackDownloader.swift:106`、`Features/ModBrowser/ModDownloader.swift:159` | 绕过引擎直接用 `URLSession.download` + `FileChecker` 校验 | 未纳入本轮适配面；若统一，需补 `expectedSize` + `sha1` 请求，并保留「校验失败删除已落盘文件」的行为 |

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

1. **校验失败必须删除目标文件再抛错**。旧 `merge` 在校验不过时先 `removeItem` 再抛（`NetDownloader.swift:795`）。
   若只抛不删，文件残留后下次 `.skip` 预检会命中并跳过（无 checker 时永远跳过），坏文件被永久固化。
2. **哈希算法按长度自动判定且大小写不敏感**：`<35` 用 MD5、`==64` 用 SHA256、其余用 SHA1，比较前统一小写
   （`NetDownloader.swift:45-57`）。`CryptoKitDownloadVerifier` 只支持 SHA1/SHA256，32 位 MD5 场景若走协议方法
   （`sha1`/`sha256` 都传 nil）会**静默不做校验**。迁移阶段必须走 `DefaultDownloadVerifier.verify(fileAt:checker:)`，
   或先补 MD5 支持。
3. **预检语义**：`.skip` + 文件存在 + 校验通过 → 跳过且不重下；存在但校验不过 → 删除重下；
   完全没有校验要求 → 存在即跳过。若新链路默认变成「总是重下」或「存在即不校验」，离线/断网场景会从成功变失败。
4. **`expectedSize` 是「必须相等」，`minSize` 是「至少」**，两者语义不同不可互相取代。`DownloadRequest` 只有前者，
   旧链路带 `minSize` 的调用方在迁移前需先确认是否仍有此约束。
5. **服务端忽略 Range 的降级路径必须保留**：分片请求返回 200 时判定该源不支持断点续传并拉黑（只准单线程）
   （`NetDownloader.swift:587-591`）。丢失该判定会继续按 Range 语义拼接 200 的全量响应，文件长度错乱。
6. **分片合并只拼「有数据」的分片且必须按 offset 升序**（`NetDownloader.swift:757-787`）；
   传输提前断流仍有剩余时必须判失败走断点续传，不能当作完成（`NetDownloader.swift:692`）。
7. **资源保护参数**：全局分片上限 16、单文件 >4MB 才分片、>50MB 时做磁盘空间预检、
   慢速检测（间隔 >1s 且 <1KB/s）与分片 5 分钟总超时、单源失败 3 次阈值、连接层错误直接淘汰该源
   （`NetDownloader.swift:139-148`、`633-640`、`707-736`）。这些决定「不会把磁盘写满 / 不会无限重试」。
8. **取消与失败必须清理临时分片**（`SharedConstants.temperatureURL` 下的 `.tmp`，`NetDownloader.swift:807-813`），
   否则缓存目录持续膨胀。
9. **进度口径是 0…1 比例而非字节**，且跳过分支回调 `1.0`；调用方依赖该回调完成计数（旧 `progress(1.0)` 在
   `NetDownloader.swift:262`、`282`）。
10. **`.both` 模式才追加互补源**，用户手动限定「仅官方 / 仅镜像」时不得跨源兜底（`DownloadSourceManager.swift:65-74`）；
    候选列表顺序以请求主源为第一位。
11. **`MultiFileDownloader` 的批进度 `(Double, Int)` 已是全批 0…1**（`MultiFileDownloader.swift:122` 的注释），
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
  同为「单文件 + `.replace`」形态，可直接复用本步模式，但需注意 `ForgeInstaller.swift:172`
  的进度回调按 `progress * 0.2` 折算，须在状态流上做同样折算。
- `MinecraftInstaller` 的前置小文件（#2/#3/#4）顺延其后，原因是需与 `stage` 计数配对。
