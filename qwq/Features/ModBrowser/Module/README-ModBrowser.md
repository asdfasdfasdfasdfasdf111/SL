# ModBrowser 模块（Modrinth 项目浏览）

本目录是 ModBrowser 的**目标结构**。当前阶段只做「建立结构」：
仅新增文件，未修改 / 删除任何既有文件，未接线，行为零变化。

模块定义遵循工程约定：编译期模块，不做 `.bundle` 动态加载、不做运行时类扫描、不做 Plugin.json。

## 一、文件与职责

| 文件 | 内容 | 说明 |
| --- | --- | --- |
| `ModProject.swift` | `ModProjectType`、`ModProjectFile`、`ModProjectVersion`、`ModProject` | 统一项目模型，含四个既有数据源的转换入口 |
| `ModSearchRequest.swift` | `ModSearchRequest` | 检索入参。字段对齐 `ModrinthSearcher.search` 的真实能力 |
| `ModSearchResult.swift` | `ModSearchResult` | 一页检索结果 + `totalHits` / `hasMore` |
| `ModBrowserService.swift` | `ModBrowserError`、`ModBrowserService`、`DefaultModBrowserService` | 对外协议与既有实现的适配器 |
| `ModSearchUseCase.swift` | `ModProjectDetail`、`ModSearchUseCase` | 检索与详情读取用例，只依赖协议 |
| `ModInstallUseCase.swift` | `ModInstallRequest`、`ModInstallPlan`、`ModInstallUseCase` | 安装准备用例：选版本 → 定主文件 → 定目标路径 |
| `ModBrowserModule.swift` | `ModBrowserModule` | `SLModule` 实现，注册能力键 `modbrowser.service` |

依赖方向单向：用例层 → `ModBrowserService` 协议 → 既有 `ModrinthSearcher` / `ModDownloader`。
下层不认识上层，可逐个替换并单测。

## 二、统一模型对应关系

| 统一模型字段 | `ModrinthMod` | `ModrinthProject` | `LocalModCatalog.Item` | `DownloadedItem` |
| --- | --- | --- | --- | --- |
| `id` | `id` | `id` | `projectID` | `id` |
| `slug` | `slug` | — | — | — |
| `title` | `title` | `title ?? id` | `title` | `name` |
| `description` | `description` | — | `description` | `subtitle` |
| `iconURL` | `icon_url` | — | `iconURL` | `iconURL` |
| `downloads` | `downloads` | — | `downloads` | — |
| `categories` | — | — | `categories` | `tags` |
| `gameVersions` | — | `game_versions` | — | — |
| `loaders` | — | `loaders` | — | — |
| `versionIDs` | `versions` | — | — | — |
| `projectType` | 调用方传入 | — | `projectType` | 调用方传入 |

「—」表示该数据源不提供此字段，转换后为 nil / 空数组。**不臆测填充**：
调用方必须按可选语义处理，不要假定某字段一定有值。

## 三、刻意没有建模的东西

- **检索的 loader / 游戏版本过滤**：`ModrinthSearcher.search` 只发送 `project_type` facet，
  不发送 `categories`（loader）与 `versions` facet，没有实现的能力不写进 `ModSearchRequest`。
  加载器与游戏版本过滤只在版本查询与安装用例中生效——那里 `ModDownloader.getVersions`
  确实支持这两个查询参数。
- **分类过滤（`ItemFilter` / `ModrinthTagMap`）**：属纯展示层谓词，留在 UI 侧，不进模块模型。
- **本地全量目录的预热与翻译预取**（`LocalModCatalog.warmUp` / `preTranslateAll`）：
  属启动期性能策略，与「项目数据从哪来」无关，暂不纳入。
- **版本范围表达式**（如 `>=1.20 <1.21`）：`ModVersionDetector.versionMatches` 已实现，
  但详情页/安装流程当前并未使用；接入前不在用例层重复实现。

## 四、既有 17 个文件的将来归属

`qwq/Features/ModBrowser/` 现有 17 个文件，按职责可分为四类：

| 现状文件 | 类别 | 迁移去向 |
| --- | --- | --- |
| `ModrinthModels.swift` | API 模型 | 保留。作为适配层输入，不再被 UI 直接解码使用 |
| `ModDownloader.swift` | 网络访问 | 保留。降级为 `ModBrowserService` 的实现细节；`ModError` 不再向 UI 泄漏 |
| `ModrinthSearcher.swift` | 网络访问 | 保留。同上，检索路径的底层实现 |
| `ModLoader.swift` | 领域枚举 | 保留。`ModLoader.rawValue` 是模块协议中加载器过滤的取值形态 |
| `LocalModCatalog.swift` | 本地数据源 | 保留。后续作为 `ModBrowserService` 的第二个数据源（离线全量目录）接入 |
| `ModrinthCategoryCache.swift` | 缓存 | 保留。属实现细节，不上提为协议 |
| `ModDetailView.swift` | UI | 改造：改为持有 `ModSearchUseCase`，经 `ModProjectDetail` 渲染 |
| `CategoryContentView.swift` | UI | 改造：检索改走 `ModSearchUseCase.search`，分页改走 `ModSearchRequest.nextPage()` |
| `CategoryResultsGrid.swift` / `ContentCard.swift` / `CategorySearchBar.swift` / `CategoryCanvasPlaceholder.swift` | UI | 改造：数据源从 `DownloadedItem` 切到 `ModProject` |
| `ItemFilter.swift` | UI 谓词 | 保留在 UI 侧，模型字段不变，可从 `ModProject` 取值 |
| `ModrinthSectionType.swift` | 映射 | 保留。其输出即 `ModProjectType.rawValue` |
| `ModLoaderDetector.swift` | 本地文件检测 | 保留。属本地 mods 目录扫描，非 Modrinth 数据 |
| `ModVersionDetector.swift` | 本地文件检测 | 保留。同上 |
| `Category.swift` | 侧边栏 UI | 保留，与模块无关 |

`qwq/PCLCore/Minecraft/Mod/Loader/`（Forge / Fabric / NeoForge 安装器）属**加载器安装**，
与项目浏览无关，不纳入本模块。

## 五、迁移步骤（后续执行，当前未做任何改动）

**第 1 步：详情页切到用例层**
`ModDetailView` 改为持有 `ModSearchUseCase`，详情与版本一次取回。
验收：详情页展示内容与现状一致（图标、标题、简介、版本列表、加载器标签）。

**第 2 步：分类页切到用例层**
`CategoryContentView` 的检索改走 `ModSearchUseCase.search`，翻页改用 `nextPage()`。
验收：四种 project_type 的列表、翻页、空结果提示与现状一致。

**第 3 步：安装路径切到安装用例**
`ModDownloader.autoDownloadMod` / `resolveLatestFile` 的调用点改为
`ModInstallUseCase.makePlan` + `Core/Download` 的下载引擎。
验收：目标路径仍为 `<gameRoot>/versions/<version>/mods`，sha1 一致，文件可被游戏加载。

**第 4 步：把 `ModBrowserModule` 登记进模块清单**
`ModuleRegistry.swift` 的 `AppModuleBootstrap.makeRegistry()` 中把 `ModBrowserModule()` 加入
`modules` 数组（**该文件本轮不允许修改，故此项留待接线时执行**）。
验收：`context.require(ModuleCapabilityKey<ModBrowserService>("modbrowser.service"))` 可取到实例。

**第 5 步：收窄既有入口**
确认无 UI 直接调用后，`ModDownloader` / `ModrinthSearcher` 收敛为 `internal`，
仅由本目录的适配器引用。

## 六、接线状态

已接线 1 处；`DefaultModBrowserService` 本身未改动，仍为既有实现的原样适配。

| 目标 | 调用点 | 状态 |
| --- | --- | --- |
| 详情读取 | `Features/ModBrowser/ModDetailView.swift:79` `fetchProjectDetails()` | **已接线**：`ModDownloader().getProject(modId:)` → `DefaultModBrowserService().projectDetail(id:)`，取 `gameVersions` / `loaders` |
| 检索 | `Features/Game/GameViews.swift:135 / 164 / 525` | 未接线：调用点在 `qwq/Features/Game/**`，本轮不允许修改 |
| 安装解析 | `Features/Download/DownloadFileResolver.swift:43 / 52 / 61` | 未接线：调用点在 `qwq/Features/Download/**`，同上 |
| 离线全量目录预热 | `App/qwqApp.swift:11`、`Features/Game/GameViews.swift:205` | 未接线：属启动期策略，且调用点不在允许范围 |

已接线点的行为一致性依据：

- `ModDownloader.getProject` 不读写 `searchCache`（`searchCache` 仅 `searchMods` 使用），
  因此由「每次新建实例」改为「`DefaultModBrowserService` 内的共享静态实例」不改变缓存命中与返回值；
- `ModProject.gameVersions` / `loaders` 在转换时已按 `?? []` 归一，与既有 `project.game_versions ?? []` 同义；
- 错误仍由同一 `catch` 吞掉，未新增错误提示（该分支原先仅复位只写不读的 `isLoadingProject`，
  该死状态已随清理删除，错误路径行为不变）。

未采用 `ModSearchUseCase.detail(projectID:)`：它会额外请求一次版本列表，
而本视图的版本清单来自本地目录扫描，多出的一次往返属行为变化。

## 七、测试挂载点

`ModBrowserService` 可实现为内存版本（固定返回若干 `ModProject` / `ModProjectVersion`），
无需真实网络：

- `ModSearchRequest.nextPage()`：偏移量顺推；
- `ModSearchResult.hasMore`：`offset + items.count` 与 `totalHits` 的边界；
- `ModProject` 四套转换：缺失字段是否按可选 / 空数组落地；
- `ModInstallUseCase.makePlan`：精确匹配优先、前缀匹配兜底、无命中抛
  `noCompatibleVersion`、版本无文件抛 `noDownloadableFile`；
- `ModProjectDetail.versions(matchingLoader:gameVersion:)`：单条件与双条件过滤。
