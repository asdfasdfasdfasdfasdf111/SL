# Core/Minecraft

Minecraft 实例领域的**只读抽象**。当前阶段只做「建立结构」：
仅新增文件，未修改 / 删除任何既有文件，未接线，行为零变化。

## 一、为什么只做只读

`qwq/PCLCore/Minecraft/` 是启动链路的心脏，规模与耦合度如下：

| 文件 | 行数 | 说明 |
| --- | --- | --- |
| `MinecraftInstance.swift` | 493 | 实例本体：加载清单、检测版本、选 Java、启动、存配置 |
| `ClientManifest.swift` | 397 | 客户端清单解析（库、natives、参数、规则） |
| `Download/MinecraftInstaller.swift` | 450 | 资源补全 |
| `Download/InstallTask.swift` | 488 | 下载任务调度 |
| `Launch/MinecraftLauncher.swift` | 338 | 进程拉起与参数组装 |
| `Launch/LaunchFix.swift` | 116 | 客户端文件校验与修复（上帝对象） |
| `MinecraftDirectory.swift` / `MinecraftVersion.swift` / `AssetIndex.swift` / `VersionManifest.swift` | 94 / 71 / 40 / 135 | 目录、版本、资源索引、版本清单 |

`MinecraftInstance` 的关键约束是**构造即副作用**：`create` → `setup` → `loadConfig` / `loadManifest`
→ `detectVersion` → `resolveAndApplyJava` → `saveConfig`（会自动挑 Java 并把结果写回 `.PCL_Mac.json`）。

因此本阶段**只做只读抽象**，不试图改造它。UI 需要的只是「有哪些实例、各自什么版本/加载器」，
这类查询不应触发实例初始化与配置写回。

## 二、文件与职责

| 文件 | 内容 | 说明 |
| --- | --- | --- |
| `MinecraftInstanceInfo.swift` | `MinecraftLoaderKind`、`MinecraftVersionKind`、`MinecraftInstanceInfo` | 只读快照 + PCLCore 枚举的镜像 |
| `MinecraftRepository.swift` | `MinecraftRepository`、`DirectoryScanningMinecraftRepository` | 实例查询协议与只读扫描实现 |
| `MinecraftModule.swift` | `MinecraftModule` | `SLModule` 实现，注册能力键 `minecraft.repository` |

### 关于两个镜像枚举

`MinecraftInstance.clientBrand` 的类型 `ClientBrand` 与 `MinecraftVersion.type` 的类型 `VersionType`
都是 PCLCore 的公开非 frozen 枚举，未声明 `Sendable`，不能作为本模块值类型快照的字段。
故各自镜像一份（`MinecraftLoaderKind` / `MinecraftVersionKind`），取值字符串与 PCLCore 完全一致，
并提供单向转换。这与 `JavaArchitecture` 镜像 `Architecture` 是同一处理方式。

## 三、快照字段的来源与可得性

| `MinecraftInstanceInfo` 字段 | 来源 | 扫描实现（未初始化实例） | `init(_:)` 快照（已初始化实例） |
| --- | --- | --- | --- |
| `name` | `MinecraftInstance.name` | 版本目录末段 | 同左 |
| `runningDirectory` | `runningDirectory` | `<root>/versions/<name>` | 同左 |
| `minecraftRootDirectory` | `minecraftDirectory.rootURL` | 扫描传入的根目录 | 同左 |
| `versionName` | `version.displayName` | 清单 `id`，缺失回落目录名 | 实例已解析的版本名 |
| `versionKind` | `version.type` | 清单 `type`，缺失回落 `.release` | `version.type` |
| `loader` | `clientBrand` | 清单文本关键字判定 | `clientBrand`（可为 `quilt`） |
| `manifestJavaVersion` | `manifest.javaVersion` | 清单 `javaVersion` | `manifest.javaVersion` |
| `manifestPath` / `configPath` | 计算属性 | `<name>.json` / `.PCL_Mac.json` | 同左 |

两条路径的**判定口径一致**，但扫描路径的字段可得性更低：清单损坏或缺失时只会回落，
不会像 `MinecraftInstance.create` 那样直接构造失败。

## 四、刻意没有建模的字段

- **最后启动时间**：`MinecraftInstance` 与 `.PCL_Mac.json` 均**无此字段**，全库也没有任何写入点
  （`grep -n "lastLaunch\|launchedAt"` → 0 命中）。可用文件系统时间近似，但需要先定义语义
  （是启动时间，还是清单被改写的时间），属新增能力，确认前不写入模型。
- **`isUsingRosetta`**：启动时的瞬时判定结果（由所选 JVM 架构决定），不是实例的持久属性。
- **`config`（内存/Java 路径/附加库）**：属启动参数职责，归启动模块。
- **`process`**：进程句柄，归进程控制职责。
- **`icon`（`getIconName()`）**：纯展示派生值，可由 `versionKind` + `loader` 在 UI 侧算出
  （对应 `MinecraftInstance.getIconName()` 的分支），不重复存储。

## 五、与既有文件的将来归属

| 现状 | 迁移去向 |
| --- | --- |
| `MinecraftInstance.create` / `loadInnerInstances` 的**查询**调用点 | 改为 `MinecraftRepository.instances()` / `inspect(id:)` |
| `MinecraftInstance` 的**构造与启动**（`launch`） | 保持不变，属启动模块职责，本阶段不动 |
| `MinecraftInstance.resolveMinJavaVersion` | 已由 `JavaRequirement(manifestJavaVersion:mcVersion:)` 覆盖，后续在启动模块内统一 |
| `MinecraftInstance.findSuitableJava` / `resolveAndApplyJava` | 目标由 `JavaResolver`（`qwq/Features/Java/`）承担，启动链路接线时切换 |
| `ClientManifest` / `AssetIndex` / `VersionManifest` | 保留。属清单与资源索引解析，不是「实例查询」 |
| `MinecraftDirectory.loadInnerInstances` | 保留，但其「顺带构造实例」的语义在查询路径上被本仓储取代 |
| `Launch/LaunchFix.swift` | 已由 `qwq/Features/Launch/LaunchPreflight.swift` 的四类校验器拆分，接线时切换 |

## 六、迁移步骤（后续执行，当前未做任何改动）

**第 1 步：UI 查询改走仓储**
启动页 / 版本列表页读取实例的调用点改为 `MinecraftRepository.instances()`，
按 `MinecraftInstanceInfo` 渲染，不再为列表展示构造 `MinecraftInstance`。
验收：列表条目（名称、版本、加载器图标）与现状一致，且打开列表不再触发 Java 扫描与配置写回。

**第 2 步：把 `MinecraftModule` 登记进模块清单**
`ModuleRegistry.swift` 的 `AppModuleBootstrap.makeRegistry()` 中加入 `MinecraftModule()`
（**该文件本轮不允许修改，故此项留待接线时执行**）。
验收：`context.require(ModuleCapabilityKey<MinecraftRepository>("minecraft.repository"))` 可取到实例。

**第 3 步：收窄实例 API**
确认无 UI 直接读 `MinecraftDirectory.instances` 后，将其访问级别收窄为 `internal`。

**第 4 步：评估是否暴露写能力**
若后续需要「新建实例 / 删除实例」，再为 `MinecraftRepository` 增加写方法，
而不是让 UI 直接调 `MinecraftInstance.create`。写方法必须显式承担副作用，
届时单独评审。

## 七、接线状态

**本轮 0 处接线**。`DirectoryScanningMinecraftRepository` 与两个镜像枚举未改动，
只做只读核对（`MinecraftLoaderKind` / `MinecraftVersionKind` 的取值与
`ClientBrand`（`MinecraftInstance.swift:479-484`）、`VersionType`
（`MinecraftVersion.swift:49-57`）逐字一致，无偏差）。

| 目标 | 调用点 | 状态 |
| --- | --- | --- |
| 实例列表 / 单实例查询 | `MinecraftDirectory.loadInnerInstances` 全库**调用点 0 处**；`MinecraftInstance.create` 的调用点集中在 `qwq/PCLCore/**` 与 `qwq/Features/Launch/Adapters/**` | 未接线：没有落在 `qwq/Core/Minecraft/Module/**` 内的调用点，而本模块本轮只允许改这一目录 |
| UI 版本列表 | `Features/Game/GameScanService.swift:14`、`Features/Game/GameCategoryView.swift:169`、`Features/Download/ModDragInstaller.swift:15` | 未接线：走的是 `MinecraftVersionManager.getVersions(from:)`（字符串列表），与本仓储的实例快照不是同一数据结构，且调用点不在允许范围 |

**接线前必须先解决的语义不一致**：`MinecraftRepository` 的默认根目录来源是
`AppSettings.shared.currentMinecraftDirectory`（`resolveRoots()`），该字段全库无写入点、
恒为 `MinecraftDirectory.default`（即 `~/Library/Application Support/minecraft`）；
而 UI 实际的游戏根目录是 `LauncherSettings.selectedGameRoot`
（由 `GameScanService` 扫描结果或 `NSOpenPanel` 选择写入，见 `GameCategoryView.swift:121 / 149 / 172`）。
两者通常不是同一目录，直接接线会让「实例列表」改从另一路径读取，属行为变化，故本阶段不接。
建议后续为 `MinecraftRepository` 增加显式根目录注入（已有 `init(roots:)`，只需由调用方传入
`selectedGameRoot`），再执行迁移步骤第 1 步。

## 八、测试挂载点

`MinecraftRepository` 可实现为固定数组的内存版本，无需真实磁盘：

- `DirectoryScanningMinecraftRepository(roots:)`：指向临时目录，构造 `versions/<name>/<name>.json`
  验证版本名、类型、加载器与 `javaVersion` 的解析；
- 清单缺失 / 损坏：验证 `versionName` 回落目录名、`versionKind` 回落 `.release`；
- `inspect(id:)`：传入非标准化路径（含 `..` 或多余分隔符）仍应命中；
- `MinecraftLoaderKind(manifestText:)`：四种关键字顺序（neoforged 优先于 forge）；
- `MinecraftVersionKind(rawVersionType:)`：八种取值与未知取值的回落。
