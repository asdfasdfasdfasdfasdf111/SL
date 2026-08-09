# 更新日志

本文件记录 SL 启动器（qwq）的重要变更。版本格式遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 修复

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

### 新增

- 下载校验：客户端 jar、依赖库、原生库下载接入 SHA-1 校验
- 本地 Modrinth 全量目录更新至 122,477 条目（模组 71,706 / 资源包 31,918 / 光影 781 / 整合包 18,072），覆盖更完整
- JVM 启动参数动态补齐：按平台与 Java 主版本自动注入缺失参数（macOS 补 `-XstartOnFirstThread`、Java 8 及以下补 `-XX:+UseG1GC`、补 `-XX:+HeapDumpOnOutOfMemoryError` 与 `-Dfile.encoding=UTF-8`），全部先查重再追加，与版本清单自带参数不冲突
- 借鉴 GitHub 开源项目 Swift-Craft-Launcher（AGPL-3.0，仅参考思路）进一步深化 JVM 参数优化：`-Xms` 堆初始大小动态补齐（默认 maxMemory 的一半、下限 256m，消除堆扩张停顿）；Java 9+ 且未显式指定 GC 时注入 G1 停顿调优（`-XX:+ParallelRefProcEnabled` / `-XX:MaxGCPauseMillis=200`）；补 `-XX:+OmitStackTraceInFastThrow` 与 `-XX:+OptimizeStringConcat` 零风险运行时优化，全部查重后追加
- 离线用户名输入实时提示（PCL2 HintChinese 语义）：输入框下方动态显示校验提示——超过 16 字符提示「用户名不能超过 16 个字符」，包含英文数字下划线以外字符时提示 1.18+ 服务端可能拒绝；启动时对含非法字符的用户名弹窗警告「可能无法进入游戏」，支持「仍要启动」以兼容 1.18 之前的版本

### 变更

- 应用图标内容整体缩小至 0.85 倍（像素尺寸不变，内容居中），视觉上更紧凑
- 空闲时静默后台：网速计速器改为惰性启动（有流量才跑，空闲 3 秒自停，不再常驻每秒唤醒）；游戏日志改为增量读取（不再全量重读文件）；窗口检测轮询由 1 秒降频至 2 秒——应用空闲时几乎不再产生 CPU 与内存占用
- 翻译结果内存上限：实时翻译字典最多保留 2000 条，超限优先裁剪非活跃条目，磁盘缓存兜底恢复，长会话内存不再无限增长
- Java 主版本探测合并为一次读取（`release` 文件解析），版本校验与参数过滤共用结果，减少重复磁盘 IO
- 代码极致模块化：`GameViews.swift` 由 2776 行拆分为 4 个职责单一文件——`GameViews.swift`（1516 行，列表与分类视图）、`ModDetailView.swift`（详情页）、`ContentCard.swift`（内容卡片）、`GameCards.swift`（依赖卡/加载器选择卡/版本卡/网格卡），可读性与可维护性大幅提升
- 修复 AppIcon 资源引用缺失导致的 32x32@2x 图标缺口
- 在线列表缓存优先：进入页面/搜索时先读磁盘缓存（离线、弱网也能秒开上次内容），无缓存才请求网络；所有分类列表拉取成功后自动持久化到磁盘缓存

## [1.0.0] - 2026-08-07

### 新增

- SL 启动器基线：游戏版本下载 / 安装 / 启动、账户与游戏目录管理
- Modrinth 全量目录爬虫（`crawl_modrinth.py`）与本地全量列表 / 搜索 / 实时翻译
- 加载器检测缓存与重试、26.x 版本分类、详情页、版本卡片放大裁剪与图标映射
