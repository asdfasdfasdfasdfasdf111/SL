# Features/Theme

主题领域的**目标结构**。当前阶段只做「建立结构」：
仅新增文件，未修改 / 删除任何既有文件，未接线，行为零变化。

## 一、现状

工程里与"主题"相关的有三处，但只有一处真正生效：

| 位置 | 内容 | 实际作用 |
| --- | --- | --- |
| `Features/Settings/ThemeManager.swift:21` | `ThemeManager.shared.accentColor`（`@Published`，didSet 归档 `NSColor` 写 `UserDefaults[UDK.accentColor]`） | **当前唯一生效的主题来源**，约 19 处视图以 `@ObservedObject var theme = ThemeManager.shared` 读取 |
| `Features/Settings/AppSettingsStore.swift:18` | `accentColor`（`@Published`，didSet 写同一个 `UserDefaults[UDK.accentColor]`） | 设置模块的存储点，已注册为能力键 `settings.store` |
| `PCLCore/PCLStubs.swift:342` | `Theme`（桩实现，仅 `id` 字段，`load(id:)` 不读文件不解析配色） | **不参与任何渲染**，属历史遗留接口 |

需要注意的一致性问题：前两者是**两个独立的内存副本**，写的是同一个 UserDefaults 键。
`ThemeManager` 与 `AppSettingsStore` 各自在 `init` 时读取一次，之后互不通知，
因此运行期可能出现"设置页改了颜色，部分视图仍是旧色"的分歧。

## 二、文件与职责

| 文件 | 内容 | 说明 |
| --- | --- | --- |
| `ThemeDefinition.swift` | `ThemeDefinition` | 主题模型，当前只承载强调色 |
| `ThemeRepository.swift` | `ThemeRepository`、`AppSettingsThemeRepository` | 数据来源协议 + 从 `AppSettingsStore` 读取的最小实现 |
| `ThemeService.swift` | `ThemeService`、`DefaultThemeService` | 对外唯一门面（当前只读） |
| `ThemeModule.swift` | `ThemeModule` | `SLModule` 实现，注册 `theme.service` 与 `theme.repository` |

**不新建存储**：颜色值一律取自 `AppSettingsStore.accentColor`，本模块不写 UserDefaults、
不额外持有颜色副本。

## 三、为什么模型只有一个字段

现有实现中真实可主题化的内容只有强调色一项：

- `ThemeManager` / `AppSettingsStore` 都只提供 `accentColor`；
- `PCLStubs.Theme` 的 `id` 不具备渲染语义（`Theme.load(id:)` 只做对象构造）；
- 全库不存在主题目录、明暗变体、字体、圆角等配置。

因此 `ThemeDefinition` 只声明 `accentColor`。**不虚构尚未存在的配置项**，
未来某项配置真正落地时再扩字段，而不是先摆一堆空壳。

## 四、刻意没有纳入协议的东西

- **写入（切换强调色）**：`ColorPickerView.swift:29` 现在直接写
  `theme.accentColor = color`（即写 `ThemeManager`）。写入能力的收窄属设置模块职责，
  且 `AppSettingsStore.swift` 本轮不允许修改，故本阶段服务保持只读。
- **明暗模式**（`AppSettings.ColorSchemeOption`）：`PCLStubs.AppSettings` 中的 `ColorSchemeOption`
  属桩字段，无写入点，与主题渲染无关联。
- **`PCLStubs.Theme`**：桩实现，无渲染语义，不纳入也不删除（删除需改既有文件）。

## 五、迁移步骤（后续执行，当前未做任何改动）

**第 1 步：确认单一数据源**
把 `ThemeManager` 与 `AppSettingsStore` 的双副本合并为一份——
两者写的是同一个 `UserDefaults` 键，保留 `AppSettingsStore`（设置模块的存储点）、
让 `ThemeManager` 退化为对它的转发。
验收：设置页改色后，所有读取点同一帧内同步变色，不存在分歧。

**第 2 步：读取点改走门面**
19 处 `@ObservedObject var theme = ThemeManager.shared` 中，凡是非设置页的只读用法，
改为经 `ThemeService.currentTheme()` 取值（SwiftUI 侧仍需要一个可观察的桥接，
届时由设置存储的 `@Published` 承担）。
验收：视觉表现与现状一致。

**第 3 步：把 `ThemeModule` 登记进模块清单**
`ModuleRegistry.swift` 的 `AppModuleBootstrap.makeRegistry()` 中加入 `ThemeModule()`
（**该文件本轮不允许修改，故此项留待接线时执行**）。
验收：`context.require(ModuleCapabilityKey<ThemeService>("theme.service"))` 可取到实例。

**第 4 步：删除兼容层**
确认无读取点后删除 `ThemeManager`，并处理 `PCLStubs.Theme`（属既有文件，需单独评审）。

## 六、接线状态

**本轮 0 处接线**。`DefaultThemeService` / `AppSettingsThemeRepository` 未改动。
逐一核对全部强调色读取点后，确认当前不存在「行为完全一致」的接线点：

| 目标 | 调用点 | 状态 |
| --- | --- | --- |
| 订阅式读取（允许范围内） | `Features/ModBrowser/CategoryContentView.swift:240 / 293`、`ContentCard.swift:51 / 56`、`CategoryCanvasPlaceholder.swift:18`、`ModDetailView.swift:202`、`Settings/ColorPickerView.swift:27 / 63 / 95` | 未接线：全部是 `@ObservedObject var theme: ThemeManager` 在 View body 内的订阅式读取；`ThemeService.currentTheme()` 是 `async` 一次性取值，接过去会丢掉订阅与同帧更新语义 |
| 订阅式读取（范围外） | `Features/Game/**`、`Features/Java/JavaPickerView.swift`、`Features/Launch/LaunchButton.swift` 等 | 未接线：调用点不在本轮允许修改范围 |
| 非订阅读取 | `UI/Shell/RootOverlays.swift:75 / 78`、`Features/Download/DownloadDetailView.swift:84 / 116 / 172` | 未接线：分别落在 `qwq/UI/**`、`qwq/Features/Download/**`，均不在允许范围 |
| 写入强调色 | `Settings/ColorPickerView.swift:29` `theme.accentColor = color` | 未接线：`ThemeService` 当前只读，无写入方法可承接（写入收窄属设置模块职责） |

额外风险（说明为何不能只改读取点）：`ThemeManager` 与 `AppSettingsStore` 是**两个独立内存副本**，
仅共用 `UserDefaults[UDK.accentColor]` 且归档格式相同（两处都用 `NSKeyedArchiver` 归档 `NSColor`），
各自只在 `init` 读一次、之后互不通知。UI 写入只落在 `ThemeManager`，
而 `AppSettingsThemeRepository.current()` 读的是 `AppSettingsStore`；
在迁移步骤第 1 步（单一数据源）完成前，任何读取点改走门面都可能拿到**过期颜色**。

结论：Theme 的接线前提是先做第 1 步（`ThemeManager` 退化为 `AppSettingsStore` 的转发）
并为 SwiftUI 侧补可观察桥接，否则属行为变化。

## 七、测试挂载点

- `AppSettingsThemeRepository`：注入替身存储或直接改 `AppSettingsStore.shared.accentColor`，
  验证返回值随颜色变化；
- `DefaultThemeService(repository:)`：注入固定仓储，验证门面只转发；
- `ThemeDefinition` 的 `Sendable` / `Hashable` 语义：可放入 `Set`、可跨任务传递。
