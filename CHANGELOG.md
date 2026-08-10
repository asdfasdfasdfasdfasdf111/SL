# 更新日志

本文件记录 SL 启动器（qwq）的重要变更。版本格式遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- **新增下载详情页（毛玻璃风格，对标 PCL.Mac InstallingView）**：点击圆形下载按钮后不再只是视觉指示，而是进入真正的下载详情页——左侧 200pt 圆角矩形毛玻璃信息卡（总进度 / 实时下载速度 / 剩余文件，对标 PCL.Mac LeftTabView + PanelView），右侧逐任务毛玻璃卡逐阶段渲染进度（inprogress 显示实时百分比、finished 勾选、waiting 灰圈、failed 红叉，对标 StaticMyCard）。后端完整移植 PCL 的 `InstallTask` 任务模型：新增 `ModFileDownloadTask`（单文件下载任务，字节级进度写入 `currentStagePercentage`，走 `SingleFileDownloader → NetManager`，完成自动 `completeOneFile/complete`）、`DownloadDetailManager`（全局任务容器，`tasks.objectWillChange` 转发实时刷新）；`SpeedMeter` 速度数据源为 NetManager 分片下载现成上报，详情页直接读取。整合包下载完成后自动进入安装流程，普通文件下载完成后详情页自动关闭并弹「下载完成」
- **新增游戏版本一键下载安装（游戏版本页点「下载」不再报错，对标 PCL.Mac DownloadPage）**：游戏版本页（加载器选择页）点下载 = 真正下载安装所选版本——复用 PCLCore `MinecraftInstaller.createTask`（客户端清单 → 资源索引 → 本体 jar → 依赖 libraries → natives），若该版本有可用加载器（`LoaderSupportChecker` 检测结果）则追加对应的 `FabricInstallTask`/`ForgeInstallTask`/`NeoforgeInstallTask`，由 createTask 在 jar 下载完成后自动串联安装（通过 `DataManager.inprogressInstallTasks` 按 key 查找，与 PCL.Mac 行为一致）。加载器版本号由新增的 `LoaderVersionResolver` 自动取最新（Fabric 优先最新稳定版，来源对标 PCL.Mac LoaderCard：meta.fabricmc.net / bmclapi2 forge、neoforge / meta.quiltmc.org）。实例名 = 版本号（带加载器时 + "-Fabric"/"-Forge"/"-NeoForge"，与本地实例命名约定一致）。全流程进入下载详情页展示进度，完成后自动关闭并弹「下载完成」。无可用加载器的版本自动装纯原版

### 修复

- **修复下载详情页偶发崩溃 `EXC_BAD_ACCESS (code=257, address=0x26fffc2cb)`**：根因是下载任务完成回调（`onComplete`）里直接写视图的 `@State`（`self.isDownloading`）——回调可能在用户已离开页面后触发，此时视图已销毁，写已释放的 State storage 造成 UAF（对齐故障、跳进数据区）。改为：回调只操作全局单例（`DownloadDetailManager.dismiss()` / 弹窗提示），「下载中」状态由 `onChange(of: downloadDetail.isPresented)` 跟随详情页开关自动复位（视图存活时才执行，销毁则无需复位）
- **修复下载详情页交互（对标 PCL.Mac：点圆形按钮 toggle 开关，无返回键）**：此前详情页以全屏叠加层盖住整个内容区，把右下角圆形按钮也盖住了，用户无法再次点击回到原页面，只能点右上角 xmark 关闭。现改为：圆形按钮提升到详情页之上（zIndex 50 > 10）始终可见可点，点击在「显示/隐藏详情页」间切换（toggle）；移除详情页的 xmark 关闭按钮；手动关闭详情页时保留进行中的任务，再次打开恢复显示；任务清空后再打开显示「没有进行中的下载」占位，不再空白
- 修复游戏版本页加载器卡片无法取消选中：再点已选中的加载器卡片即可取消（不装加载器、下载纯原版），刷新/重新检测后保持取消状态不再被自动选回；此前点击只会切换选中，无法表达「不装加载器」。取消状态用空字符串表示，与「下载纯原版」的判定天然兼容
- 修复游戏版本页点「下载」弹「下载失败: 游戏版本页无需下载」：此前的下载链路只在 mod/shader/resourcePack/modpack 四类页面实现了下载逻辑，游戏版本页（loaderSelector）只做了占位守卫，而下载按钮又对所有页面显示，一按就撞上守卫报错。已改为真正的版本下载安装（见上方新增条目），并保留兜底文案

- 修复「下载游戏」页面所有分类显示为空：版本清单（version_manifest）拉取失败时不再缓存空结果（此前一次失败会导致 5 分钟内所有游戏版本分类全部为空），网络恢复后自动重试
- 修复模组列表实时翻译导致界面卡死：翻译结果改为独立字典异步更新，不再逐条改写列表数组触发全列表重建
- 修复实时翻译仅覆盖前 200 张卡片：本地全量目录（模组 7 万余条）中滚动到下方的卡片完全没有翻译，只有点进详情页才翻译简介。改为按需翻译——卡片进入可视区域时才发起翻译（滚动到哪翻译到哪），已翻译结果写入磁盘缓存
- 修复翻译缓存未全量应用与未回写列表：此前列表只对前 200 项批量应用磁盘缓存，其余条目即使已在详情页翻译过也不会在列表显示。现在进入页面/返回列表时全量应用磁盘翻译缓存，详情页翻译过的简介返回列表后立即回写
- 修复退出详情页后列表滚动位置回到最上方：进入详情页前记录当前浏览位置（视口顶部卡片锚点），返回列表后自动恢复原位，不再跳回顶部
- 修复游戏版本清单分类缓存逻辑，避免缓存污染导致切分类后无内容
- 修复 Forge 安装器与 GLFW 启动器使用 `/usr/bin/java` 的问题：改为优先使用用户选择的 Java，其次扫描系统最佳版本，最后才回退系统 Java
- 修复解压任意 ZIP 时的路径穿越（ZIP Slip）漏洞：拒绝绝对路径与 `..` 跳出的条目
- 修复下载进度语义：内容长度未知（-1）时不再导致进度累加为负数
- 修复下载完成后句柄与临时文件未及时清理的问题
- 修复崩溃日志清理误删共享临时目录的问题
- 修复缓存读写并发死锁（`NSLock` → `NSRecursiveLock`）
- 修复列表翻译缓存全量扫描触发海量磁盘 IO 导致的卡顿：此前进入页面/返回列表会对全部 7 万余条目录逐条执行磁盘检查，改为纯内存扫描；磁盘缓存命中的翻译由进入可视区域的卡片按需回读，滚动到哪显示到哪
- 修复实时翻译无并发上限导致的请求堆积：全局翻译并发限制为最多 24 个同时进行，滚动浏览大量卡片时不再无限制创建后台网络任务
- **修复创建世界 / 进入世界报错 `Internal Exception: io.netty.handler.codec.EncoderException: Failed to encode packet 'serverbound/minecraft:hello'`**：根因是离线用户名超过 16 字符——历史脏数据把输入框占位提示「SL启动器（最好使用英文及下划线）」存成了真实用户名（17 字符 > MC `hello` 包 `writeUtf(name,16)` 上限，编码直接抛 `String too big (was 17 characters, max 16)`）。本次完整移植 PCL2 离线登录逻辑：① 启动前 PCL2 风格校验用户名（非空 / 无英文引号 / ≤16 字符，对应 PCL2 `PageLoginLegacy.IsVaild`）；② 离线 UUID 改用 PCL2 `McLoginLegacyUuid` 算法（名字长度 + djb2-xor 哈希拼接，强制 version=3 / variant=9，替代此前「未哈希的 OfflinePlayer 原始字节」错误算法）；③ 离线 accessToken = UUID 本身（PCL2 `McLoginLegacyStart` 行为）；④ `user_type` 恢复 PCL2 行为统一传 `msa`（PCL2 issue #1221，废弃此前改传 `legacy` 的错误尝试）；⑤ 启动时自动清理已写入 UserDefaults 的占位符脏数据
- **修复游戏关闭启动器检测不到**：`MinecraftLauncher.launch` 增加 `process.terminationHandler`，进程退出时主动在主线程触发 callback；同时用 `DispatchSemaphore` 替代 `process.waitUntilExit()`——一旦 Java 进程异常（卡死/死锁/僵尸），旧实现永久阻塞、UI 永远收不到 completion；现在 terminationHandler 必然触发一次 callback。catch 路径也 signal semaphore 防止 launch() 自身永久阻塞
- 修复启动参数 `user_properties` 多转义引号的问题：此前传 `"\"{}\""` 让 Java 收到字面量 `"{}"`，改为与 PCL2 一致的 `{}`（Process.arguments 不经 shell，参数原样传递）；同时按 PCL2 行为补充 `auth_session` 启动参数（值与 accessToken 一致）
- 启动链路防御性用户名校验：`PCLLaunchBridge` 对用户名 trim 后为空自动兜底为 `Player`，非法（含英文引号 / 超 16 字符）直接失败并返回明确错误；`MinecraftInstance.launch` 前置校验，非法用户名不再拖到进服时才抛 `EncoderException`
- **修复离线自定义皮肤无效（26.2 实测）**：1.19.3+ 的默认皮肤实际加载路径为 `assets/minecraft/textures/entity/player/{slim|wide}/{9 个默认皮肤}.png`，此前向版本 JAR 顶层写入 `entity/steve.png` 等的替换方式游戏根本不读取。已按 PCL2（`ModLaunch.vb` 离线皮肤资源包逻辑）移植新方案：生成皮肤资源包 `resourcepacks/SL 皮肤.zip`（`pack.mcmeta` + wide/slim 双模型 × 9 个默认皮肤 + 旧版顶层 `entity/{steve,alex}.png`，全版本生效），并注入 `options.txt` 的 `resourcePacks`（追加 `"file/SL 皮肤.zip"`，列表末尾最高优先级）；选择皮肤时与每次启动前均幂等应用（按皮肤 SHA-1 判重，换皮肤自动重建资源包）
- 修复点击空白处 / 按钮后用户名输入框高亮边框不消失：macOS 点击非焦点区域不会自动让输入框失焦，新增背景透明点击层（点击空白即失焦），并让「选择皮肤」「启动游戏」按钮主动释放焦点
- 修复模组 / 加载器详情页每次进入都强制联网检测加载器支持导致 10+ 秒等待：加载器支持检测改为三级策略——内存缓存 → 磁盘缓存（`SL启动器/LoaderSupportCache.json`，7 天 TTL，原子写入）→ 联网检测（失败自动回退旧磁盘缓存），装过加载器后再次进入详情页秒开
- **修复手动关闭游戏进程后启动器识别不到**：`process.terminationHandler` 此前在 `run()` 之后才设置——进程启动后立刻退出（秒退 / 崩溃 / 手动关闭恰在 run 之后）时 handler 可能永不触发，`launch()` 永久阻塞、UI 永远停留在「运行中」。改为在 `run()` 之前设置 handler，并将等待改为带超时轮询兜底：检测到进程不再运行就主动回调，确保「游戏已关闭」必然被识别并复位 UI
- 修复启动按钮等待阶段无反馈：点击启动后约 1 秒（皮肤资源包应用等准备操作）按钮变灰却仍显示「启动游戏」，新增「准备中…」阶段文案，准备完成进入下载 / 启动阶段自动切换
- **修复游戏版本页（加载器选择）显示与所点版本不一致**：进入详情页时默认选中的是「当前实例版本」而非用户点击的版本——例如点击 1.7.2 打开详情页，加载器卡片却显示当前实例 26.2 的检测结果（26.2 缓存命中 Fabric/Forge/NeoForged/Quilt 四张卡片，而 1.7.2 实际仅支持 Forge）。游戏版本页现改为默认选中用户点击的版本（`item.name`），加载器检测严格按所选版本执行
- **修复加载器选择页 1.10 等版本仍显示 4 张卡片（上一修复后仍复现）**：根因是 `fetchManifestVersions` 完成回调此前**无条件**把 `selectedVersion` 覆盖为 `sortedVersions.first`，而版本列表排序会把当前实例版本（26.2）提到首位——点击 1.10 后 onAppear 按 `item.name` 设置的选择被清单拉取回调冲掉，`onChange` 再次触发 `fetchLoaderSupport("26.2")` 命中磁盘缓存（仅 26.2 有 4 加载器条目）显示四张卡。现改为回调内先保留现有选择（含用户手动选择），其次用户点击的 `item.name`，最后才回退到列表首位；`item.name` 不在本地版本列表时也不提前回退，等待清单就绪后决议
- **优化加载器支持检测的首次等待**：① 404/410 等 4xx 状态码此前被当作瞬时故障重试 3 次（Quilt 双端点 × 3 次 = 6 次白等），现改为「4xx = 明确不支持」直接出结论，仅网络错误 / 5xx 才重试——实测 1.10 首次检测由数秒降至约 1 秒（四端点并发取最慢值）；② 「0 个加载器支持的版本」此前检测结果为空时不写缓存，导致每次进详情页都重新联网白等，现空结果同样写入缓存（区分「明确不支持」与「网络失败结果未知」，后者不写缓存、回退磁盘旧缓存，避免覆盖已有记录）；③ 缓存命中的版本（如 26.2）本来就秒开、不闪 loading
- 修复下载 / 安装任务回调写 `self.isDownloading` 的 UAF 崩溃风险：回调可能晚于视图销毁，此时写 @State 会触发 `EXC_BAD_ACCESS`。改为不再在任务回调里写该状态，由 `.onChange(of: downloadDetail.isPresented)` 在详情页开关变化（dismiss / 手动关闭）时统一复位

### 新增

- 下载校验：客户端 jar、依赖库、原生库下载接入 SHA-1 校验
- 本地 Modrinth 全量目录更新至 122,477 条目（模组 71,706 / 资源包 31,918 / 光影 781 / 整合包 18,072），覆盖更完整
- JVM 启动参数动态补齐：按平台与 Java 主版本自动注入缺失参数（macOS 补 `-XstartOnFirstThread`、Java 8 及以下补 `-XX:+UseG1GC`、补 `-XX:+HeapDumpOnOutOfMemoryError` 与 `-Dfile.encoding=UTF-8`），全部先查重再追加，与版本清单自带参数不冲突
- 借鉴 GitHub 开源项目 Swift-Craft-Launcher（AGPL-3.0，仅参考思路）进一步深化 JVM 参数优化：`-Xms` 堆初始大小动态补齐（默认 maxMemory 的一半、下限 256m，消除堆扩张停顿）；Java 9+ 且未显式指定 GC 时注入 G1 停顿调优（`-XX:+ParallelRefProcEnabled` / `-XX:MaxGCPauseMillis=200`）；补 `-XX:+OmitStackTraceInFastThrow` 与 `-XX:+OptimizeStringConcat` 零风险运行时优化，全部查重后追加
- 离线用户名输入实时提示（PCL2 HintChinese 语义）：输入框下方动态显示校验提示——超过 16 字符提示「用户名不能超过 16 个字符」，包含英文数字下划线以外字符时提示 1.18+ 服务端可能拒绝；启动时对含非法字符的用户名弹窗警告「可能无法进入游戏」，支持「仍要启动」以兼容 1.18 之前的版本

### 变更

- 离线皮肤应用统一改走「皮肤资源包」方案（PCL2 移植，见修复条目）：不再修改版本 JAR——JAR 顶层贴图对 1.19.3+ 无效；资源包方案全版本生效，且不破坏 JAR 完整性
- 下载按钮点击即时提示「下载开始」（此前仅下载完成才提示「下载完成」）
- 用户名输入框横向宽度 190 → 150，更紧凑
- 用户名校验提示文字由橙色改为白色（暗色主题下更协调）
- **加载器支持检测下沉到 PCLCore 后端核心**：新增 `LoaderSupportChecker` 核心服务，UI 层（`ModDetailView`）不再直接联网 / 直接读写缓存文件，只消费结果——三级策略（内存 → 磁盘 7 天 TTL → 联网失败回退旧缓存）与并发检测、多端点重试全部在核心层实现；新增同步缓存查询接口（缓存命中时不闪烁 loading），内存警告时一并清理核心层内存缓存

- 应用图标内容整体缩小至 0.85 倍（像素尺寸不变，内容居中），视觉上更紧凑
- 空闲时静默后台：网速计速器改为惰性启动（有流量才跑，空闲 3 秒自停，不再常驻每秒唤醒）；游戏日志改为增量读取（不再全量重读文件）；窗口检测轮询由 1 秒降频至 2 秒——应用空闲时几乎不再产生 CPU 与内存占用
- 翻译结果内存上限：实时翻译字典最多保留 2000 条，超限优先裁剪非活跃条目，磁盘缓存兜底恢复，长会话内存不再无限增长
- Java 主版本探测合并为一次读取（`release` 文件解析），版本校验与参数过滤共用结果，减少重复磁盘 IO
- 代码极致模块化：`GameViews.swift` 由 2776 行拆分为 4 个职责单一文件——`GameViews.swift`（1516 行，列表与分类视图）、`ModDetailView.swift`（详情页）、`ContentCard.swift`（内容卡片）、`GameCards.swift`（依赖卡/加载器选择卡/版本卡/网格卡），可读性与可维护性大幅提升
- 修复 AppIcon 资源引用缺失导致的 32x32@2x 图标缺口
- 在线列表缓存优先：进入页面/搜索时先读磁盘缓存（离线、弱网也能秒开上次内容），无缓存才请求网络；所有分类列表拉取成功后自动持久化到磁盘缓存
- 下载详情页交互调整：移除右上角 X 关闭按钮，圆形下载按钮改为开关切换（`zIndex` 提升至详情页之上，详情页打开时按钮仍可见可点），再点一次即可回到刚才的页面，无需返回键

## [1.0.0] - 2026-08-07

### 新增

- SL 启动器基线：游戏版本下载 / 安装 / 启动、账户与游戏目录管理
- Modrinth 全量目录爬虫（`crawl_modrinth.py`）与本地全量列表 / 搜索 / 实时翻译
- 加载器检测缓存与重试、26.x 版本分类、详情页、版本卡片放大裁剪与图标映射
