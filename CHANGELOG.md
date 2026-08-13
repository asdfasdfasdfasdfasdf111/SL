# 更新日志

本文件记录 SL 启动器（qwq）的重要变更，按版本发布记录。

## Beta 0.1.2 版本发布 🚀（2026-08-13）

新增游戏版本一键下载安装，支持 Fabric/Forge/NeoForge 加载器自动串联（对标 PCL.Mac DownloadPage）
新增毛玻璃下载详情页与全局圆形下载按钮，移植 PCL 的 InstallTask 任务模型（总进度 / 实时速度 / 逐任务阶段渲染）
新增崩溃自捕获（CrashReporter），崩溃时把堆栈写入 ~/Library/Logs/qwq_crash.log
新增下载 SHA-1 校验（客户端 jar / 依赖库 / 原生库）
新增 JVM 启动参数动态补齐与调优（-XstartOnFirstThread / G1GC / -Xms 等，查重后追加）
新增离线用户名输入实时提示（PCL2 HintChinese 语义）
新增游戏安装并发下载：原版 jar 与散列资源、依赖库与 natives 分波并行（PCL2 风格，全局 16 分片统一限流），加载器只等待 jar、散列资源后台继续
新增下载阶段独立进度：InstallTask 并行阶段状态机（beginParallelStage/finishParallelStage），详情页各阶段进度互不覆盖
新增版本列表缓存优先：磁盘缓存供首帧立即可展示（cachedMerged），联网刷新转后台执行，弱网/离线时列表不再长时间空白
本地 Modrinth 全量目录更新至 122,477 条目

优化加载器支持检测：三级缓存策略（内存 → 磁盘 7 天 TTL → 联网失败回退旧缓存），4xx 视为明确不支持，首次等待由数秒降至约 1 秒
优化实时翻译：按需翻译 + 并发上限 24 + 内存上限 2000 条，滚动浏览不再卡顿
优化空闲静默后台：计速器惰性启动、游戏日志增量读取、窗口轮询降频，空闲时几乎零 CPU 与内存占用
优化在线列表缓存优先：离线 / 弱网也能秒开上次内容
优化 Java 查找：7 类来源全量扫描，release 文件一次读取探测主版本
代码极致模块化：全工程巨型文件按「一个文件一个顶层声明」拆分为 30+ 个单一职责模块（累计 39 批收官）
优化build_asan3/ ASan 构建产物目录加入 .gitignore 忽略，与 build_asan/、build_asan2/ 同理不再入库

修复下载页选中未列出版本后立即崩溃：下载页合并清单与旧安装器 DataManager 清单不同步，旧代码查不到版本仍强制解包触发 assertionFailure；现先查旧清单、未命中再查合并清单 URL 索引，最终缺失时返回 nil 进入可恢复错误提示，彻底移除该路径断言
修复下载页游戏版本列表空白：官方 + 未列出两个清单源全部失败且无缓存时返回空数组；现增加 BMCLAPI 镜像自动回退（主源失败自动切换，不依赖设置二选一）+ CacheManager 磁盘缓存兜底（联网失败回退上次内容，弱网/被阻断时列表不再空白）
修复游戏版本下载首个 await 返回时的 EXC_BAD_ACCESS：Swift 6.2 在 Swift 5 + Approachable Concurrency + 默认 MainActor 组合下会误编译存储 async 闭包的 ABI（swiftlang/swift#86332），现将闭包属性与初始化参数显式统一为 @MainActor，杜绝隐式 actor 参数错位与损坏地址跳转
修复下载任务完成竞态导致的 UAF 风险：complete/dismiss 增加幂等与归属校验，杜绝旧任务迟到回调清掉新任务引用
修复 EXC_BAD_ACCESS 崩溃根因：全工程 17 文件 26 处视图生命周期回调同步状态写清零（Modifying state during view update）
修复下载链路 UAF：下载闭包零 self 捕获、动画改可取消 Task，视图销毁后不再写已释放的 State storage
修复启动参数规则匹配误删库（移植 PCL2 顺序叠加语义 Rule.check）
修复 JVM 参数动态补齐三处偏差（-Xmx 查重 / Log4Shell 防御 / natives 路径兜底）
修复 Java 查找链路五处功能失效（进程死锁 / 版本正则 / 并发覆盖 / 残留 JVM / stub 矛盾）
修复创建世界 / 进入世界 EncoderException（离线用户名超 16 字符，完整移植 PCL2 离线登录）
修复离线自定义皮肤无效（PCL2 皮肤资源包方案，全版本生效）
修复游戏关闭 / 手动关闭进程检测不到（terminationHandler 前置 + 超时轮询兜底）
修复下载详情页交互：圆按钮 toggle 开关、与主内容互斥整页替换、退出后滚动位置恢复
修复光影详情页返回后侧栏高亮不跳回
修复加载器选择页显示与所点版本不一致、1.10 等版本仍显示 4 张卡片
修复解压 ZIP 的路径穿越（ZIP Slip）漏洞
修复缓存读写并发死锁（NSLock → NSRecursiveLock）、崩溃日志误删共享目录、下载句柄未清理
修复下载进度负数、下载卡片无动画、Java 刷新按钮动画不同步
修复版本清单拉取失败缓存空结果、翻译缓存未全量应用等列表展示问题
修复并发下载进度不准：详情页按 stage 取独立进度、MultiFileDownloader 批次进度重复归一化（downloadAll 的 p 已是 0...1 不再除以文件数）、getProgress 除零/越界与 completeOneFile 完成计数下限保护

## Beta 0.1.1 版本发布 🚀（2026-08-07）

SL 启动器基线：游戏版本下载 / 安装 / 启动、账户与游戏目录管理
Modrinth 全量目录爬虫（crawl_modrinth.py）与本地全量列表 / 搜索 / 实时翻译
加载器检测缓存与重试、26.x 版本分类、详情页、版本卡片放大裁剪与图标映射
