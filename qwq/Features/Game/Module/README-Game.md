# Game 模块（版本浏览与选择）

本目录是 Game 域的**模块内核**。模块定义遵循工程约定：编译期模块，
不做 `.bundle` 动态加载、不做运行时类扫描、不做 Plugin.json。

第一阶段只做「建立骨架 + 视图收口」：**未接线**（`AppModuleBootstrap` 只登记 `SettingsModule`），
未修改、删除任何既有文件的行为，分类页布局 / 文案 / 交互 / 动画参数逐字未变。

## 一、文件与职责

| 文件 | 内容 | 说明 |
| --- | --- | --- |
| `MinecraftVersionInfo.swift` | `ClientManifestSnapshot`、`MinecraftVersionInfo` | 版本只读快照；字段逐一对齐 `MinecraftVersion` / `ClientManifest` / 清单条目的真实属性 |
| `VersionCatalogService.swift` | `VersionCatalogService`、`DefaultVersionCatalogService` | 清单取数协议 + `GameVersionManifest` 适配器（不重写拉取与缓存逻辑） |
| `VersionFilterUseCase.swift` | `VersionCatalogCategory`、`VersionFilterUseCase` | 正式版 / 测试版（快照）/ 远古版三分桶规则的唯一实现处 |
| `GameModule.swift` | `GameModule` | `SLModule` 实现，注册能力键 `game.versionCatalog`、`game.versionFilter` |

依赖方向单向：视图模型 → 用例 → `VersionCatalogService` 协议 → `GameVersionManifest` /
`GameVersionHelper`。协议实现为无状态 `struct`，可直接跨并发域传递。

## 二、字段对照（不臆造字段）

| 快照字段 | 真实来源 |
| --- | --- |
| `id` | `MinecraftVersion.displayName`（PCLCore/Minecraft/MinecraftVersion.swift:11）；与清单条目 `"id"` 同语义 |
| `type` | 清单条目 `"type"` 原文；取值与 `VersionType`（同文件 :49）rawValue 一致 |
| `releaseTime` | 清单条目 `"releaseTime"` 原文（保留 ISO8601 字符串，按字符串比较即得时间序） |
| `manifestURL` | 清单条目 `"url"`（该版本的客户端清单地址） |
| `kind` | 由 `type` 经 `MinecraftVersionKind(rawValue:)` 归一；**不识别时为 nil** |
| `client` | `ClientManifest` 公开属性快照：`id` / `mainClass` / `type` / `javaVersion` / `assetIndex?.id` / `clientDownload?.url` |

两处刻意约定：

- **版本类型不另建枚举**，直接复用既有 `MinecraftVersionKind`
  （Core/Minecraft/Module/MinecraftInstanceInfo.swift:68，镜像 `VersionType`）。
  取其 `rawValue` 可失败构造而**不用** `init(rawVersionType:)`：后者回落 `.release`，
  会把未识别 type 误判为正式版，与既有 `GameVersionFilter` 行为不符。
- **保存 `type` 原文**：既有 `GameVersionHelper.isAprilFoolVersion(id:type:)` 按原文判定，
  保存原文才能保证过滤结果与收口前逐条一致。

## 三、分类规则（`VersionFilterUseCase`）

| 分类 | 规则 |
| --- | --- |
| 正式版（`.release`） | `kind == .release`（含 1.7.x、1.8、1.12.2 等老正式版） |
| 测试版（`.snapshot`，即快照） | `kind` 为 `.snapshot` 或 `.pending`，且不是愚人节版本 |
| 远古版（`.ancient`） | `kind` 为 `.alpha` 或 `.beta`，或任意愚人节版本 |
| `.all` | 不过滤（模块附加视图，不对应侧边栏条目；`subCategory == nil` 仍返回空，与既有 `.none` 分支一致） |

愚人节判定委托 `GameVersionHelper.isAprilFoolVersion(id:type:)`，模块内不重复实现命名规则。

`GameVersionFilter.filteredIDs(_:subCategory:)` 已改为本用例的适配器（`[[String: Any]]` → 快照），
签名与输出不变，`ModDetailView` 与分类页共用同一份规则，不再各写一遍 switch。

## 四、视图收口

`Features/Game/GameViews.swift` 的 `DownloadCategoryView` 按 `ContentView` 同一做法收口：

| 收口去向 | 内容 |
| --- | --- |
| `ViewModels/DownloadCategoryViewModel.swift` | 侧边栏选中态、列表数据、搜索决策树（防抖 400ms，四个分支）、分页、请求归属令牌、详情页选中态、清单 → 列表项转换 |
| 保留在视图 | 布局计算（列宽 / 卡片宽）、滚动网格、全部 `withAnimation` 与动画参数、侧栏高亮 y 偏移（`SidebarHighlight.offsets`）、子项弹入透明度、内容淡入淡出、`CardTranslationModel` 的持有与订阅 |

行数：`GameViews.swift` 591 → 303 行。

`CardTranslationModel` 仍由视图以 `@StateObject` 持有，视图模型只按方法参数接收其引用以调度预取，
不接管其生命周期与订阅（保持原有失效粒度）。

隔离标注：`DownloadCategoryViewModel` 标注 `@MainActor`。收口前这些决策方法位于 `View` 遵循类型内
（`View` 协议带全局 actor 标注，遵循类型随之推断为该 actor 隔离），标注后隔离语义与收口前相同，
同时满足对 `@MainActor` 的 `CardTranslationModel` 同步调用的要求。

依据条目：

- `@StateObject` / `@ObservedObject`：https://developer.apple.com/documentation/swiftui/stateobject、https://developer.apple.com/documentation/swiftui/observedobject
- `Sendable` 与全局 actor 推断：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
- 协议要求默认 non-isolated：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/
- `onChange(of:perform:)`（现行 `onChange(of:initial:_:)` 需 macOS 14.0+，本项目部署目标 13.0 不可用，沿用旧签名）：https://developer.apple.com/documentation/swiftui/view/onchange(of:perform:)

## 五、刻意没有建模 / 没有抽取的东西

- **安装编排**（`GameVersionDownloadStarter`）：跨下载模块的编排，属安装域，不并入版本浏览模块。
- **本地实例扫描**（`GameScanService` / `GameDirectoryScanner` / `GameInstance`）：属本地实例域，
  与「清单版本浏览」不是同一数据来源（前者读磁盘 versions 目录，后者读 Mojang 清单）。
- **详情页版本选择**（`VersionSelectionSection` / `DetailVersionDecision` / `DetailPageType` /
  `CrossVersionFinder`）：属 ModDetail 详情域，分类页只是宿主，不属于 Game 模块。
- **`GameVersionHelper` 比较与排序**：已被详情域复用，改动面超出本模块，仅保存引用关系。
- **死代码 `GameGridCard`**：全库无构造点，标注 `@available(*, deprecated)` 保留，本次不动。
- **`GameVersionManifest` 的磁盘缓存 key 与 TTL**：属基础设施策略，仍在原处，不改写。

## 六、编译验证（两口径）

```
DEV=$(xcode-select -p)
# 口径一（含 qwqTests）
xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps \
  -F "$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
  -I "$DEV/Platforms/MacOSX.platform/Developer/usr/lib" \
  -module-name qwq $(find qwq -name "*.swift") qwqTests/*.swift
# 口径二（与 App target 一致的默认 MainActor 隔离）
xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps \
  -F "$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
  -I "$DEV/Platforms/MacOSX.platform/Developer/usr/lib" \
  -module-name qwq -default-isolation MainActor $(find qwq -name "*.swift")
```

两口径均为 0 error，告警集合与收口前逐条一致（口径一 44、口径二 58）。
