# Skin 模块

皮肤能力的**目标结构**。当前阶段只做「建立结构」：
仅新增文件，未修改 / 删除任何既有文件，未接线，行为零变化。

## 一、现状

`qwq/Features/Skin/` 现有 6 个文件，皮肤有**两条应用路径**并存：

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `MinecraftSkinManager.swift` | 41 | 皮肤文件持久化（`~/Library/Application Support/SL启动器/Skins/<uuid>.png`） |
| `SkinResourcePackApplier.swift` | 156 | 离线皮肤主路径：生成 `resourcepacks/SL 皮肤.zip` + 注入 options.txt |
| `SkinAvatarCropper.swift` | 86 | 尺寸校验与头像裁剪（64×64 / 64×32 / 128×128） |
| `SkinExtractor.swift` | 72 | 从游戏版本 JAR 提取默认皮肤 |
| `OfflineSkinService.swift` | 192 | 交互入口：选择面板、默认皮肤恢复（依赖 `LauncherSettings` 单例） |
| `OfflineUsernameValidator.swift` | 22 | 离线用户名提示文案 |

注：历史遗留的 authlib-injector / JAR 改写路径已在前序批次删除，注释保留在
`MinecraftSkinManager.swift` 头部，离线皮肤统一走资源包方案。

## 二、文件与职责

| 文件 | 内容 | 说明 |
| --- | --- | --- |
| `SkinDecoder.swift` | `SkinError`、`SkinImageInfo`、`SkinDecoder`、`DefaultSkinDecoder` | 图像解码与尺寸校验，基于 ImageIO，可任意线程调用 |
| `SkinResourcePackBuilder.swift` | `SkinResourcePackBuilder`、`DefaultSkinResourcePackBuilder` | 资源包构建协议 + `SkinResourcePackApplier` 的适配实现 |
| `SkinService.swift` | `SkinService`、`DefaultSkinService` | 对外唯一门面：校验 / 落盘 / 读取 / 资源包 |
| `SkinModule.swift` | `SkinModule` | `SLModule` 实现，注册 `skin.service` 与 `skin.decoder` |

依赖方向：`SkinService` → （`SkinDecoder` / `SkinResourcePackBuilder`）→ 既有实现。

## 三、协议与既有实现的对应关系

| 协议方法 | 既有实现 | 行为差异 |
| --- | --- | --- |
| `SkinDecoder.inspect(_:)` | `SkinAvatarCropper.validateSkin(at:)` | 尺寸白名单相同；改为 `CGImageSource` 直读像素尺寸，不经 `NSImage`，因此可脱离主线程调用 |
| `SkinService.saveSkin` / `skinData` | `MinecraftSkinManager.saveSkin` / `getSkinData` | 无 |
| `SkinService.applyResourcePack` / `removeResourcePack` | `SkinResourcePackApplier.apply` / `remove` | 无；幂等判断仍依赖 `LauncherSettings.appliedSkinHash`，故适配层传入 `LauncherSettings.shared` |

## 四、刻意没有纳入协议的东西

- **交互**：`OfflineSkinService.selectSkinImage` 里的 `NSOpenPanel` / `NSAlert` / 放文件位置，
  属 UI 职责，模块只覆盖「校验 → 落盘 → 资源包」三步数据操作。
- **用户名提示**：`OfflineUsernameValidator.hint(for:)` 是纯展示文案，与皮肤数据无关。
- **从 JAR 提取默认皮肤**：`SkinExtractor.extractFromGameJar` 依赖 `AppContext.processPool` 与游戏目录结构，
  接入前需要先确定「提取结果归属哪个模块」（皮肤本体还是资源补全），本轮不纳入。
- **`LauncherSettings` 的收窄**：资源包幂等标记目前写在 `LauncherSettings`，属设置模块职责；
  迁到 `AppSettingsStore` 后再去掉适配层对 `LauncherSettings.shared` 的依赖
  （**`AppSettingsStore.swift` 本轮不允许修改**）。

## 五、迁移步骤（后续执行，当前未做任何改动）

**第 1 步：头像与展示改走解码器**
`CategoryContentView` 等处的皮肤尺寸校验改调 `SkinDecoder`。
验收：非法尺寸的提示文案与现状一致（与 `LauncherError.skinValidationFailed` 的文案对齐）。

**第 2 步：皮肤应用改走门面**
`OfflineSkinService.selectSkinImage` 中的保存 + 资源包生成两步改为调用 `SkinService`，
面板与弹窗留在 UI 层。
验收：`resourcepacks/SL 皮肤.zip` 内容、options.txt 的 resourcePacks 取值、
`appliedSkinHash` 幂等行为与现状一致。

**第 3 步：把 `SkinModule` 登记进模块清单**
`ModuleRegistry.swift` 的 `AppModuleBootstrap.makeRegistry()` 中加入 `SkinModule()`
（**该文件本轮不允许修改，故此项留待接线时执行**）。
验收：`context.require(ModuleCapabilityKey<SkinService>("skin.service"))` 可取到实例。

**第 4 步：幂等标记迁移**
`appliedSkinHash` 从 `LauncherSettings` 迁至 `AppSettingsStore`，适配层去掉 `LauncherSettings` 依赖。

## 六、接线状态

已接线 4 处（皮肤读取 3、皮肤落盘 1）。`DefaultSkinService` / `DefaultSkinDecoder` /
`DefaultSkinResourcePackBuilder` 均未改动，仍为既有实现的原样适配。

| 目标 | 调用点 | 状态 |
| --- | --- | --- |
| 皮肤读取 | `Features/ModBrowser/CategoryContentView.swift:189 / 211`、`Features/Skin/OfflineSkinService.swift:111` | **已接线**：`MinecraftSkinManager.shared.getSkinData(forUUID:)` → `DefaultSkinService().skinData(forUUID:)`（同步、返回 `Data?`，适配器直接委托同一实现） |
| 皮肤落盘 | `Features/Skin/OfflineSkinService.swift:67` | **已接线**：`MinecraftSkinManager.shared.saveSkin(_:forUUID:)` → `DefaultSkinService().saveSkin(from:forUUID:)`（同步、抛错原样透传） |
| 尺寸校验 | `Features/Skin/OfflineSkinService.swift:51` | 未接线：**错误类型与文案都会变**。既有抛 `LauncherError.skinValidationFailed`（展示为「皮肤无效: 不支持的尺寸: 64×63」），服务侧 `inspectSkin(at:)` 抛 `SkinError.unsupportedDimensions`（「不支持的皮肤尺寸：64×63」）；该错误经 `error.localizedDescription` 直接进 `NSAlert`，属可见行为变化 |
| 资源包生成（选择皮肤） | `Features/Skin/OfflineSkinService.swift:76` | 未接线：既有调用为**同步**；`SkinService.applyResourcePack` 为 `async` 且把错误包成 `SkinError.resourcePackFailed`，既引入异步边界（需 `Task` 包裹，改变时序与取消语义）又改变错误类型 |
| 资源包生成（启动链路） | `Features/Launch/LaunchCoordinator.swift:186` | 未接线：调用点在 `qwq/Features/Launch/**`，本轮不允许修改 |
| 从 JAR 提取默认皮肤 | `Features/Skin/OfflineSkinService.swift:128 / 163`、`Features/ModBrowser/CategoryContentView.swift:217` | 未接线：`SkinExtractor` 未纳入协议（第一节已说明），本轮不扩协议 |

其余 `MinecraftSkinManager.shared` 引用只剩 `Skin/Module/SkinService.swift`（适配器自身），
`ModBrowser`、`Skin` 两目录的 UI 侧已无直接调用。

**顺带发现的缺陷（本阶段只记录，不修改）**：`OfflineSkinService.selectSkinImage` 把**游戏根目录**
当作 `gameDir` 传给 `SkinResourcePackApplier.apply`（第 69–71 行），而 `LaunchCoordinator.swift:173-186`
的注释已明确指出「实际游戏运行目录是 `gameRoot/versions/<版本>`，写到这里游戏读不到（潜伏错误）」
并修正了自身调用点。后果有两条：

1. `apply` 内 `packPackVersion(for: gameDir + "/<version>.jar")` 指向 `<gameRoot>/<version>.jar`，
   该路径不存在（jar 实际在 `<gameRoot>/versions/<version>/<version>.jar`，见
   `MinecraftInstance.swift:409`、`MinecraftInstaller.swift:151`），故 `pack_version` 恒为 nil、
   回落 `pack_format 1`；
2. `appliedSkinHash` 按 `pack_<version>_<皮肤 sha1>` 计算，与 `LaunchCoordinator` 口径相同；
   若用户所选皮肤原图与 `selected_skin.png` 字节一致（`saveSkinImage` 为原样复制），
   启动链路的 `apply` 会因 hash 命中而跳过，资源包最终不会写入版本目录。

## 七、测试挂载点

- `DefaultSkinDecoder.inspect`：64×64 / 64×32 / 128×128 通过，其余尺寸抛
  `SkinError.unsupportedDimensions`，非图像数据抛 `SkinError.unreadableImage`；
- `SkinImageInfo.isLegacyFormat`：仅 64×32 为 true；
- `DefaultSkinService(decoder:packBuilder:)`：注入桩实现，验证门面只做转发、不吞错误；
- `DefaultSkinResourcePackBuilder.packURL(in:)`：路径为 `<gameDir>/resourcepacks/SL 皮肤.zip`。
