# UI 评审文稿（Round 5）— SL启动器 / qwq

> **本轮的正式交付物是 `docs/UI-REVIEW-ROUND5.html`**（自包含、截图 base64 内嵌、可直接转发/离线打开）。
> 本 Markdown 是同批结论的纯文本版，便于 diff；两者结论一致，HTML 版内容更全
> （10 条逐条详情 + 动画专项表 + 不能判定清单 + 截图复现步骤）。

> **本文件只是文稿，不含任何代码改动。** 所有改动建议均为「怎么改」的描述，未落到源码。
>
> 评审依据：Apple《Human Interface Guidelines》官方条文（逐条附官方链接）+ 八大设计原则。
> 截图来源：`docs/ui-review-round5/`（2026-09-23 离屏渲染，**已包含本轮全部代码改动**，25 张）。
> 渲染方式与真实运行有差异，凡截图无法判定的项一律单列在「第五部分」，不混进结论。

---

## 0. 前提假设（按 HIG 流程第 0 步）

| 项 | 取值 | 依据 |
|---|---|---|
| 目标平台 | **macOS** | 截图有侧边栏 + 隐藏标题栏的窗口；工程 `MACOSX_DEPLOYMENT_TARGET = 13.0` |
| 输入形态 | 静态截图 25 张 + 对应源码 | 见文末截图清单 |
| 关注点 | 整体体验 + 控件 + 平台契合度 | 用户要求「对照 HIG 看哪里要改」 |
| **未做的事** | 未做动态行为实测、未做 VoiceOver 实测 | 离屏渲染不触发 `onAppear`；沙箱无屏幕录制与辅助功能权限 |

> 说明：截图是**离屏渲染**产物。本工程多个视图的可见内容依赖 `onAppear` 触发的入场动画（初值 `opacity = 0`），渲染器不触发该回调，故这类视图在截图里是空白。**这类空白一律按「不能判断」处理，不计为缺陷**（第五部分逐条列出）。

---

## 1. 评审结论表（按严重度排序）

| # | 问题 | 违反 | 官方依据 | 改法 | 严重度 |
|---|---|---|---|---|---|
| 1 | **首屏大片空白**：窗口 900×662，左侧玩家卡仅占约 280pt（≈31% 宽），右侧约 65% 是纯背景。内容不随窗口生长。 | macOS 规则 1「用大屏在更少嵌套层级展示更多内容」；原则「简洁」「匠心」 | 「Leverage large displays to present more content in fewer nested levels and with less need for modality, while maintaining a comfortable information density that doesn't make people strain to view the content they want.」<br>— [Designing for macOS](https://developer.apple.com/cn/design/human-interface-guidelines/designing-for-macos) | 首屏改两栏：左栏玩家卡（固定 ≈320pt），右栏放「最近版本 / 快速操作 / 运行状态」三块。窗口拉宽时由右栏吸收宽度。 | **P1** |
| 2 | **顶层导航是自绘「顶部标签条」**（启动/游戏/下载/联机/赞助/个性化 一行六项），窗口内没有任何边栏。 | 原则「熟悉感」；macOS 规则 3 | tab bars 适用平台为 iOS / iPadOS / tvOS / visionOS；macOS 顶层导航的官方形态是边栏（sidebars 页含 macOS 专条：「Avoid hiding the sidebar by default to ensure that it remains discoverable.」）<br>— [Sidebars](https://developer.apple.com/cn/design/human-interface-guidelines/sidebars) | 六个一级入口改为 `NavigationSplitView` 边栏（macOS 惯用 180–240pt 列宽），默认选中「启动」。可一并获得平台惯用的显示/隐藏边栏能力。 | **P1** |
| 3 | **没有「偏好设置」入口**：全库 grep `.commands` / `CommandGroup` / `keyboardShortcut` / `Settings {` **命中 0**。「个性化」（选强调色）只是第七个顶部标签。 | macOS 规则 3（严重度**高**）、规则 6 | 「Use the menu bar to give people easy access to all the commands they need to do things in your app.」<br>— [Designing for macOS](https://developer.apple.com/cn/design/human-interface-guidelines/designing-for-macos) | 增加 `Settings` 场景承载「个性化」，系统会自动在 App 菜单生成「设置… ⌘,」；并把「个性化」从一级导航移出。 | **P1** |
| 4 | **加载态是整屏空白 + 一句居中文字**（`游戏检索中.`），没有任何骨架/轮廓。 | HIG Loading 规则（严重度：中） | 「If you make people wait for loading to complete before displaying anything, they can interpret the lack of content as a problem with your app or game. Instead, consider showing placeholder text, graphics, or animations as content loads, replacing these elements as content becomes available.」判定方法：「加载期间截图，若为一整块空白/纯 spinner 而没有任何占位骨架或内容轮廓，即违反。」<br>— [Loading](https://developer.apple.com/cn/design/human-interface-guidelines/loading) | 用与结果同形的骨架卡片（3 列 × 2 行灰色占位块）填满同一网格位置，顶部保留搜索框。另：状态短语末尾的句号 `。` 去掉（不是完整句子）。 | **P1** |
| 5 | **强调色网格 7+1 断行**：8 个色块排成 7 个一行 + 第二行仅「灰色」一个孤立格。 | 原则「匠心」「简洁」 | HIG 未规定网格列数（此项**无官方硬规则**，按原则层判断） | 固定 4 列 × 2 行，或把色数补到 8 的整数倍（如加「青色」）。 | **P2** |
| 6 | **下载页版本卡片信息密度过低**：3 列卡片，每张只有「版本号 + 正式版」两行。 | macOS 规则 1 | 同第 1 条依据 | 卡片补发布日期 / 是否已安装 / 加载器支持标记；或改紧凑列表（一行一版本 + 右侧操作）。 | **P2** |
| 7 | **顶部导航图标为线性描边变体**。 | tab bars 规则「优先用填充符号」（严重度：中） | 「Consider using SF Symbols to provide familiar, scalable tab bar icons. … Prefer filled symbols or icons for consistency with the platform.」<br>— [Tab bars](https://developer.apple.com/cn/design/human-interface-guidelines/tab-bars) | 选中项用 filled 变体（如 `paintpalette.fill`），未选中保留描边。**若采纳第 2 条改边栏，本项自动消解。** | **P2** |

**已符合 HIG、不需要改的要点**（避免只报问题）：

- **选中态不只靠颜色**：个性化页每个色块下方都有文字标签（蓝色/紫色/…），选中项除填充色外加了白色描边环。符合「不得仅靠颜色传达信息」。
- **搜索框有描述性占位文字**（`搜索正式版...`），符合 search fields 的「Use placeholder text to help people know what they can search for.」
- **窗口有系统红绿灯控件、可缩放、可全屏**：`qwqApp.swift` 用 `.frame(minWidth: 800, minHeight: 590)` + `.defaultSize(900×660)`，未锁死尺寸，符合 macOS 规则 2。
- **失败提示的停留时长按语义分级**：任务状态 1.5s、失败提示 6s（`RootOverlays.mistakePillDuration`），与 HIG Feedback 的「反馈强度匹配事件重要性」一致。

---

## 2. 动画与动效专项（用户明确要求「看动画效果怎么样」）

**先说清一件事**：截图表现不了动画。本工程多个入场动画把 `opacity` 初值设为 0、由 `onAppear` 里的 `withAnimation` 拉到 1，而离屏渲染器**不触发 `onAppear`**——所以药丸、通知横幅这类视图在截图里是**全白**的。因此下面只给「代码在做什么」的结论，实际观感需要录屏确认（我没有屏幕录制权限，见第五部分）。

| 动效 | 代码位置 | 曲线 / 时序 | 评估 |
|---|---|---|---|
| 任务药丸入场 | `qwq/UI/TaskPill.swift:86` | `withAnimation(.exaggeratedSpring)`，延迟一个渲染事务（`DispatchQueue.main.async` 包一层） | 合理。延迟到事务外是必要的，同步写 `@State` 会触发 "Modifying state during view update"。 |
| 任务药丸退场 | `TaskPill.swift:105-113` | `.explosiveSpring` 淡出+缩小 → 停 300ms → 把 `isPresented` 写回 false | 合理。且已从 `DispatchQueue.main.asyncAfter`（**不可取消**）改为 `.task`（随视图消失自动取消）。 |
| 药丸「换消息」重建 | `TaskPill.swift:47` `.id(message)` | 以正文作视图身份 | **本轮修掉的真缺陷**：此前正文变化而开关恒为 true，前后两棵子树被判为「同一视图更新」→ `onAppear` 不再触发、停留计时不重排。后果是同一通道在停留期内再来一条消息，**第二条只显示「第一条剩余的时间」**，极端情况下只闪零点几秒就消失——恰好抵消了 6s 的失败提示时长。 |
| 侧边栏子项淡入 | `qwq/Features/Game/GameSidebarView.swift`（`subItemOpacity`，延迟 0.3s） | 延迟淡入 | 合理，但**截图看不到**（属第五部分）。 |
| 顺序观察 | — | 入场的 `async` 包一层、退场用可取消 `.task` | 两者方向一致；未见互斥或竞态。 |

**动效层面没有发现需要改的点**——现有曲线选择（弹性入场 / 快速退出）与 HIG「反馈强度匹配事件重要性」是一致的。若要进一步打磨，唯一建议是：药丸入场的弹性幅度（`exaggeratedSpring`）偏大，对「下载开始」这类高频低重要事件可能显得吵；建议按级别分级（低重要用常规 spring，失败才用夸张曲线）。此项**待录屏确认后再定**。

---

## 3. 与代码的对照（每条结论的可核验位置）

| 结论 | 代码位置 | 关键事实 |
|---|---|---|
| 无菜单栏命令 | 全库检索 `.commands` / `CommandGroup` / `keyboardShortcut` / `Settings {` | 命中 **0**；`qwqApp.swift` 只有 `WindowGroup` + `.windowStyle(.hiddenTitleBar)` + `.defaultSize` |
| 窗口可缩放但内容不自适应 | `qwq/App/qwqApp.swift:26` `.frame(minWidth: 800, minHeight: 590)`；`.defaultSize(width: 900, height: 660)` | 尺寸约束只有下限与默认值，**没有任何把多余宽度分配给内容的布局**（无 `NavigationSplitView`、无弹性列） |
| 无窗口尺寸的重复声明 | `qwq/App/AppDelegate.swift:9`、`qwq/UI/Modifiers/LauncherWindowModifier.swift:28` | 两处都明确注释「不在此处声明 `window.minSize`」，唯一来源是根视图约束。按 `NSWindow.contentMinSize` 官方语义，该做法正确。 |
| 加载态只有文字 | `qwq/Features/Game/GameViews.swift`（`asyncFullDiskScanForGames` 驱动的检索）+ 其结果为空时的分支 | 加载期间渲染的就是一行状态文字，无骨架视图 |
| 药丸的两处时长 | `qwq/UI/Shell/RootOverlays.swift`（`mistakePillDuration` / 默认 1.5s）；`TaskPill.swift:30` `var duration: TimeInterval = 1.5` | 两个入口共用同一组件，仅时长不同——设计意图清楚 |

---

## 4. 优先级说明（HIG 流程第 5 步）

规则库的「严重度：高」**不自动等于 P0**。P0 的界定是「上架合规风险 / 数据隐私安全 / 无障碍阻断 / 用户丢数据」——本次评审**没有任何一条落进 P0**。

- 第 3 条引用的官方规则严重度是「高」（macOS 规则 3），但它不涉及合规、隐私或数据安全，因此按换算规则落 **P1**。
- 其余 P1 来自「明显不像原生 / 常见场景走不通」。
- P2 为打磨项。

---

## 5. 不能判断的部分（**这一步不能省**）

### 5.1 截图里是空白，但**不是**缺陷的（离屏渲染假象）

| 截图 | 空白原因 | 结论 |
|---|---|---|
| `06-pill-task.png`、`06-pill-error.png` | `TaskPillContent` 的 `opacity` 初值 0，靠 `onAppear` 的 `withAnimation` 拉到 1；渲染器不触发 `onAppear` | **不能判断外观**；不是「药丸不显示」 |
| `07-notice-1info.png`、`07-notice-2success.png` | 同上（通知横幅同款入场动画） | 同上 |
| `01-window-02-下载.png` 里「游戏」下方那块**空蓝色高亮块** | `GameSidebarView` 的 `subItemOpacity` 初始全 0，延迟 0.3s 淡入 | **不是**「子项没渲染出来」。子项（正式版/快照/远古版）在真实运行时会出现。 |
| `01-window-01-游戏.png` 整屏只有「游戏检索中.」 | 该页内容由异步全盘扫描完成后填充，渲染器不等异步 | 只能评**加载态本身**（已列为第 4 条），不能评结果态 |

### 5.2 必须真机/录屏才能判定的

1. **所有转场与动画的实际观感**——页面切换是否有转场、药丸弹性幅度是否过吵、侧边栏子项淡入是否拖沓。**需要录屏**（我没有屏幕录制权限，`screencapture` 在无权限时只吐桌面壁纸）。给我一段录屏或你自己看一眼，我可以据此再出第二轮动效结论。
2. **VoiceOver 朗读顺序与可达性**——顶部六项导航是否可用键盘 Tab 到达、朗读顺序是否合理。需要真机 + Accessibility Inspector。
3. **实际对比度数值**——深色背景下灰色小字（如「将用于分类高亮和按钮」「正式版」）是否达到 4.5:1。截图上目测偏灰，但**目测不算证据**，需用 Accessibility Inspector 取样。这是**潜在 P0/P1**，一旦实测低于门槛即升级。
4. **系统强调色改动后的表现**——用户改 macOS 系统强调色时，边栏图标与选中态是否跟随。需要真机改一次系统设置。
5. **窗口尺寸连续变化时的布局**——把窗口从 800 拉到 1600 宽，右侧空白比例如何变化。需要真实交互。

### 5.3 规则库未覆盖、按通用设计判断的（已标注，不冒充官方依据）

- 强调色网格的列数（第 5 条）：HIG 无网格列数硬规则。
- 「右侧 65% 空白」的**具体**改法（放什么内容进右栏）：官方只有「用大屏展示更多内容」的原则，没有「首屏该放哪几块」的规定。

---

## 6. 附：截图清单（`docs/ui-review-round5/`，25 张，均为当前代码渲染）

| 文件 | 页面 |
|---|---|
| `00-window-launch-page.png` | 启动页（整窗） |
| `01-window-00-启动.png` … `01-window-05-个性化.png` | 六个一级页面 |
| `02-window-download-detail.png` | 下载详情 |
| `03-java-picker.png` | Java 选择 |
| `04-launch-button-1idle.png` … `-6disabled.png` | 启动按钮六态 |
| `05-close-button-hidden/launching/running.png` | 关闭按钮三态 |
| `06-pill-task.png` / `06-pill-error.png` | 任务药丸（见 5.1，渲染空白） |
| `07-notice-1info` … `4error.png` | 顶部通知四级（见 5.1） |
| `08-overlay-drop-highlight.png` | 拖放高亮 |

本文件共覆盖 **7 条可判定问题**（4×P1 + 3×P2），**0 条 P0**；另有 **5 类**必须真机才能判定的事项已单列。
