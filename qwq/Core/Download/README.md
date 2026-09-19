# Core/Download

下载领域的**目标结构**。本目录当前只定义数据与协议，不改变任何现有下载行为：
旧的 `qwq/PCLCore/Download/NetDownloader.swift` 原样保留，仍是实际生效的代码路径。

## 文件职责

| 文件 | 内容 | 说明 |
| --- | --- | --- |
| `DownloadRequest.swift` | `DownloadRequest`、`DownloadPriority` | 一次单文件下载的全部输入：url、落盘路径、期望大小、sha1/sha256、请求头、是否支持 Range、优先级。纯数据，可直接构造用于测试 |
| `DownloadProgress.swift` | `DownloadProgress` | 进度快照。`fraction` 与 `estimatedRemaining` 由 `bytesWritten`/`totalBytes`/速度派生，避免各处口径不一致 |
| `DownloadState.swift` | `DownloadState` | 状态机：idle → preparing → downloading → verifying → merging → completed，任意非终态可迁移到 cancelled / failed |
| `DownloadError.swift` | `DownloadError` | 统一错误类型，收敛旧实现里 `NetDownloadError`、`MyLocalizedError`、字符串 failReason 三种载体 |
| `DownloadTask.swift` | `DownloadTask`、`DownloadTaskStore` | 任务视图（请求 + 状态）与状态台账协议。旧实现状态藏在 `NetManager.FileRecord` 私有类里，外部无法观测 |
| `DownloadSourceResolver.swift` | `DownloadSourceResolver`、`SequentialDownloadSourceResolver` | 把「给出有序候选源列表」从调度中拆出。默认实现按候选顺序返回，测速与黑名单留给后续实现 |
| `DownloadSliceStore.swift` | `DownloadSlice`、`DownloadSliceState`、`DownloadSliceStore` | 分片是纯数据（offset/length/临时文件/状态/已写字节），台账是协议，可替换为内存实现或落盘实现 |
| `DownloadMerger.swift` | `DownloadMerger` | 只做一件事：按 offset 顺序把已完成分片拼成目标文件 |
| `DownloadVerifier.swift` | `DownloadVerifier`、`CryptoKitDownloadVerifier` | 结果校验。旧 `FileChecker.check` 靠「返回 nil」表达成功，这里改为 throws，调用方无法忽略 |
| `DownloadScheduler.swift` | `DownloadScheduler` | 并发额度、分片切分、重试、源切换、进度发布的边界定义 |
| `DownloadEngine.swift` | `DownloadEngine`、`DownloadHandle` | 对外唯一入口，UI / 安装层只依赖此文件 |

依赖关系单向：`DownloadEngine` → `DownloadScheduler` → （`DownloadSourceResolver` / `DownloadSliceStore` / `DownloadMerger` / `DownloadVerifier`）。
下层组件不知道上层存在，因此可以逐个替换并单测。

## 与旧代码的对应关系

| 旧（NetDownloader.swift） | 新 |
| --- | --- |
| `PCLNetFile` | `DownloadRequest` |
| `FileChecker.check` 返回 `String?` | `DownloadVerifier.verify` throws |
| `NetManager.Slice`（私有类） | `DownloadSlice` + `DownloadSliceStore` |
| `NetManager.pickSource` + 源黑名单 | `DownloadSourceResolver` |
| `NetManager.merge` | `DownloadMerger` |
| `NetManager.precheck` / `establishFileSize` | `DownloadState.preparing` 阶段的职责 |
| `NetDownloadError` | `DownloadError` |
| 进度闭包 + `waitForCompletion` 轮询 | `DownloadScheduler.observe` 的 `AsyncStream<DownloadState>` |

## 迁移步骤：把 NetDownloader 逐步降级为协调器

迁移按「先加后换、每步可回滚」进行，任何一步都不要求一次性重写。

**第 1 步：接入 Engine 门面（不改旧逻辑）**
新增一个 `DownloadEngine` 实现，内部直接转发到现有 `NetManager.download(_:progress:)`：
把 `DownloadRequest` 转成 `PCLNetFile`，把 `DownloadState` 用进度闭包驱动。
此时新模块只是旧引擎的适配器，行为完全不变，UI 侧可先切换观测方式。

**第 2 步：抽出校验**
新引擎不再调用 `FileChecker`，改用 `CryptoKitDownloadVerifier`。
两者语义差异（旧实现按哈希长度自动判 MD5/SHA1/SHA256）用一段显式判断兼容，
跑通旧用例集后删除 `FileChecker` 在下载路径上的调用。

**第 3 步：抽出源解析**
把 `DownloadSourceManager.downloadURLs` 产出的数组交给 `SequentialDownloadSourceResolver`，
`NetManager` 的 `pickSource` 退化为「按 Resolver 给出的顺序取下一个可用源」。
源黑名单（`sourcesOnce` / `sourceFails`）随后搬进 Resolver 实现。

**第 4 步：抽出分片台账**
`NetManager.Slice` 的读写改走 `DownloadSliceStore`。
先只做记录（状态同步写两份），确认一致后再让调度器只读台账，删除 `Slice` 私有类。

**第 5 步：抽出合并**
`NetManager.merge` 的按序拼接逻辑迁到 `DownloadMerger` 实现，
覆盖策略（`.skip`/`.replace`/`.throw`）上提到调用方，在提交请求前决定。

**第 6 步：降级 NetDownloader**
上述能力全部落地后，`NetManager` 只剩下「额度分配 + tick 循环」，
即本目录 `DownloadScheduler` 的一个实现。届时：
- 把该实现移到 `Core/Download/` 下并改名为具体调度器；
- 旧 `NetDownloader.swift` 保留一个薄转发层，或直接删除（取决于是否还有外部引用）。

**每一步的验收**
- 现有安装流程（原版 json/jar、资源索引、散列资源、依赖库、natives）全量跑通；
- 断点续传与多源切换各有一次人为中断验证；
- `DownloadSourceManager` 的官方/镜像切换行为不回退。

## 测试挂载点

本目录所有协议均可实现为内存版本，无需真实网络：

- `DownloadSourceResolver`：固定返回若干 URL，验证空数组 → `sourceUnavailable`；
- `DownloadSliceStore`：内存字典实现，验证完成分片查询与清理；
- `DownloadMerger`：写入若干临时分片后合并，比对合并结果与预期字节序列；
- `DownloadVerifier`：对已知内容的临时文件校验 sha1/sha256 与大小；
- `DownloadScheduler`：注入上述全部依赖，用单个小文件验证状态序列
  `preparing → downloading → verifying → merging → completed` 与取消后的 `cancelled`。
