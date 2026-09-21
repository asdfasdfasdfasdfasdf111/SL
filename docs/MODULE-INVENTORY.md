# 模块化盘点与优化清单

日期：2026-09-21
统计口径：`qwq/` 下 198 个 Swift 文件、23,801 行

## 一、模块清单与状态（14 个模块）

| # | 模块 | 代码量 | 骨架 | 接线 | 说明 |
|---|---|---|---|---|---|
| 1 | Settings | 412 行 / 3 文件 | ✅ | ✅ | `AppSettingsStore` 为唯一存储点，旧 `ThemeManager` 收窄为只读转发 |
| 2 | Java | 1555 行 / 13 文件 | ✅ | ✅ | 唯一 `JavaResolver`；启动链已改走它 |
| 3 | Download | 3033 行 / 30 文件 | ✅ | 🔶 部分 | 抽象层 + 适配器完成；调用方已切 7 处，批量路径判定"切换会改变进度表现"未切 |
| 4 | Launch | 2332 行 / 20 文件 | ✅ | ✅ | `LaunchCoordinator` 已改走 `LaunchService`；桥接层退化为参数转换 |
| 5 | ModBrowser | 3083 行 / 24 文件 | ✅ | 🔶 部分 | 详情查询已接；检索调用点在 `Features/Game`（未模块化），暂无法接 |
| 6 | Minecraft | 318 行 / 3 文件 | ✅ | ❌ | 只读抽象已建；仓储根目录与实际使用目录不一致，接上即行为变化，故未接 |
| 7 | Skin | 882 行 / 10 文件 | ✅ | 🔶 部分 | 已接 4 处 |
| 8 | Theme | 121 行 / 4 文件 | ✅ | ❌ | `ThemeManager` 与 `AppSettingsStore` 曾双写同一 key（已收敛），但服务层是 async 取值、界面是订阅式，接入会读到过期色 |
| 9 | **Game** | 2372 行 / 18 文件 | ✅ | ❌ | 原 **0 个模块件**；`GameViews` 591 行、`GameCards` 286 行、`VersionSelectionSection` 227 行。收口进展：新增 `Module/` 模块内核 4 文件 + `README-Game.md`，`GameViews` 591→303 行（业务决策收口到 `ViewModels/DownloadCategoryViewModel`），`GameModule` 注册能力 `game.versionCatalog` / `game.versionFilter`，`GameVersionFilter` 改为 `VersionFilterUseCase` 适配器；`AppModuleBootstrap` 沿用未登记状态，故接线仍为未接 |
| 10 | **Translation** | 537 行 / 7 文件 | ❌ | ❌ | `TranslationService` 144 行、`CardTranslationModel` 140 行 |
| 11 | **Account / 兼容层** | 7526 行 / 41 文件 | ❌ | ❌ | `PCLCore` 全域；含 **11 个单例** |
| 12 | **UI** | 1423 行 | 🔶 部分 | — | `Notices`、`Shell`、`Modifiers` 为新建；`ViewComponents` 182 行仍未归口 |
| 13 | **App** | 1052 行 | 🔶 部分 | — | `ContentView` 297 → 132 行，已抽 4 个 ViewModel |
| 14 | **Infra** | 391 行 | ❌ | ❌ | `Services`（CacheManager 303 行）、`Models`、`PCLCore/Utils` 未归口 |

## 二、完成度量化

| 指标 | 数值 |
|---|---|
| 模块总数 | 14 |
| 已有骨架 | **8 / 14 = 57%** |
| 已完成接线 | **3 / 14 = 21%**（Java、Launch 完整；Download 部分） |
| 按代码量覆盖 | 约 **10,991 / 23,801 = 46%** |
| 完全未动 | **6 个模块**（Game、Translation、Account/兼容层、Infra，以及 UI/App 的剩余部分） |

## 三、优化完成情况

### 已完成（本轮及前几轮）
| 类别 | 数量 | 内容 |
|---|---|---|
| 性能优化 | **3 处** | `CacheManager.diskGet` 去掉 fileExists（批量预取省约 5000 次 stat）；`ChineseText` 正则改为静态复用（原每次调用重编译，预取可达上万次）；`ModVersionDetector` 正则提到循环外 |
| 缺陷修复 | **20+ 项** | 提示通道 3 项、启动链路 5 项（D2–D6）、D1 客户端 JAR 校验、D7 进程终止失效、D8 失败被吞、皮肤资源包目录、8 处 actor 隔离错配、23 处 `@ObservedObject` 用法、窗口尺寸统一、归档安全编码、SIL 初始化违规、强调色双写收敛、`GameViews` 状态写入统一、README 同名冲突、缺失 Combine 导入 |
| 并发安全 | 3 处 | `JavaResolverBridge` 数据竞争、`GameProcessController` 续体泄漏、`LocalModCatalog` 的 `NSLock` in async |

### 已知待优化（明确可做，尚未做）
1. **`CacheManager` 只读路径去隔离** —— 收益最大：翻译卡片目前在主线程读盘（`CardTranslationModel` 的 `Task.detached` 实际 `await` 回主 actor）。需要先给 `CacheManager` 的只读路径标注 `nonisolated`
2. **`ModVersionDetector` 减少进程创建** —— 每个 jar 最多 spawn 5 次 `unzip`，可先 `unzip -l` 列一次目录再定位条目
3. **`LocalModCatalog.loadCatalog` 缩短临界区** —— 持全局锁做 gzip 解压 + 12 万条 JSON 解析

## 四、剩余模块扫描结果（按优先级）

### P0：`PCLCore`（7526 行、41 文件、11 个单例）—— 最大的未模块化区
| 文件 | 行数 | 问题 |
|---|---|---|
| `Download/NetDownloader.swift` | **889** | 单文件承担预检、多源、分片、重试、黑名单、测速、合并、校验、调度、取消；抽象层已建，但批量路径未切 |
| `Minecraft/Mod/Loader/LoaderSupportChecker.swift` | **609** | 加载器兼容性判定，无测试、无边界定义 |
| `Minecraft/Download/MinecraftInstaller.swift` | **526** | 安装编排与下载混杂 |
| `Minecraft/Download/InstallTask.swift` | **513** | 安装任务状态机 |
| `Minecraft/MinecraftInstance.swift` | **505** | 启动核心，只读抽象已建未接 |

**该做什么**：把 11 个单例逐个收口（谁持有、谁能改、单元测试怎么替身），优先 `NetDownloader`（风险最高）与 `MinecraftInstance`（启动核心）。

### P1：`Features/Game`（2372 行、18 文件、0 模块件）—— 最大的未模块化功能域
| 文件 | 行数 |
|---|---|
| `GameViews.swift` | **591** |
| `GameCards.swift` | **286** |
| `VersionSelectionSection.swift` | **227** |
| `VersionUtils.swift` | 193 |
| `GameCategoryView.swift` | 184 |

**该做什么**：`GameViews` 用与 `ContentView` 相同的方式收口（业务决策移入 ViewModel）；建立 `GameModule`（版本清单、安装状态、版本过滤三个能力）。

### P2：基础设施
- `Services/CacheManager.swift`（303 行）：去隔离（见 待优化 1）
- `Features/Translation`（537 行）：建立 `TranslationModule`，把 `translateText` 的主线程阻塞问题一并解决
- `UI/ViewComponents.swift`（182 行）：拆为按用途分组的组件文件

### P3：UI / App 剩余部分
- `UI/Notices/NoticeCenter.swift`（202 行）：功能已可用，暂不需动
- `App/ContentView.swift`（132 行）：已从 297 行收口，剩余为窗口壳与布局，可接受

## 五、结论

- **模块化进度：骨架 8/14，接线 3/14，代码覆盖约 46%**
- **最大缺口：`PCLCore`（7526 行、11 单例）与 `Features/Game`（2372 行）**
- **优化：已完成 3 处性能 + 20+ 项缺陷；已知待做 3 处**
