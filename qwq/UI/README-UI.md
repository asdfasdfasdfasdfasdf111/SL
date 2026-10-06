# UI 模块

界面层收口。**只放「跨页面复用」的视图与效果**；某个分类页专属的视图留在
`Features/<模块>/`（例如游戏页的 `VersionPickerCard`）。

## 目录职责

| 目录 | 放什么 | 例子 |
|---|---|---|
| `Shell/` | 外壳与页面骨架：顶栏、弹窗骨架、根级覆盖层 | `HomeHeader`、`PopupCardScaffold`、`RootOverlays` |
| `Components/` | 通用控件：按钮、卡片、标签、布局容器 | `ViewComponents`、`VersionButton`、`TaskPill`、`FlowLayout` |
| `Effects/` | 视觉/交互效果：动画曲线、背景、滚动辅助 | `AnimationExtensions`、`LaunchBackground`、`ScrollBounceModifier`、`HorizontalScrollCatcher` |
| `Notices/` | 提示通道（横幅/浮层） | `NoticeOverlay` |
| `Modifiers/` | 窗口级修饰器 | `LauncherWindowModifier` |

## 玻璃约定（重要，勿各自为政）

**全应用不使用深色材质做玻璃。** 统一为：

```swift
.fill(Color.white.opacity(0.05 ... 0.12))   // 极淡白，能看出边界即可
.overlay(shape.stroke(.white.opacity(0.08), lineWidth: 0.5))  // 细高光边
.shadow(color: .black.opacity(0.2 ~ 0.35), radius: 10~14, y: 3~6)  // 层次
```

原因（都踩过）：
1. **深色材质在深色模式下会把面板压成暗块**，压在渐变背景上显得"黑不溜秋"，
   用户定稿要求「所有毛玻璃都要透明，能看出来就行」。
2. **SwiftUI 的 `.ultraThinMaterial` / `.regularMaterial` 默认跟随窗口激活状态**
   （`followsWindowActiveState`），窗口被切到后台会切到「非活跃」外观而**发黑**；
   系统组件不会这样。纯色填充没有这个问题。
3. 少数必须"真模糊"的位置才用 `BlurView`（`NSVisualEffectView`，`state` 恒为 `.active`）。

## 约束

- 部署目标 **macOS 13.0**：不可使用 macOS 26 的 Liquid Glass API（`.glassEffect` 等）。
- 窗口为**锁定尺寸**（800×560，`windowResizability(.contentSize)`），
  布局按此尺寸校对即可；不要再写"随窗口无限缩放"的假设。
- 加载器图标（`Assets.xcassets/Loader*`）统一为「白色 + 亮度作透光率」的单色图，
  **保持原始长宽比**（FORGE 是 188×32 的宽字标，补成正方形会让它缩得极小）。
