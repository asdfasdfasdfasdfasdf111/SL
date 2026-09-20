# Apple 框架 API 核对手册（Swim111Launcher）

> 用途：在 `xcodebuild` 被沙箱拦截、无法真正编译验证的前提下，把项目实际用到的 **SwiftUI / AppKit / Foundation 框架 API** 逐条对照 Apple 官方文档核对，形成可查证的手册，供后续写代码时逐条查证。
>
> 范围：**只核对框架 API 语义层**（SwiftUI 状态与生命周期、修饰器与动画语义、AppKit 窗口与归档、Foundation 进程/管道/网络/文件/派发源）。**不核对语言层与并发层**——那部分由 `docs/SWIFT_LANGUAGE_CHECKLIST.md` 负责，本手册与它的重叠处只做交叉引用，不重复结论。
>
> 约束：本手册**只读**项目源码，未修改 `qwq/` 下任何文件；未执行任何 git 写操作。所有结论均附官方文档链接；凡查不到官方依据的，明确标注「未找到官方依据，存疑」，不臆测。

---

## 0. 环境与核验方法（可复现）

| 项 | 值 | 来源 |
|---|---|---|
| SDK | MacOSX.sdk（Xcode 26，含 macOS 26 SDK） | 同事手册 §0 已实测 |
| `SWIFT_VERSION` | `5.0` | `qwq.xcodeproj/project.pbxproj` |
| `MACOSX_DEPLOYMENT_TARGET` | **`13.0`** | `qwq.xcodeproj/project.pbxproj:268,297` |
| App Sandbox | **`ENABLE_APP_SANDBOX = NO`** | `qwq.xcodeproj/project.pbxproj:262,291` |
| 依赖 | SwiftyJSON 5.0.2、ZIPFoundation 0.9.20 | `Package.resolved` |

部署目标为 13.0 这一条对多个结论有决定性影响（尤其 §2.1 的 `#unavailable(macOS 13.0)` 死分支、§1.5 的 `.onChange` 弃用告警、`.defaultSize` 的可用性）。

**核对方法**：逐个 API 用 WebFetch 抓取 `developer.apple.com/documentation/` 官方页面，摘录官方原文关键句 → 在项目中定位实际调用点（`文件:行号`）→ 比对语义 → 给出「正确 / 有风险 / 错误 / 存疑」结论。抓取不到的页面（JS 动态渲染）在本手册 §5 单列，不编造结论。

**结论分级定义**

| 结论 | 含义 |
|---|---|
| 正确 | 与官方文档语义一致，无兼容性风险 |
| 有风险 | 当前能跑，但依赖未文档化行为、使用已弃用 API、或写法与官方明确建议相悖 |
| 错误 | 与官方明文规则冲突，或行为与代码/注释声称的不一致 |
| 存疑 | 未找到官方依据，或官方页面正文不可抓取；只记录，不下断言 |

---

## 1. 逐条核对表

### 1.1 SwiftUI 状态管理

| # | API | 官方规则要点（原文关键句） | 项目中位置 | 结论 | 备注 / 改法 |
|---|---|---|---|---|---|
| S1 | `@StateObject` | "SwiftUI creates a new instance of the model object only once during the lifetime of the container that declares the state object. For example, SwiftUI doesn't create a new instance if a view's inputs change, but does create a new instance if the identity of a view changes." | `App/ContentView.swift:6`（7 处使用） | 正确 | 语义无问题。若要「输入变了就重建」，官方唯一手段是改 view identity（`.id(_:)`）。<br>链接：https://developer.apple.com/documentation/swiftui/stateobject |
| S2 | `@StateObject` 的 autoclosure | "SwiftUI runs the autoclosure that you provide to the state object's initializer only the first time you call the state object's initializer, so the model's stored `name` value doesn't change." / "Use caution when doing this… it might result in unexpected behavior or unwanted side effects if you explicitly initialize the state object." | `App/ContentView.swift:6`（直接给初值，未在 `init` 里重赋值） | 正确 | 官方 `init` 写法是 `_model = StateObject(wrappedValue: …)`。本项目没有在 `init` 里重建 StateObject，**未踩**「在 init 里重新创建导致被丢弃」的坑。但 `_settings = StateObject(wrappedValue: LauncherSettings.shared)` 若未来出现，应知：autoclosure 只执行一次，且**惰性对象每次视图 init 时都会被构造**（见 S7）。 |
| S3 | `@ObservedObject` 初值 | "**Don't specify a default or initial value for the observed object.** Use the attribute only for a property that acts as an input for a view, as in the above example." | **35 处**形如 `@ObservedObject var theme = ThemeManager.shared`（其中 `ThemeManager.shared` 27 处；`UI/ViewComponents.swift:108,136`、`UI/Notices/NoticeOverlay.swift:6,38,126`、`App/ContentView.swift:16`、`Features/Game/GameCards.swift:15,72,140,186` 等） | 有风险（低） | 官方明文不建议给初值。因为这些对象都是**永不释放的单例**，运行行为正确；风险在「未来有人把单例改成可释放对象」时会静默失效（视图持旧引用不更新）。更贴合官方的写法见 §2.8。<br>链接：https://developer.apple.com/documentation/swiftui/observedobject |
| S4 | `@ObservedObject` 生命周期 | "SwiftUI updates any view that depends on the object…"；官方要求对象由 `@StateObject` 或上层持有（"You typically do this to pass a `StateObject` into a subview"）。对象若无人持有而被释放，视图不会再收到更新 | `App/ContentView.swift:16`（`LaunchPanelState.shared`）；`UI/Notices/NoticeOverlay.swift:6`（`NoticeCenter.shared`） | 正确 | 由 `static let shared` 永久持有，不触发「生命周期不由视图持有导致失效」的场景。 |
| S5 | `@EnvironmentObject` | "If you declare a property as an environment object, be sure to set a corresponding model object on an ancestor view by calling its `environmentObject(_:)` modifier." | 读取方 5 处：`Features/Game/GameViews.swift:12`、`GameCategoryView.swift:14`、`VersionPickerCard.swift:21`、`ModBrowser/CategoryContentView.swift:9`、`Java/JavaPickerView.swift:52`；注入方 `App/ContentView.swift:39` | 正确 | 注入点 `ContentView.swift:39` 的 `.environmentObject(settings)` 位于根 `ZStack`（含 `RootOverlays`）之后，整棵子树都能取到。`VersionPickerCard.swift:82` 再次 `.environmentObject(settings)` 属重复注入，无害。<br>链接：https://developer.apple.com/documentation/swiftui/environmentobject |
| S6 | `@Environment(\.colorScheme)` | 环境值读取，无生命周期语义 | `Features/Settings/ColorPickerView.swift:59` | 正确 | — |
| S7 | `@State` 与引用类型 | "It's possible to store an object that conforms to the `ObservableObject` protocol in a `State` property. **However the view will only update when the reference to the object changes** … The view will not update if any of the object's published properties change. To track changes to both the reference and the object's published properties, use `StateObject` instead." / "A `State` property always instantiates its default value when SwiftUI instantiates the view… avoid side effects and performance-intensive work when initializing the default value." | 项目未用 `@State` 存 `ObservableObject`（正确规避） | 正确 | 链接：https://developer.apple.com/documentation/swiftui/state |
| S8 | `@Observable`（Observation 宏） | "To fully adopt Observation, replace the use of `StateObject` with `State()` after updating your data model type." / "Don't wrap objects conforming to the `Observable` protocol with `@ObservedObject`… Attempting to wrap an `Observable` object with `@ObservedObject` may cause a compiler error." / 绑定需 `@Bindable` | 项目**未采用** `@Observable`（全库 0 处），全部沿用 `ObservableObject` | 正确但落后 | 混合两种体系是官方允许的（"You don't need to make a wholesale replacement… You can make changes incrementally"），但同一类型不可混用。若后续迁移，`@ObservedObject` 必须同步去掉。<br>链接：https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro |
| S9 | `@Published` + `didSet` 落盘 | 官方 `@Published` 文档未禁止 `didSet`；注意 Swift 初始化期间属性观察器不触发 | `Features/Settings/AppSettingsStore.swift:18-68`（12 个 `@Published` 全部挂 `didSet` 写 `UserDefaults`）；`AppSettingsStore.init()` 内对初始值手工补写 `UserDefaults` | 正确 | 初始值绕过 `didSet` 是 Swift 语言语义（属同事手册范围），代码已用「init 内手工补写」正确处理。<br>链接：https://developer.apple.com/documentation/combine/published |
| S10 | 跨对象状态透传 | 官方 `objectWillChange` / `ObservableObject` 语义 | `App/ViewModels/NavigationState.swift:78-80`、`App/ViewModels/LaunchPanelState.swift:28-30` 用 `objectWillChange.sink` 手动转发 | 正确 | 转发后订阅方的更新时机正确（`sink` 收到的是 willChange 前置信号）。<br>链接：https://developer.apple.com/documentation/combine/observableobject |

### 1.2 App / Scene 生命周期与“谁是入口”

| # | API | 官方规则要点（原文关键句） | 项目中位置 | 结论 | 备注 / 改法 |
|---|---|---|---|---|---|
| A1 | `@main` 唯一性 | "Precede the structure's declaration with the `@main` attribute… **You can have exactly one entry point among all of your app's files.**" | `App/qwqApp.swift:3`（唯一 `@main`） | 正确 | 全库仅 1 处 `@main`。若未来加第二个入口会直接编译失败。<br>链接：https://developer.apple.com/documentation/swiftui/app |
| A2 | `NSApplicationDelegateAdaptor` | "SwiftUI instantiates the delegate and calls the delegate's methods in response to life cycle events. **Define the delegate adaptor only in your `App` declaration, and only once for a given app. If you declare it more than once, SwiftUI generates a runtime error.**" | `App/qwqApp.swift:5`（唯一一处） | 正确 | 链接：https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor |
| A3 | SwiftUI App 与 AppDelegate 混用 | 官方明确**不推荐**："Manage an app's life cycle events without using an app delegate whenever possible. For example, prefer to handle changes in `ScenePhase` instead of relying on delegate callbacks, like `applicationDidFinishLaunching(_:)`." | `App/AppDelegate.swift:5-34` 用 `applicationDidFinishLaunching` 配置窗口 | 有风险（低） | 官方是「尽量不用」而非禁止；但由此产生两条具体风险：① 依赖 `NSApp.windows` 的时序（§2.2）；② 与视图层 `onAppear` 重复写同一属性（§2.3）。<br>链接：https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor |
| A4 | `applicationDidFinishLaunching(_:)` 时机 | "Tells the delegate that the app's initialization is complete but it hasn't received its first event."（`@MainActor`） | `App/AppDelegate.swift:5` | 正确 | 该方法在首个事件之前、主线程执行；在其中做窗口外观设置是合法的。但**官方未承诺此刻 `NSApp.windows` 已包含 SwiftUI 创建的主窗口**（见 §5）。<br>链接：https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationdidfinishlaunching(_:) |
| A5 | SwiftUI 创建窗口的时机 vs `onAppear` | `onAppear`："The exact moment that SwiftUI calls this method depends on the specific view type that you apply it to, but the `action` closure completes before the first rendered frame appears." | `UI/Modifiers/LauncherWindowModifier.swift:21-26` 在 `onAppear` 写窗口属性 | 正确（但有重复写入风险） | `onAppear` 必然在首帧前完成，因此写窗口属性「来得及」。它与 `applicationDidFinishLaunching` 的先后**官方未定义**；本项目注释在 `LauncherWindowModifier.swift:8-10` 断言「onAppear 在 didFinishLaunching 之后」，属工程实测结论，官方无依据 → 见 §5。<br>链接：https://developer.apple.com/documentation/swiftui/view/onappear(perform:) |
| A6 | `WindowGroup` + `.windowStyle(.hiddenTitleBar)` | "A window style which hides both the window's title and the backing of the titlebar area, allowing more of the window's content to show."（macOS 11.0+） | `App/qwqApp.swift:19` | 正确 | 与 AppKit 侧 `titlebarAppearsTransparent` + `.fullSizeContentView` 的组合语义一致（见 K3）。<br>链接：https://developer.apple.com/documentation/swiftui/windowstyle/hiddentitlebar |
| A7 | `Scene.defaultSize(width:height:)` | 页面正文为 JS 渲染，**本次未能抓取到正文** | `App/qwqApp.swift` —— **未使用**（注释声称「macOS 13+ 由 qwqApp 里的 `.defaultSizeCompat` 声明」，但全库 grep 无 `.defaultSize` / `.defaultSizeCompat`） | **错误（代码与注释不符）** | 该修饰器在 macOS 13.0+ 可用（部署目标即 13.0，可直接使用），但项目从未声明它 → 默认窗口尺寸 900×660 实际未生效，详见 §2.1、§3。<br>链接：https://developer.apple.com/documentation/swiftui/scene/defaultsize(width:height:) |
| A8 | `.windowResizability(_:)` | "The value that you specify indicates the strategy the system uses to place **minimum and maximum size restrictions** on windows that it creates from that scene." / "The default value for all scenes if you don't apply the modifier is `automatic`. With that strategy, `Settings` windows use the `contentSize` strategy, while **all others use `contentMinSize`**."（macOS 13.0+） | `App/qwqApp.swift` 未显式设置 → 取默认 `.automatic` | 正确（但需知其后果） | 这是「根视图 `.frame(minWidth:minHeight:)` 会影响窗口最小尺寸」的**官方依据链**：`WindowGroup` 默认走 `.contentMinSize`，窗口尺寸限制由内容推导。见 §3。<br>链接：https://developer.apple.com/documentation/swiftui/scene/windowresizability(_:)、https://developer.apple.com/documentation/swiftui/windowresizability |

### 1.3 ViewBuilder

| # | API | 官方规则要点（原文关键句） | 项目中位置 | 结论 | 备注 / 改法 |
|---|---|---|---|---|---|
| V1 | `ViewBuilder` 基本语义 | "use `ViewBuilder` as a parameter attribute for view-producing closure parameters, allowing those closures to provide multiple child views." | `App/ContentView.swift:59`（`@ViewBuilder private var mainContent`）、`UI/Shell/RootOverlays.swift:35` | 正确 | 链接：https://developer.apple.com/documentation/swiftui/viewbuilder |
| V2 | `if/else` → `_ConditionalContent` | 官方 Topics 列出 `buildEither(first:)` / `buildEither(second:)`："Produces content for a conditional statement in a multi-statement closure when the condition is true / false." | `UI/Shell/RootOverlays.swift:43,59,73,88`（4 个 `if` 分支）、`App/ContentView.swift:72-77`（`if/else`）、`UI/Notices/NoticeOverlay.swift:10,70,79` | 正确 | `if/else` 编译为 `_ConditionalContent<A,B>`；两侧类型不同也不报错。`switch` 官方**未在当前页面列出**（属 `buildEither` 的组合展开）。 |
| V3 | 单 closure 子视图数量上限 | 官方当前页面只列出 `buildBlock()` 与 `buildBlock(_:)` 两个重载，**未列出历史上 1…10 的重载** | `RootOverlays.body` 的 `ZStack` 内含 5 个平级子视图（`UI/Shell/RootOverlays.swift:36-114`） | 存疑 | 项目未触碰上限（5 < 10），不影响编译。上限制属编译器重载层（历史上为 10），官方当前页面无明文 → 见 §5。 |
| V4 | 类型擦除代价 | 官方未在 `ViewBuilder` 页给出 `AnyView` 性能结论 | 项目未使用 `AnyView`（0 处） | 正确 | 无需处理。 |

### 1.4 修饰器语义：层级 / 拖放 / 状态回调

| # | API | 官方规则要点（原文关键句） | 项目中位置 | 结论 | 备注 / 改法 |
|---|---|---|---|---|---|
| M1 | `ZStack` 顺序决定层级 | "The `ZStack` **assigns each successive subview a higher z-axis value** than the one before it, meaning **later subviews appear 'on top'** of earlier ones." | `App/ContentView.swift:21-34`（`mainContent` 在前、`RootOverlays` 在后） | 正确 | 项目注释（`ContentView.swift:26-29`、`RootOverlays.swift:6-9`）与官方语义完全一致：同 `zIndex` 时后者在上，互换位置确实会把叠加层压到主内容之下。<br>链接：https://developer.apple.com/documentation/swiftui/zstack |
| M2 | `zIndex(_:)` | "A relative front-to-back ordering for this view; **the default is `0`**." / "Use `zIndex(_:)` when you want to control the front-to-back ordering of views." | `UI/Shell/RootOverlays.swift:40(100) 55(200) 69(200) 82(150) 108(40)` | 正确 | 0 < 40 < 100 < 150 < 200 的层级设计合法；`zIndex` 只在**同一父容器内的兄弟节点之间**比较，项目未跨容器使用。<br>链接：https://developer.apple.com/documentation/swiftui/view/zindex(_:) |
| M3 | `.overlay { }` | "Layers the views that you specify **in front of** this view." / "If you specify more than one view in the `content` closure, the modifier collects all of the views into an implicit `ZStack`, taking them **in order from back to front**."（macOS 12.0+） | `App/ContentView.swift:38`（`.overlay { NoticeOverlay() }`）、`UI/Notices/NoticeOverlay.swift:93`、`RootOverlays.swift:93` | 正确 | 语义为「叠在前方、不改变被修饰视图布局」；`ContentView.swift:38` 的 `NoticeOverlay` 因此不会挤压主内容。<br>链接：https://developer.apple.com/documentation/swiftui/view/overlay(alignment:content:) |
| M4 | `.onDrop(of:isTargeted:perform:)` | "If the drag-and-drop operation doesn't contain any of the supported types, then this drop destination doesn't activate and `isTargeted` doesn't update." / "**Make sure to start loading the contents of `NSItemProvider` instances within the scope of the `action` closure.** Do not perform loading asynchronously on a different actor. Loading the contents may finish later, but it must start here. **For security reasons, the drop receiver can access the dropped payload only before this closure returns.**" / 官方推荐改用 `dropDestination(for:isEnabled:action:)`（未标记本 API 弃用） | `App/ContentView.swift:63-65` → `DropInstallCoordinator.handle(providers:)`（`App/ViewModels/DropInstallCoordinator.swift:47-51`）→ `Services/DragDropHandler.swift:19-27` | 正确（有两点需注意） | ① 加载**确实**在 action 闭包内同步启动（`provider.loadItem(...)` 在闭包内直接调用），符合官方要求；② 真正的文件读取发生在 `DispatchQueue.main.async` 之后（闭包已返回），官方「payload 只在闭包返回前可访问」这条对**跨沙箱来源**可能有影响——本项目 `ENABLE_APP_SANDBOX = NO`，同一进程可直达文件路径，实践无问题；若将来开启沙箱需复验。<br>链接：https://developer.apple.com/documentation/swiftui/view/ondrop(of:istargeted:perform:) |
| M5 | `.onChange(of:perform:)` 单参数形式 | "Use `onChange(of:initial:_:)` or `onChange(of:initial:_:)` instead. **The trailing closure in each case takes either zero or two input parameters, compared to this method which takes one.**" / "Be aware that the replacements have **slightly different behavior**. This modifier's closure captures values that represent the state **before** the change. The new modifiers capture values that correspond to the **new** state." | 全库 **17 处**单参数形式，其中框架层关注点：`App/ContentView.swift:41`、`UI/Notices/NoticeOverlay.swift`(无)、`UI/ViewComponents.swift:75`、`Features/Settings/ColorPickerView.swift:39,86`、`Features/Game/GameViews.swift:238,239` 等 | 有风险（中） | macOS 14+ SDK 下为**弃用告警**（非错误，项目当前 86 条告警里含此类）。**迁移不能只改签名**：旧形式在闭包内读到的 `self` 状态是「变更前」，新形式是「变更后」，对 `{ _ in applyFilter() }` 这种「闭包内读其它状态」的写法，行为可能变化 → 逐处确认，见 §2.5。<br>链接：https://developer.apple.com/documentation/swiftui/view/onchange(of:perform:) |
| M6 | `.task(id:)` / `.task` | "A closure that SwiftUI calls as an asynchronous task **before the view appears**. **SwiftUI will automatically cancel the task at some point after the view disappears** before the action completes." / "Use this modifier to perform an asynchronous task with a **lifetime that matches that of the modified view**. If the task doesn't finish before SwiftUI removes the view **or the view changes identity, SwiftUI cancels the task**." / "The task is created by `Task.immediate`. Its action begins execution synchronously until it suspends at the first `await`." | `UI/Notices/NoticeOverlay.swift:20-25`（`.task(id: center.current?.id)` 内 `Task.sleep` 4s 后自动关闭） | 正确 | 这是 `task` 相对 `onAppear` 的核心优势：新提示到来（id 变化）或视图卸载时，上一次的 4 秒等待自动取消，不会误关新提示。若写成 `onAppear + DispatchQueue.main.asyncAfter`，需要自己维护取消。<br>链接：https://developer.apple.com/documentation/swiftui/view/task(name:priority:file:line:_:) |
| M7 | `.onAppear` | "Adds an action to perform before this view appears." / "The exact moment that SwiftUI calls this method depends on the specific view type… the `action` closure completes before the first rendered frame appears."（**官方未提供任何取消机制**） | `App/ContentView.swift:50-52`（Java 预扫描）、`UI/Notices/NoticeOverlay.swift:26-32`、`UI/Modifiers/LauncherWindowModifier.swift:21`、`UI/Notices/NoticeOverlay.swift:115-119` | 正确 | 官方语义差异已用对：**需要随视图消失而中止**的工作都放 `.task`（或显式维护取消），`onAppear` 只做一次性无取消需求的副作用。<br>链接：https://developer.apple.com/documentation/swiftui/view/onappear(perform:) |
| M8 | 「视图更新期间改 `@Published`」 | 官方无明文禁止条款；`onAppear` 页只规定「首帧前完成」 | `UI/Notices/NoticeOverlay.swift:28,31`、`116-118` 用 `DispatchQueue.main.async` 把写入推迟到渲染事务外 | 存疑 | 注释（`NoticeOverlay.swift:27`）所称「避免在视图更新期间改 @Published 触发状态改写告警」是工程实践，未找到官方依据 → 见 §5。写法本身无害。 |
| M9 | `.alert(_:isPresented:presenting:actions:message:)` | macOS 12.0+ 可用 | `App/ContentView.swift:44-48` | 正确 | 部署目标 13.0，无可用性问题。 |

### 1.5 动画

| # | API | 官方规则要点（原文关键句） | 项目中位置 | 结论 | 备注 / 改法 |
|---|---|---|---|---|---|
| N1 | `Animation.spring(response:dampingFraction:blendDuration:)` | "`response`: The stiffness of the spring, defined as an **approximate duration in seconds**. A value of zero requests an infinitely-stiff spring" / "`dampingFraction`: The amount of drag applied to the value being animated, as a **fraction of an estimate of amount needed to produce critical damping**" / "`blendDuration`: The duration in seconds over which to **interpolate changes to the response value** of the spring." | `UI/AnimationExtensions.swift:4-9`（5 条曲线）、`App/ViewModels/NavigationState.swift:37`（`canvasSpring` response 0.6 / damping 0.65 / blend 0.15） | 正确 | 全部参数在官方合法区间内（`dampingFraction < 1` 即欠阻尼有回弹；0.3–0.65 属于明显回弹到轻微回弹）。`blendDuration` 是「多次动画之间的平滑过渡」，与 `response` 不是同一维度，项目用法正确。<br>链接：https://developer.apple.com/documentation/swiftui/animation/spring(response:dampingfraction:blendduration:) |
| N2 | `Animation.interpolatingSpring(mass:stiffness:damping:initialVelocity:)` | 官方："An interpolating spring animation that uses a damped spring model to produce values in the range [0, 1]… Preserves velocity across overlapping animations" | `UI/AnimationExtensions.swift:7`（`bounceBack` mass 1.5 / stiffness 200 / damping 12） | 正确 | 未指定 `response/dampingFraction` 的物理参数形式，单独一类，语义正确。<br>链接：https://developer.apple.com/documentation/swiftui/animation/interpolatingspring(mass:stiffness:damping:initialvelocity:) |
| N3 | `withAnimation(_:_:)` | "This function sets the given `Animation` as the `animation` property of the thread's current `Transaction`." | `App/ContentView.swift:108,115`（画布换页）、`UI/Notices/NoticeOverlay.swift:117` | 正确 | 调用点都在主线程的 UI 回调（手势 `onEnded`、`DispatchQueue.main.async`）内，`Transaction` 能正确随状态写入向下传播。<br>链接：https://developer.apple.com/documentation/swiftui/withanimation(_:_:) |
| N4 | `Transaction` | "Use a transaction to pass an animation between views in a view hierarchy." / "The root transaction for a state change comes from the binding that changed, plus any global values set by calling `withTransaction(_:_:)` or `withAnimation(_:_:)`." | 未直接使用 `Transaction` / `withTransaction` | 正确 | 项目只用 `withAnimation` 与 `.animation(_:value:)` 两种入口，均为官方推荐路径。<br>链接：https://developer.apple.com/documentation/swiftui/transaction |
| N5 | `.animation(_:value:)` | `value:` 形式在 macOS 12+ 未弃用（被弃用的是无 `value` 的旧形式） | `App/ContentView.swift:96`（`.animation(NavigationState.canvasSpring, value: navigation.selectedIndex)`）、`UI/Notices/NoticeOverlay.swift:18`（`.animation(.exaggeratedSpring, value: center.current?.id)`） | 正确 | 均带 `value:`（`Equatable`），无弃用告警。 |
| N6 | `matchedGeometryEffect(id:in:properties:anchor:isSource:)` | "This method sets the geometry of each view in the group from the inserted view with `isSource = true`…" / "**If the number of currently-inserted views in the group with `isSource = true` is not exactly one results are undefined**, due to it not being clear which is the source view." / "The `matchedGeometryEffect()` modifier only arranges for the **geometry** of the views to be linked, **not their rendering**."（macOS 11.0+，需 `@Namespace`） | 项目**未使用**（全库 grep 无匹配） | 正确（未使用） | 记为已知限制储备：同一 `id` 的 `isSource=true` 视图必须**恰好一个**，否则几何未定义；且它不负责淡入淡出，需配合 `transition`。<br>链接：https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:) |

### 1.6 AppKit

| # | API | 官方规则要点（原文关键句） | 项目中位置 | 结论 | 备注 / 改法 |
|---|---|---|---|---|---|
| K1 | `NSWindow.minSize` | "The minimum size to which the window's **frame (including its title bar)** can be sized." / "The minimum size constraint is enforced for resizing by the user as well as for the `setFrame...` methods **other than `setFrame(_:display:)` and `setFrame(_:display:animate:)`**." | `App/AppDelegate.swift:9`（800×590）、`UI/Modifiers/LauncherWindowModifier.swift:25`（800×550） | 有风险（中） | ① `minSize` 含标题栏，而项目语义想要的是「内容区最小」；② 两次写入同一属性，后写覆盖先写；③ 官方明文 `setFrame(_:display:)` **绕过**该约束（`AppDelegate.swift:19` 正用该方法）。<br>链接：https://developer.apple.com/documentation/appkit/nswindow/minsize |
| K2 | `NSWindow.contentMinSize` | "The minimum size of the window's **content view** in the window's base coordinate system." / "**This method takes precedence over the `minSize` property.**" | 项目**未直接**设置，但 SwiftUI 会依据 `.windowResizability` 推导（见 A8 / §3） | **错误（数值被静默覆盖）** | 官方明文 **`contentMinSize` 优先于 `minSize`**。因此 `LauncherWindowModifier` 写入的 550 并不能决定最终最小尺寸——详见 §2.3、§3。<br>链接：https://developer.apple.com/documentation/appkit/nswindow/contentminsize |
| K3 | `titlebarAppearsTransparent` + `styleMask.insert(.fullSizeContentView)` | "When the value of this property is `true`, the title bar does not draw its background, which allows all content underneath it to show through. **It only makes sense to set this property to `true` when `NSFullSizeContentViewWindowMask` is also set.**" | `App/AppDelegate.swift:7-8`、`UI/Modifiers/LauncherWindowModifier.swift:23-24`（两处都成对设置） | 正确 | 项目两处都同时设置了 `fullSizeContentView`，符合官方前提；两处重复设置同一组属性，见 §2.2（幂等，无副作用）。<br>链接：https://developer.apple.com/documentation/appkit/nswindow/titlebarappearstransparent |
| K4 | `NSApplication.windows` | "This property contains an array of `NSWindow` objects corresponding to **all currently existing windows** for the app. The array includes all onscreen **and offscreen** windows, whether or not they are visible on any space. **There is no guarantee of the order of the windows in the array.**" | `App/AppDelegate.swift:6`、`UI/Modifiers/LauncherWindowModifier.swift:22`、`PCLCore/Minecraft/MinecraftInstance.swift:359`（`windows.first ?? keyWindow` 作为 sheet 宿主） | 有风险（高） | 官方明文**顺序无保证**，且数组含**屏幕外窗口**（如面板、隐藏窗口、SwiftUI 内部 window）。`.first` 可能拿到错误的窗口 → 详见 §2.2。<br>链接：https://developer.apple.com/documentation/appkit/nsapplication/windows |
| K5 | `NSColor` 与归档 | `NSColor` 的 Conforms To 含 **`NSCoding`、`NSSecureCoding`、`Sendable`**（即 NSColor 本身支持安全编码） | `Features/Settings/AppSettingsStore.swift:110`、`Features/Settings/ThemeManager.swift:23` 归档；`AppSettingsStore.swift:117`、`ThemeManager.swift:30` 解档 | 有风险（中） | 归档侧传 `requiringSecureCoding: false`（关闭防护），解档侧用 `unarchivedObject(ofClass:)`（安全解档 API），两侧策略不匹配 → 见 §2.4。<br>链接：https://developer.apple.com/documentation/appkit/nscolor |
| K6 | `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding:)` | 官方 API 列表可见：旧的 `archivedData(withRootObject:)`（无参版）标注 **Deprecated**，当前版本带 `requiringSecureCoding:`；`requiresSecureCoding` 属性说明为 "Indicates whether the archiver **requires all archived classes to resist object substitution attacks**." | `Features/Settings/AppSettingsStore.swift:110`、`ThemeManager.swift:23` | 存疑（防护强度） | 未弃用（用的是新签名），但 `false` 等于放弃对象替换攻击防护（这正是该参数存在的唯一目的）。改法见 §2.4。<br>链接：https://developer.apple.com/documentation/foundation/nskeyedarchiver |
| K7 | `NSKeyedUnarchiver.unarchivedObject(ofClass:from:)` | 官方页面正文为 JS 渲染未能抓取；Topics 中 `requiresSecureCoding`："Indicates whether the receiver requires all unarchived classes to conform to `NSSecureCoding`." | `AppSettingsStore.swift:117`、`ThemeManager.swift:30` | 存疑 | 「`requiringSecureCoding: false` 归档 + `unarchivedObject(ofClass:)` 解档」是否在所有系统版本上都等价可用，**官方无明文** → 见 §5。归档侧改为 `true` 后两侧策略一致，风险归零。<br>链接：https://developer.apple.com/documentation/foundation/nskeyedunarchiver |
| K8 | `Color(nsColor:)` | "Creates a color from an AppKit color."（macOS 12.0+） | `AppSettingsStore.swift:120`、`ThemeManager.swift:31` | 正确 | 部署目标 13.0 ≥ 12.0。<br>链接：https://developer.apple.com/documentation/swiftui/color/init(nscolor:) |
| K9 | `NSApp.applicationIconImage` / `NSImage.lockFocus` | 官方未对 `lockFocus` 给出弃用标注（属遗留绘图 API） | `App/AppDelegate.swift:22-33` | 正确 | 仅记录：`lockFocus/unlockFocus` 是遗留 API（新代码一般用 `NSImage(size:flipped:drawingHandler:)`），官方页面未标注弃用故不列为风险。 |

### 1.7 Foundation

| # | API | 官方规则要点（原文关键句） | 项目中位置 | 结论 | 备注 / 改法 |
|---|---|---|---|---|---|
| F1 | `Process.terminationHandler` | "A completion block the system invokes when the task completes." / "**This block isn't guaranteed to be fully executed prior to `waitUntilExit()` returning.**"（官方**未说明执行线程**） | `PCLCore/Minecraft/Launch/MinecraftLauncher.swift:162-165`、`Features/Launch/Adapters/…`（`ManagedProcess.waitForTermination`） | 正确 | 项目在 `run()` **之前**挂载 handler（`MinecraftLauncher.swift:158-167` 注释说明），规避了「秒退导致 handler 永不触发」；handler 内只做 `signal` + 一次性门控，重活已 `DispatchQueue.main.async` 外抛。<br>执行线程无官方明文 → 见 §5；项目不依赖线程假设，安全。<br>链接：https://developer.apple.com/documentation/foundation/process/terminationhandler |
| F2 | `Process.waitUntilExit()` | "Blocks the process until the receiver is finished." / "This method first checks to see if the receiver is still running using `isRunning`. **Then it polls the current run loop using `NSDefaultRunLoopMode` until the task completes.**" / "`waitUntilExit()` **does not guarantee** that the `terminationHandler` block has been fully executed before `waitUntilExit()` returns." | **项目已避免使用**：`MinecraftLauncher.swift:186-195` 用「信号量 1s 超时轮询 + `isRunning` 兜底」替代 | 正确（规避得很干净） | 官方两条告诫都被项目处理：① 它「poll 当前 runloop」→ 在主线程调用会空转主 runloop/卡 UI；② 它不等 `terminationHandler` → 依赖它做收尾会有竞态。项目的注释（`MinecraftLauncher.swift:186`）与之吻合。<br>链接：https://developer.apple.com/documentation/foundation/process/waituntilexit() |
| F3 | `Process` 单实例只能跑一次 | "**You can only run the subprocess once per instance. Subsequent attempts raise an error.**" | `MinecraftLauncher.swift:118`（每次 `launch` 新建 `Process()`）、`ProcessPoolGameProcessController.swift:81`（每次新建） | 正确 | 不存在复用 `Process` 实例的路径。<br>链接：https://developer.apple.com/documentation/foundation/process |
| F4 | `Process.standardOutput` 与 Pipe 的写端 | "If `file` is an `NSPipe` object, **launching the receiver automatically closes the write end of the pipe in the current task.** Don't create a handle for the pipe and pass that as the argument, **or the write end of the pipe won't be closed automatically**." | `MinecraftLauncher.swift:145-147`（`process.standardOutput = pipe` / `standardError = pipe`，传的是 **Pipe** 本身） | 正确（★本次核对重点） | 官方明文保证了 `drainPipe` 的前提：子进程退出后写端必然关闭 → 读端**必然到达 EOF** → 「先排空、再解绑、最后关句柄」的顺序不会阻塞、不会丢数据。项目`MinecraftLauncher.swift:197-203` 的顺序与官方语义自洽。<br>反例提醒（同一句官方原文）：**如果改成传 `pipe.fileHandleForWriting`，写端不会被自动关闭**，`drainPipe` 将永远读不到 EOF → 死锁。项目当前没有这种写法。<br>链接：https://developer.apple.com/documentation/foundation/process/standardoutput |
| F5 | `FileHandle.readabilityHandler` 的解除方式 | "Your block is submitted to the file handle's **dispatch queue** when there is data to read." / "**To stop reading the file or socket, set the value of this property to `nil`. Doing so cancels the dispatch source and cleans up the file handle's structures appropriately.**" | `MinecraftLauncher.swift:154-156`（挂载）、`202`（置 `nil`）、`213`（异常路径置 `nil`） | 正确（★本次核对重点） | 官方语义解释了为什么「先置 `nil` 再关句柄」会丢日志尾：置 `nil` = **取消 dispatch source 并清理文件句柄结构**，已到达内核管道缓冲、但尚未被 handler 取走的字节不再有投递路径。项目现行顺序「`drainPipe` 排空 → 置 `nil` → `writer.close()`」与官方机制一致。<br>链接：https://developer.apple.com/documentation/foundation/filehandle/readabilityhandler |
| F6 | `FileHandle.read(upToCount:)` 的 EOF 语义 | "**Returns an empty `NSData` object if the handle is at the file's end** or if the communications channel returns an end-of-file indicator." / "If `length` bytes aren't available, this method returns the data from the current file pointer to the end of the file."（macOS 10.15.4+） | `MinecraftLauncher.swift:93-98`（`while let chunk = try? handle.read(upToCount: 64*1024), !chunk.isEmpty`） | 正确 | 关键点：EOF 返回**空 Data 而非 nil**，因此 `!chunk.isEmpty` 是必须的终止条件，项目写对了；若只判 `nil` 会死循环。<br>链接：https://developer.apple.com/documentation/foundation/filehandle/read(uptocount:) |
| F7 | `FileHandle` 的线程与重入 | 官方未承诺 handler 的执行线程，只说明「submitted to the file handle's dispatch queue」 | `MinecraftLauncher.swift:44-86`（`GameLogWriter` 用 `NSLock` 保护缓冲与句柄，`isClosed` 挡住关闭后在途回调） | 正确 | 官方无明文线程保证 → 加锁是必要防御（`readabilityHandler` 在私有串行队列、退出排空在启动线程，确实并发）。锁内不回调外部、不反向取锁，无死锁。<br>链接：https://developer.apple.com/documentation/foundation/filehandle |
| F8 | `Pipe` 缓冲与不读的后果 | "The data that passes through the pipe is **buffered**; the size of the buffer is determined by the underlying operating system." | `MinecraftLauncher.swift:154`（有 reader）；`ProcessPoolGameProcessController.swift:90-92`（直接绑 FileHandle，**不经管道**） | 正确 | 管道缓冲由 OS 决定（实践约 64KB，官方未给数值，见 §5）；项目两条路径都避免了「无人读取写满缓冲导致子进程阻塞」：前者有 handler，后者直接写入文件句柄。适配器文件头注释的论述成立。<br>链接：https://developer.apple.com/documentation/foundation/pipe |
| F9 | `FileManager.urls(for:in:)` | "Returns an array of URLs for the specified common directory in the requested domains."（**未承诺目录已存在**） | `App/AppContext.swift:61-64`（取 `[0]` 后 `createDirectory`）、`MinecraftLauncher.swift:110`、`ProcessPoolGameProcessController.swift:68` | 正确 | 项目在取用后立刻 `createDirectory(withIntermediateDirectories: true)`，符合「官方不保证存在」的前提。更稳的官方替代是 `url(for:in:appropriateFor:create:)`（可原子级创建）。<br>链接：https://developer.apple.com/documentation/foundation/filemanager/urls(for:in:) |
| F10 | `DispatchSource.makeMemoryPressureSource(eventMask:queue:)` | "**The returned dispatch source is in the inactive state initially. When you are ready to begin processing events, call its `activate()` method.**" / `queue`: "The dispatch queue to use when executing the installed handlers." | `App/AppContext.swift:76-84`（`eventMask: [.warning, .critical]`，未传 queue，用 `resume()`） | 有风险（低） | ① 用 `resume()` 启动（未找到官方「`resume()` 等价 `activate()`」明文 → 见 §5），工程上等价可用；② 未传 `queue` → 处理器在默认队列执行（与同事手册 §2.8 的隔离结论交叉，本手册不重复）；③ 缺少 `.normal` 掩码 → 压力解除后不会回调（`AppContext.swift:78-80` 注释说明是有意为之，属设计选择）。<br>链接：https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource(eventmask:queue:) |
| F11 | `MemoryPressureEvent` 掩码取值 | `.all` / `.normal`（changed to normal）/ `.warning` / `.critical` 四个值 | `AppContext.swift:76`（`.warning`、`.critical`） | 正确 | 取值合法（`OptionSet`）。<br>链接：https://developer.apple.com/documentation/dispatch/dispatchsource/memorypressureevent |
| F12 | `DispatchSourceProtocol.cancel()` | "Asynchronously cancels the dispatch source, preventing any further invocation of its event handler block." / "**It is invalid to close a file descriptor or deallocate a mach port that is currently being tracked by a dispatch source object before the cancellation handler is invoked.**" | `App/AppContext.swift:87-89`（`deinit { memoryPressureSource?.cancel() }`） | 正确 | 内存压力源不持有文件描述符/mach port，官方那条「cancel 后才能关句柄」不适用；但 `deinit` 取消是正确习惯（源未取消时被释放属未定义行为，见 §5）。<br>链接：https://developer.apple.com/documentation/dispatch/dispatchsourceprotocol/cancel() |
| F13 | `URLSessionConfiguration.timeoutIntervalForResource` | "The resource timeout interval controls **how long (in seconds) to wait for an entire resource to transfer** before giving up. The resource timer starts when the request is initiated… **The default value is 7 days.**" | `App/AppContext.swift:18`（600s，下载）/ `28`（15s，API）/ `38`（12s，翻译）；`PCLCore/Utils/Requests.swift:59`（600s） | 正确 | 语义用对：大文件下载给 10 分钟、API 给 15 秒。注意它**不是**单次请求超时（那是 `timeoutIntervalForRequest`，`AppContext.swift:17,27,37` 已分别设为 30/10/8s）。<br>链接：https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforresource |
| F14 | `URLSessionConfiguration.httpMaximumConnectionsPerHost` | "**This limit is per session**… Additionally, depending on your connection to the Internet, a session may use a **lower** limit than the one you specify. The default value is `6`. **HTTP/2 and later run multiple requests over a single connection and thus ignore this property.**" | `App/AppContext.swift:19`（8）、`29`（4）、`39`（2）；`Requests.swift:63`（16，注释称「与分片池 16 路对齐」） | 有风险（低） | 对 HTTP/2 站点（Mojang/BMCLAPI/Modrinth 多为 HTTP/2）该值**不产生效果**；且它是 per-session，多会话叠加会突破上限（项目原有注释「多会话叠加会超」的判断与官方一致）。<br>链接：https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpmaximumconnectionsperhost |
| F15 | `URLSessionConfiguration.connectionProxyDictionary` | "The default value is `NULL`, **which means that tasks use the default system settings**." / 官方当前推荐改用 `proxyConfigurations`："Prefer using `proxyConfigurations`, which supports secure proxy and relay types." | `App/AppContext.swift:16`、`Requests.swift:57`（均设 `[:]`，注释称「空字典 = 不使用任何代理（nil 才是走系统默认代理）」） | 存疑（依赖未文档化行为） | 官方**只明文说明 `nil` 的含义**，未说明「空字典 = 禁用代理」。项目注释的推断在实践中成立（社区长期使用），但属未文档化行为 → 见 §2.7、§5。<br>链接：https://developer.apple.com/documentation/foundation/urlsessionconfiguration/connectionproxydictionary |
| F16 | `URLSessionConfiguration.httpShouldUsePipelining` | 页面顶部提示："**Pipelining is an HTTP/1.1 concept. Adopt HTTP/2 or later instead.**" / "The default value is `false`. **HTTP/2 and later ignore this property. HTTP/1.1 only considers this property in the classic loading mode** (`usesClassicLoadingMode`)." | `Requests.swift:65`（`c.httpShouldUsePipelining = true`） | 有风险（低） | 在「非经典加载模式」或 HTTP/2 下该设置**不生效**；官方首页直接建议改用 HTTP/2。建议删除该行（收益不明、语义不保证）。<br>链接：https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpshouldusepipelining |
| F17 | `URLSessionConfiguration.urlCache` | "To disable caching, set this property to `nil`. For default sessions, **the default value is the shared URL cache object**… For ephemeral sessions, the default value is a private cache object that stores data in memory only" | `App/AppContext.swift:20`（16MB/64MB）、`30`（8MB/32MB）；`translateSession`（35-41）未设 → 用**全局共享 URLCache** | 正确 | 两个下载会话各自持有独立 `URLCache`（隔离正确）；翻译会话不设 cache 会与 `URLCache.shared` 共用，属默认语义，无错误（仅提示：若翻译结果需严格不落盘，应显式设 `nil` 或用 ephemeral 配置）。<br>链接：https://developer.apple.com/documentation/foundation/urlsessionconfiguration/urlcache |
| F18 | `URLSession.AsyncBytes`（`bytes(for:)`）逐字节迭代 | 官方 `URLSession.bytes(for:)` 返回 `AsyncBytes`，可 `for try await byte in …` | `PCLCore/Download/NetDownloader.swift:579,622`（逐字节 append 到 256KB 缓冲） | 正确（性能另议） | API 语义正确，`Task.checkCancellation()`（`NetDownloader.swift:623`）在循环内保证可取消；逐字节迭代的吞吐属性能话题，不在本次核对范围。 |
| F19 | `Data.write(to:options:)` 原子写 | "Since at present only `file://` URLs are supported, there is no difference between this method and `write(toFile:options:)`" / "This method may not be appropriate when writing to publicly accessible files. To securely write data to a public location, use `FileHandle` instead." | `PCLCore/Download/NetDownloader.swift`（分片用 `FileHandle` 写入，合并后由 `FileChecker` 校验）；未使用 `.atomic` | 正确 | 项目对「公开可访问路径」的写法与官方建议一致（走 `FileHandle`）。<br>链接：https://developer.apple.com/documentation/foundation/nsdata/write(to:options:) |
| F20 | App Sandbox 下 `Process` | "**In a sandboxed app, child processes you create with this class inherit the sandbox of the parent app.** Instead, write helper apps as XPC Services because it allows you to specify different sandbox entitlements for helper apps." | 项目 `ENABLE_APP_SANDBOX = NO` | 正确 | 因未启用沙箱，该告警不适用；`Process` 可正常拉起用户目录下的 `java`。若未来开启沙箱，此条会立刻变成阻塞性问题。<br>链接：https://developer.apple.com/documentation/foundation/process |
| F21 | `NSItemProvider.loadItem(forTypeIdentifier:options:completionHandler:)` | 页面标注 **Deprecated**（macOS 10.10–27），提示 "Use `loadObjectOfClass:completionHandler:` instead." / "The block **may be executed on a background thread**." | `Services/DragDropHandler.swift:21` | 有风险（中） | ① 使用已弃用 API；② 官方「可能在后台线程回调」被正确对待（项目 `DispatchQueue.main.async` 回主线程，见 `DragDropHandler.swift:23-25`）。改法见 §2.6。<br>链接：https://developer.apple.com/documentation/foundation/nsitemprovider/loaditem(fortypeidentifier:options:completionhandler:) |

---

## 2. 风险条目（按严重度排序）

### 2.1 【高】默认窗口尺寸 900×660 从未生效：死分支 + 缺失 `.defaultSize`

**事实链**

1. `qwq.xcodeproj` 的 `MACOSX_DEPLOYMENT_TARGET = 13.0` → 应用不可能运行在 < 13.0 的系统上。
2. `App/AppDelegate.swift:12` 的唯一窗口尺寸设置被 `if #unavailable(macOS 13.0) { … }` 包住 → **该分支恒不执行**（死代码）。
3. `App/qwqApp.swift:20-21` 的注释声称「macOS 13+ 由 qwqApp 里的 `.defaultSizeCompat` 声明」，但全库 grep 无 `.defaultSize` / `.defaultSizeCompat`（`qwqApp.swift:14-22` 的 `body` 只有 `WindowGroup + .windowStyle`）。
4. 结论：**没有任何一处为 macOS 13+ 设置启动尺寸**。首帧窗口尺寸由 SwiftUI 依内容推导，不受 900×660 控制；注释与代码不符。

**官方依据**：`NSWindow.minSize` 对 `setFrame(_:display:)` 的豁免说明该分支即便执行也走的是「绕过最小尺寸约束的直设路径」（https://developer.apple.com/documentation/appkit/nswindow/minsize ）；`Scene.defaultSize(width:height:)` 是官方的窗口默认尺寸入口（https://developer.apple.com/documentation/swiftui/scene/defaultsize(width:height:) ）。

**改前**

```swift
// AppDelegate.swift:10-20
// macOS 12 没有 Scene.defaultSize，手动设置默认窗口尺寸（900×660）并居中；
// macOS 13+ 由 qwqApp 里的 .defaultSizeCompat 声明。
if #unavailable(macOS 13.0) {
    let size = NSSize(width: 900, height: 660)
    let screenFrame = NSScreen.main?.visibleFrame ?? .zero
    let origin = NSPoint(
        x: screenFrame.midX - size.width / 2,
        y: screenFrame.midY - size.height / 2
    )
    window.setFrame(NSRect(origin: origin, size: size), display: true)
}
```

```swift
// qwqApp.swift:14-22
var body: some Scene {
    WindowGroup {
        ContentView()
            .frame(minWidth: 800, minHeight: 590)
    }
    .windowStyle(.hiddenTitleBar)
}
```

**改后（推荐：把启动尺寸交回 Scene，删掉死分支）**

```swift
// qwqApp.swift —— 部署目标已是 macOS 13.0，defaultSize 可用
private enum WindowMetrics {
    static let minWidth: CGFloat = 800
    static let minHeight: CGFloat = 590   // 与 §3 的统一值一致
    static let defaultWidth: CGFloat = 900
    static let defaultHeight: CGFloat = 660
}

var body: some Scene {
    WindowGroup {
        ContentView()
            .frame(minWidth: WindowMetrics.minWidth,
                   minHeight: WindowMetrics.minHeight)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: WindowMetrics.defaultWidth,
                 height: WindowMetrics.defaultHeight)   // macOS 13.0+
    .windowResizability(.contentMinSize)               // 显式声明，避免依赖 .automatic 的隐式推导
}
```

```swift
// AppDelegate.swift —— 删除 #unavailable 分支（部署目标 13.0，永不执行）
func applicationDidFinishLaunching(_ notification: Notification) {
    guard let window = NSApp.windows.first else { return }
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    // 窗口最小尺寸不在这里设：官方明文 contentMinSize 优先于 minSize（见 §2.3）
    window.contentMinSize = NSSize(width: WindowMetrics.minWidth,
                                   height: WindowMetrics.minHeight)
    // … 图标缩放逻辑保持不变
}
```

> 注：`WindowMetrics` 需放在 `qwq/` 内才能被两个文件共用；本手册不改源码，仅给出建议形态。

---

### 2.2 【高】`NSApp.windows.first` 定位窗口：官方明文「顺序无保证」

**官方原文**："This property contains an array of `NSWindow` objects corresponding to all currently existing windows for the app. The array includes all onscreen **and offscreen** windows… **There is no guarantee of the order of the windows in the array.**"（https://developer.apple.com/documentation/appkit/nsapplication/windows ）

**受影响位置**：`App/AppDelegate.swift:6`、`UI/Modifiers/LauncherWindowModifier.swift:22`、`PCLCore/Minecraft/MinecraftInstance.swift:359`。

风险表现：一旦应用出现第二个窗口（SwiftUI 的 `Settings` 场景、`NSColorPanel`、`NSSavePanel` 辅助窗口、崩溃报告窗口等），`.first` 可能落到屏幕外/面板窗口上 → 最小尺寸、透明标题栏、sheet 宿主全部作用到错误窗口，且**没有任何报错**（`guard let` 只挡 nil）。

**改前**

```swift
// LauncherWindowModifier.swift:21-26
content.onAppear {
    guard let window = NSApp.windows.first else { return }
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    window.minSize = NSSize(width: 800, height: 550)
}
```

```swift
// MinecraftInstance.swift:359
let sheetHost = NSApplication.shared.windows.first ?? NSApplication.shared.keyWindow
```

**改后（按窗口身份定位，而非数组下标）**

```swift
// 方案 A：给主窗口打标记，按标记取
// qwqApp 里：ContentView().background(WindowAccessor { window in
//     window.identifier = NSUserInterfaceItemIdentifier("launcher.main") })
enum MainWindow {
    static let identifier = NSUserInterfaceItemIdentifier("launcher.main")
    static var instance: NSWindow? {
        NSApp.windows.first { $0.identifier == identifier }
            ?? NSApp.mainWindow
            ?? NSApp.keyWindow
    }
}

content.onAppear {
    guard let window = MainWindow.instance else { return }
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    window.contentMinSize = NSSize(width: 800, height: 590)  // 见 §2.3
}
```

```swift
// 方案 B（最小改动）：至少收敛到官方语义更强的 keyWindow/mainWindow
let sheetHost = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first
```

---

### 2.3 【中】`minSize` 550 与内容最小高度 590 冲突：官方明文 `contentMinSize` 优先

**官方原文**：`contentMinSize` — "The minimum size of the window's content view in the window's base coordinate system. **This method takes precedence over the `minSize` property.**"（https://developer.apple.com/documentation/appkit/nswindow/contentminsize ）

`LauncherWindowModifier.swift:8-10` 的注释断言「该配置在 AppDelegate 之后执行并覆盖其 minSize（590）」。**这只对 `minSize` 属性成立**：它确实覆盖了 AppDelegate 写入的 590，但最终生效的最小尺寸由 `contentMinSize` 决定（SwiftUI 依 `.windowResizability(.automatic → .contentMinSize)` 与根视图最小 frame 推导，见 §3），因此 **550 无法成为实际最小值**，注释给出的因果链不完整。

**改前**

```swift
// LauncherWindowModifier.swift:21-26
content.onAppear {
    guard let window = NSApp.windows.first else { return }
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    window.minSize = NSSize(width: 800, height: 550)   // ← 与内容最小高度 590 不一致，且被 contentMinSize 压过
}
```

**改后（数值统一 + 用官方优先级更高的属性）**

```swift
content.onAppear {
    guard let window = MainWindow.instance else { return }
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    // 内容区最小尺寸：与根视图 .frame(minHeight:) 取同一常量，避免两套数值
    window.contentMinSize = NSSize(width: 800, height: 590)
}
```

或更进一步（更符合「单一数据源」）：**删掉这句 AppKit 写入**，只保留根视图 `.frame(minWidth:minHeight:)`，由 `.windowResizability(.contentMinSize)` 统一推导。

---

### 2.4 【中】`NSKeyedArchiver … requiringSecureCoding: false`（两处）

**官方依据**：`requiresSecureCoding` — "Indicates whether the archiver requires all archived classes to **resist object substitution attacks**."（https://developer.apple.com/documentation/foundation/nskeyedarchiver ）；`NSColor` 本身符合 `NSSecureCoding`（https://developer.apple.com/documentation/appkit/nscolor ），因此**没有理由关闭它**。

**受影响位置**：`Features/Settings/AppSettingsStore.swift:110`、`Features/Settings/ThemeManager.swift:23`。

**改前**

```swift
// AppSettingsStore.swift:109-113
private func saveColor(_ color: Color, forKey key: String) {
    if let data = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(color), requiringSecureCoding: false) {
        UserDefaults.standard.set(data, forKey: key)
    }
}
```

```swift
// ThemeManager.swift:21-27
@Published var accentColor: Color {
    didSet {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(accentColor), requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: UDK.accentColor)
        }
    }
}
```

**改后**

```swift
// 归档侧改为安全编码；解档侧已用 unarchivedObject(ofClass:from:)（安全解档 API），两侧策略对齐
private func saveColor(_ color: Color, forKey key: String) {
    if let data = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(color), requiringSecureCoding: true) {
        UserDefaults.standard.set(data, forKey: key)
    }
}
```

```swift
@Published var accentColor: Color {
    didSet {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(accentColor), requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: UDK.accentColor)
        }
    }
}
```

**迁移注意**：旧版本写入的非安全归档数据在改为 `true` **之后仍可被 `unarchivedObject(ofClass:)` 读取**（读侧未变）；若实测出现读失败，正确处置是「读失败即回退默认色并重写」（现有 `loadStoredColor` 已返回 nil → 回退 `.blue`，行为安全）。此点官方无明文保证 → 列入 §5，建议改后手工验证一次。

---

### 2.5 【中】`onChange(of:)` 单参数形式：17 处弃用 + 迁移语义差异

**官方原文**："Use `onChange(of:initial:_:)` … instead. The trailing closure in each case takes either zero or two input parameters, compared to this method which takes one." / "Be aware that **the replacements have slightly different behavior. This modifier's closure captures values that represent the state before the change. The new modifiers capture values that correspond to the new state.**"（https://developer.apple.com/documentation/swiftui/view/onchange(of:perform:) ）

**受影响位置**（17 处，含框架层重点）：`App/ContentView.swift:41`、`UI/ViewComponents.swift:75`、`Features/Settings/ColorPickerView.swift:39,86`、`Features/ModBrowser/ModDetailView.swift:169,173`、`Features/ModBrowser/CategoryContentView.swift:147,150,246,365`、`Features/Launch/SessionLogCardView.swift:46`、`Features/Launch/LaunchButton.swift:132`、`Features/Java/JavaPickerView.swift:188`、`Features/Game/GameViews.swift:238,239,327`、`Features/Game/GameCategoryView.swift:69`。

**改前**

```swift
// ContentView.swift:41-43
.onChange(of: navigation.selectedCategory) { _ in
    navigation.handleSelectedCategoryChange()
}
```

```swift
// GameViews.swift:238
.onChange(of: searchText) { _ in applyFilter() }
```

**改后（机械迁移：忽略入参 → 零参形式，语义与旧写法最接近）**

```swift
.onChange(of: navigation.selectedCategory) { _, _ in
    navigation.handleSelectedCategoryChange()
}
// 或零参数形式：
// .onChange(of: navigation.selectedCategory) { navigation.handleSelectedCategoryChange() }
```

```swift
.onChange(of: searchText) { _, _ in applyFilter() }
```

**逐处复验要点**（官方那句「旧形式捕获的是变更前状态」是本次迁移的真实风险）：

- 闭包内**只读入参、不读其它状态** → 零参/双参皆可，直接迁移。
- 闭包内**读其它会同时变化的状态**（如 `LaunchButton.swift:132` 的 `launchPhase` 分支、`CategoryContentView.swift:365` 读 Minecraft 版本） → 必须确认「读到的应是变更后还是变更前」，双参形式会改为「变更后」语义。

---

### 2.6 【中】`NSItemProvider.loadItem(forTypeIdentifier:)` 已弃用

**官方原文**：页面标注 Deprecated（macOS 10.10–27），提示 "**Use `loadObjectOfClass:completionHandler:` instead.**"；"The block **may be executed on a background thread**."（https://developer.apple.com/documentation/foundation/nsitemprovider/loaditem(fortypeidentifier:options:completionhandler:) ）

**受影响位置**：`Services/DragDropHandler.swift:21`（`loadItem`）；回主线程的部分（`:23-25`）已正确。

**改前**

```swift
// DragDropHandler.swift:17-29
func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
    for provider in providers {
        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    completion([url])
                }
            }
            return true
        }
    }
    return false
}
```

**改后（用 `UTType` + 官方推荐的 `loadDataRepresentation`，沙箱下也保留安全作用域内的读取时机）**

```swift
import UniformTypeIdentifiers

func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        // 在 onDrop 的 action 闭包作用域内同步「启动」加载（官方要求）
        _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in completion([url]) }   // 官方：回调可能在后台线程
        }
        return true
    }
    return false
}
```

> 若后续切到 `.onDrop` 的替代者 `dropDestination(for:action:isTargeted:)`（官方推荐、支持 `Transferable`），文件 URL 部分可直接用 `URL` 作为 `Transferable`，本函数可整体删除。

---

### 2.7 【低-中】直连会话三项配置：一项无官方依据、两项实际不生效

| 项 | 位置 | 官方原文 | 处置 |
|---|---|---|---|
| `connectionProxyDictionary = [:]` | `App/AppContext.swift:16`、`Requests.swift:57` | "The default value is `NULL`, **which means that tasks use the default system settings**."（未说明空字典） | 依赖未文档化行为。若必须保证直连，官方当前推荐路径是 `proxyConfigurations`（"Prefer using `proxyConfigurations`, which supports secure proxy and relay types."）；至少应补注释标明「官方未明文，属实测行为」 |
| `httpShouldUsePipelining = true` | `Requests.swift:65` | "**Pipelining is an HTTP/1.1 concept. Adopt HTTP/2 or later instead.**" / "HTTP/2 and later **ignore** this property. HTTP/1.1 **only considers** this property in the classic loading mode" | 建议**删除该行**（语义不保证、收益不确定） |
| `httpMaximumConnectionsPerHost = 16` | `Requests.swift:63` | "**HTTP/2 and later run multiple requests over a single connection and thus ignore this property.**" / "This limit is per session" | 保留无害，但注释「与分片池 16 路对齐 → 不再被每主机 8 连接卡住」的推断对 HTTP/2 站点不成立，建议修正注释 |

**改前**

```swift
// Requests.swift:54-67
static let direct: URLSession = {
    let c = URLSessionConfiguration.default
    c.connectionProxyDictionary = [:]
    c.timeoutIntervalForRequest = 30
    c.timeoutIntervalForResource = 600
    c.httpMaximumConnectionsPerHost = 16
    c.httpShouldUsePipelining = true    // ← HTTP/1.1-only，且非经典加载模式下被忽略
    return URLSession(configuration: c)
}()
```

**改后**

```swift
static let direct: URLSession = {
    let c = URLSessionConfiguration.default
    // 注意：官方仅明文说明 nil = 使用系统默认代理；空字典“禁用一切代理”属实测行为（无官方依据）
    c.connectionProxyDictionary = [:]
    c.timeoutIntervalForRequest = 30
    c.timeoutIntervalForResource = 600
    // 仅对 HTTP/1.1 且非经典加载模式生效；HTTP/2 忽略该值（保留仅为兼容 HTTP/1.1 镜像源）
    c.httpMaximumConnectionsPerHost = 16
    return URLSession(configuration: c)
}()
```

---

### 2.8 【低】`@ObservedObject` 直接给初值（35 处）+ `@StateObject` 持有单例（1 处）

**官方原文**："**Don't specify a default or initial value for the observed object.** Use the attribute only for a property that acts as an input for a view."（https://developer.apple.com/documentation/swiftui/observedobject ）；`@StateObject`："Use a state object as the single source of truth for a reference type that you store in a view hierarchy… Declare state objects as private to prevent setting them from a memberwise initializer"（https://developer.apple.com/documentation/swiftui/stateobject ）。

**受影响位置**：**35 处**（`@ObservedObject` 全库共 41 处，另 6 处为正常注入形式）。典型：`UI/ViewComponents.swift:108,136`、`UI/Notices/NoticeOverlay.swift:6,38,126`、`Features/Game/GameCards.swift:15,72,140,186`、`Features/Settings/ColorPickerView.swift:4,25,58`、`Features/ModBrowser/ModDetailView.swift:21,22,23`。

**为什么当前不炸**：这些对象都是 `static let shared` 的永生单例，视图无论如何重建，`wrappedValue` 都指向同一实例，订阅永远不会失效。

**改前**

```swift
struct NoticeOverlay: View {
    @ObservedObject private var center = NoticeCenter.shared
```

```swift
// ContentView.swift:6
@StateObject private var settings = LauncherSettings.shared
```

**改后（两种方向，任选其一，全库统一）**

```swift
// 方向一：保持单例，但作为「注入的输入」而非「自带初值的观察对象」
struct NoticeOverlay: View {
    @ObservedObject var center: NoticeCenter = .shared   // 语义等价，仅去掉 private 默认值写法
```

```swift
// 方向二：由根视图一次性持有，子视图走环境（官方推荐的 StateObject + EnvironmentObject 组合）
// qwqApp 或 ContentView：
@StateObject private var settings = LauncherSettings.shared
ContentView().environmentObject(settings)
// 子视图：
@EnvironmentObject private var settings: LauncherSettings
```

> 若未来迁移到 `@Observable`：`@ObservedObject` 必须整体去掉（官方："Attempting to wrap an `Observable` object with `@ObservedObject` **may cause a compiler error**"），`@StateObject` 换成 `@State`。

---

### 2.9 【低】`ProcessPoolGameProcessController`：`terminationHandler` 挂载时机 + 日志句柄关闭

**官方依据**：`terminationHandler` — "A completion block the system invokes when the task completes."；官方**未给出挂载时机的承诺**（https://developer.apple.com/documentation/foundation/process/terminationhandler ）。`standardOutput` 的自动关写端结论**只针对传 `Pipe` 的情况**（https://developer.apple.com/documentation/foundation/process/standardoutput ）。

**事实**：`ProcessPoolGameProcessController.swift:98` 先 `run()`，`:95-97` 的注释自述「terminationHandler 的挂载由 `ManagedProcess.waitForTermination` 负责，与 `MinecraftLauncher`『run() 之前挂 handler』相比存在窄竞态」；`:91-92` 传的是 **FileHandle**（不是 Pipe），因此「进程释放时关闭句柄」这一注释**无官方依据**，`:99-102` 仅失败路径 `close()`，成功路径的句柄归属未定义。

**改前**

```swift
// ProcessPoolGameProcessController.swift:87-102
guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
    throw LaunchError.processStartFailed(reason: "无法创建游戏日志文件：\(logURL.path)")
}
process.standardOutput = logHandle
process.standardError = logHandle
do {
    try process.run()          // handler 由调用方在 run() 之后挂载
} catch {
    try? logHandle.close()
    throw LaunchError.processStartFailed(reason: "\(executable.path)：\(error.localizedDescription)")
}
```

**改后（与 `MinecraftLauncher` 对齐：先在 run() 前挂观察点，成功路径也显式持有并可关闭句柄）**

```swift
// 在 run() 之前挂载 terminationHandler（消除窄竞态）
process.terminationHandler = { proc in
    // 由 ManagedProcess / 会话层消费；此处仅占位，保证任何退出都有回调
    _ = proc.terminationStatus
}

do {
    try process.run()
} catch {
    try? logHandle.close()      // 失败即关闭
    throw LaunchError.processStartFailed(reason: "\(executable.path)：\(error.localizedDescription)")
}
// 成功路径：把 logHandle 交给 ManagedProcess 持有，在 waitForTermination 完成后 close()
// （官方只保证「传 Pipe 时写端自动关闭」，FileHandle 的关闭时机需应用自己负责）
```

---

### 2.10 【低】内存压力源用 `resume()` 启动、缺 `.normal` 掩码

**官方原文**："The returned dispatch source is **in the inactive state initially**. When you are ready to begin processing events, call its **`activate()`** method."（https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource(eventmask:queue:) ）

**受影响位置**：`App/AppContext.swift:76-84`。

**结论**：`resume()` 实际可用（未找到官方「二者等价」明文 → §5），仅建议改为官方明确指名的 `activate()`；`.normal` 掩码缺失属有意设计（注释已说明），不改。

**改前 → 改后**

```swift
let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
source.setEventHandler { … }
source.resume()                       // 官方文档路径是 activate()
```

```swift
let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
source.setEventHandler { … }
source.activate()                     // 官方指名入口（macOS 10.12+；部署目标 13.0）
```

> 与之相关的**并发/隔离**问题（handler 未指定 queue、handler 内调用 MainActor 隔离方法）属同事手册 §2.8 的范围，本手册不重复。

---

## 3. 窗口尺寸三处不一致的真实优先级与建议统一值

### 3.1 全部相关声明（4 处写入 + 1 处声明性默认尺寸）

| # | 位置 | 内容 | 属性/语义 | 类型 |
|---|---|---|---|---|
| ① | `App/qwqApp.swift:17` | `.frame(minWidth: 800, minHeight: 590)` | 根视图**内容最小尺寸**，经 `.windowResizability` 默认 `.automatic → .contentMinSize` 参与窗口最小尺寸推导 | 内容约束（**最高优先**） |
| ② | `App/AppDelegate.swift:9` | `window.minSize = 800×590` | AppKit 窗口 **frame 最小尺寸**（含标题栏） | 属性写入 |
| ③ | `UI/Modifiers/LauncherWindowModifier.swift:25` | `window.minSize = 800×550` | 同上，**后写** | 属性写入（覆盖 ②） |
| ④ | `App/ContentView.swift:35` | `.frame(minWidth: 800, minHeight: 550)` | 嵌套内容最小尺寸（被 ① 包住，弱于 ①） | 内容约束（无效） |
| ⑤ | `App/AppDelegate.swift:12-20` | `setFrame(900×660)` | 启动默认尺寸 | **死分支**（部署目标 13.0） |

### 3.2 真实优先级结论

依据两条官方明文规则：

- `NSWindow.contentMinSize`："**This method takes precedence over the `minSize` property.**"（https://developer.apple.com/documentation/appkit/nswindow/contentminsize ）
- `Scene.windowResizability(_:)` 默认 `.automatic` 对非 `Settings` 窗口等价于 `.contentMinSize`，且"the strategy the system uses to place minimum and maximum size restrictions on windows that it creates from that scene"，官方示例即「把带约束的 `frame` 应用到 scene 内容」来确定窗口的尺寸范围（https://developer.apple.com/documentation/swiftui/scene/windowresizability(_:)、https://developer.apple.com/documentation/swiftui/windowresizability ）

**排序（从高到低）**：

1. **`contentMinSize`（由 ① 推导）= 800×590** —— 最终生效的窗口最小尺寸。
2. `minSize` 写入：③(550) 覆盖 ②(590) —— **但这只改到了被压过的那个属性**，不改变最终结果（这正是 §2.3 注释因果链不完整之处）。
3. ④（内部的 800×550）被 ① 的 590 完全包含，**不产生任何额外限制**。
4. ⑤（900×660 启动尺寸）**从未执行**，对首帧尺寸零影响。

**直白结论**：三处数值里，**590 才是真实生效值**（来自 `qwqApp.swift:17` 的根视图 `.frame(minHeight: 590)`）；550 是无效写、且注释对它「覆盖 590」的描述给出了错误的因果；900×660 的默认尺寸**根本没生效**。

### 3.3 建议统一值

**统一为 `800×590`**（沿用当前真实生效的最大约束，避免任何可感知的尺寸跳变）：把最小值定义成单一常量，只在 `qwqApp` 的根视图 `.frame(minWidth:minHeight:)` 声明一次，并显式写上 `.windowResizability(.contentMinSize)`；删除 `LauncherWindowModifier.swift:25` 与 `AppDelegate.swift:9` 的 `minSize` 写入（或改写为同值的 `contentMinSize`）；默认启动尺寸用 `.defaultSize(width: 900, height: 660)` 明确声明（见 §2.1 改后代码）。

---

## 4. 一页速查：最易写错的 10 条框架 API 规则

| # | 规则（官方语义） | 一句话判据 | 官方链接 |
|---|---|---|---|
| 1 | `@StateObject` 的初值 autoclosure **只在视图首次创建时执行一次** | 「视图输入变了但对象没变」是预期行为；要重建必须改 view identity（`.id(_:)`），不能在 `init` 里重赋值 | https://developer.apple.com/documentation/swiftui/stateobject |
| 2 | `@ObservedObject` **不要给初值**，它是「输入」不是「存储」 | 若对象无人持有（生命周期不由视图持有），视图会静默停止更新；自己创建的对象必须用 `@StateObject` | https://developer.apple.com/documentation/swiftui/observedobject |
| 3 | `@Observable` 类型只能用 `@State`/`@Environment`/`@Bindable` | 给 `@Observable` 套 `@ObservedObject` **会编译报错**；`@State` 不能存 `ObservableObject` 并期望 published 更新 | https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro |
| 4 | `.task` 的**生命周期 = 视图生命周期**（视图消失或 identity 变化即取消）；`.onAppear` **没有任何取消机制** | 需要「视图没了就停」的工作（轮询、等待、订阅）一律用 `.task(id:)`；`onAppear` 只做一次性副作用 | https://developer.apple.com/documentation/swiftui/view/task(name:priority:file:line:_:) |
| 5 | `ZStack` **后面的子视图在上层**；`zIndex` 默认 `0`，只用于同层兄弟之间 | 「谁盖住谁」先看声明顺序，再看 `zIndex`；交换声明顺序即等于换层 | https://developer.apple.com/documentation/swiftui/zstack |
| 6 | `.overlay` **叠在前面且不影响原视图布局**；集合中的多个视图按「从后到前」排列 | 需要「不挤压布局的浮层」用 `overlay`；需要「共同参与布局」用 `ZStack` | https://developer.apple.com/documentation/swiftui/view/overlay(alignment:content:) |
| 7 | `NSWindow.contentMinSize` **优先于 `minSize`**；`minSize` 含标题栏；`setFrame(_:display:)` **绕过**两者 | 想限制「内容区」最小尺寸就设 `contentMinSize`；用 `minSize` 会被 SwiftUI 的内容约束压过 | https://developer.apple.com/documentation/appkit/nswindow/contentminsize |
| 8 | `NSApp.windows` **顺序无保证**且**包含屏幕外窗口** | 任何 `NSApp.windows.first` 都是不确定性写法；应按 `identifier` / `mainWindow` / `keyWindow` 定位 | https://developer.apple.com/documentation/appkit/nsapplication/windows |
| 9 | `Pipe` 作为 `standardOutput`：**launch 会自动关闭当前进程持有的写端**（传 `fileHandleForWriting` 则不会）；EOF 前必须先排空管道再置 `readabilityHandler = nil` | 「先解绑 handler 再关句柄」会丢管道尾部数据；`read(upToCount:)` 到 EOF 返回**空 Data（不是 nil）**，循环条件必须判 `isEmpty` | https://developer.apple.com/documentation/foundation/process/standardoutput、https://developer.apple.com/documentation/foundation/filehandle/readabilityhandler |
| 10 | `Process.waitUntilExit()` **阻塞当前线程并空转当前 runloop**，且**不保证** `terminationHandler` 已执行完 | 主线程禁用；要等退出用 `terminationHandler` + 信号量/轮询，不要用 `waitUntilExit` 收尾 | https://developer.apple.com/documentation/foundation/process/waituntilexit() |

**附加 3 条（同属高频错误）**

| # | 规则 | 判据 | 链接 |
|---|---|---|---|
| 11 | `.onDrop` 的 action 闭包内必须**同步启动** `NSItemProvider` 的加载；payload 只在闭包返回前可访问 | 把 `loadItem` 丢进 `Task {}` 里再调用，属于违规（必须先把调用发起） | https://developer.apple.com/documentation/swiftui/view/ondrop(of:istargeted:perform:) |
| 12 | `onChange(of:perform:)` 单参数形式已弃用，且**新旧语义不同**（旧=变更前状态，新=变更后状态） | 迁移不是改签名，闭包内读其它状态的每处都要复验 | https://developer.apple.com/documentation/swiftui/view/onchange(of:perform:) |
| 13 | `DispatchSource` 创建后处于 **inactive**，必须 `activate()`；释放前应 `cancel()` | 忘了 activate → handler 永不触发；忘了 cancel → 释放行为未定义 | https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource(eventmask:queue:) |

---

## 5. 未找到官方依据 / 存疑项汇总

| # | 事项 | 状态 | 说明 |
|---|---|---|---|
| Q1 | `Scene.defaultSize(width:height:)` 的正文（可用性、生效条件） | **页面正文未能抓取** | 官方页面为 JS 渲染，WebFetch 仅取到页面外壳。可用性按 SDK/部署目标 13.0 记录为 macOS 13.0+，但「何时被忽略」等细节无原文可引 → §2.1 的改法属推荐形态，落地前建议在 Xcode 内查证该 API 的 Quick Help |
| Q2 | `ViewBuilder` 单 closure 子视图数量上限（历史为 10） | **官方当前页面无明文** | 页面 Topics 仅列 `buildBlock()` / `buildBlock(_:)`。项目未触碰该上限，暂不影响编译 |
| Q3 | `ViewBuilder` 中 `switch` 的展开方式 | **官方页面未列** | 官方 Topics 只有 `buildEither(first:/second:)` 与 `buildIf(_:)`；`switch` 由编译器展开为嵌套 `buildEither`，项目未使用 `switch` 于 ViewBuilder |
| Q4 | `SwiftUI App` 场景下 `NSApp.windows` 在 `applicationDidFinishLaunching` 时刻是否已含主窗口 | **无官方明文** | `applicationDidFinishLaunching` 文档只说「初始化完成、尚未收到首个事件」；`NSApplication.windows` 只说「当前存在的窗口，顺序无保证」。项目 `guard let window = NSApp.windows.first else { return }` 的失败路径（返回 nil → 静默跳过全部窗口配置）无官方保证 |
| Q5 | `onAppear` 与 `applicationDidFinishLaunching` 的先后顺序 | **无官方明文** | `LauncherWindowModifier.swift:8-10` 的「onAppear 在 didFinishLaunching 之后」是工程实测结论。结论本身与实测一致，但换 SDK/系统版本后不应假设不变 |
| Q6 | `connectionProxyDictionary = [:]` = 「禁用一切代理」 | **无官方明文** | 官方仅定义 `nil` = 使用系统默认设置。空字典语义属未文档化行为（§2.7） |
| Q7 | 「`requiringSecureCoding: false` 归档 + `unarchivedObject(ofClass:)` 解档」跨版本是否恒可用 | **无官方明文** | `NSKeyedUnarchiver` 页面正文未能抓取到相关条款；`unarchivedObject(ofClass:from:)` 页面同样为 JS 渲染。改为 `true` 可消除不确定性（§2.4） |
| Q8 | `terminationHandler` 的执行线程/队列 | **无官方明文** | 文档只写「system invokes when the task completes」，未承诺线程。项目不依赖线程假设（只做 `signal` + 门控 + `DispatchQueue.main.async`），因此安全 |
| Q9 | 管道缓冲大小（约 64KB）导致子进程阻塞的阈值 | **官方只写「由 OS 决定」** | `Pipe` 页面："the size of the buffer is determined by the underlying operating system"。项目注释中的 64KB 属经验值 |
| Q10 | `readabilityHandler` 的具体执行队列（是否文件句柄私有串行队列） | **官方未指名队列** | 官方只写 "submitted to the file handle's dispatch queue"；项目加锁防御是必要且正确的 |
| Q11 | `DispatchSourceProtocol.resume()` 与 `activate()` 是否等价 | **无官方明文** | `activate()` 页面正文为空（仅签名），`makeMemoryPressureSource` 页面只提 `activate()`。项目用 `resume()` 实测可用（§2.10） |
| Q12 | 「视图更新期间修改 `@Published` 会告警」 | **无官方明文** | `NoticeOverlay.swift:27` 注释所述告警是工程实践观察；项目用 `DispatchQueue.main.async` 推迟的写法无害 |
| Q13 | `NSImage.lockFocus/unlockFocus` 是否属弃用 | **官方页面未标注弃用** | 属遗留绘图 API，新代码推荐 `NSImage(size:flipped:drawingHandler:)`，但不列为风险 |
| Q14 | 对非安全归档调用 `unarchivedObject(ofClass:from:)` 是否抛 `invalidUnarchiveOperationException` | **无官方明文** | `NSKeyedUnarchiver` 页面只说明「类型强制转换不兼容时抛异常」，未涉及安全编码标记不匹配的情形 |

---

## 6. 官方文档索引（本次核对实际抓取过的页面）

### SwiftUI · 状态管理
- StateObject — https://developer.apple.com/documentation/swiftui/stateobject
- ObservedObject — https://developer.apple.com/documentation/swiftui/observedobject
- EnvironmentObject — https://developer.apple.com/documentation/swiftui/environmentobject
- State — https://developer.apple.com/documentation/swiftui/state
- 迁移到 Observable 宏 — https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro

### SwiftUI · App / Scene / ViewBuilder
- App（`@main` 唯一性）— https://developer.apple.com/documentation/swiftui/app
- NSApplicationDelegateAdaptor — https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor
- Scene.windowResizability(_:) — https://developer.apple.com/documentation/swiftui/scene/windowresizability(_:)
- WindowResizability — https://developer.apple.com/documentation/swiftui/windowresizability
- Scene.defaultSize(width:height:)（正文未抓取到）— https://developer.apple.com/documentation/swiftui/scene/defaultsize(width:height:)
- WindowStyle.hiddenTitleBar — https://developer.apple.com/documentation/swiftui/windowstyle/hiddentitlebar
- ViewBuilder — https://developer.apple.com/documentation/swiftui/viewbuilder

### SwiftUI · 修饰器与动画
- ZStack — https://developer.apple.com/documentation/swiftui/zstack
- zIndex(_:) — https://developer.apple.com/documentation/swiftui/view/zindex(_:)
- overlay(alignment:content:) — https://developer.apple.com/documentation/swiftui/view/overlay(alignment:content:)
- frame(minWidth:…) — https://developer.apple.com/documentation/swiftui/view/frame(minwidth:idealwidth:maxwidth:minheight:idealheight:maxheight:alignment:)
- onDrop(of:isTargeted:perform:) — https://developer.apple.com/documentation/swiftui/view/ondrop(of:istargeted:perform:)
- onChange(of:perform:)（弃用）— https://developer.apple.com/documentation/swiftui/view/onchange(of:perform:)
- task(name:priority:file:line:_:) — https://developer.apple.com/documentation/swiftui/view/task(name:priority:file:line:_:)
- onAppear(perform:) — https://developer.apple.com/documentation/swiftui/view/onappear(perform:)
- withAnimation(_:_:) — https://developer.apple.com/documentation/swiftui/withanimation(_:_:)
- Transaction — https://developer.apple.com/documentation/swiftui/transaction
- Animation.spring(response:dampingFraction:blendDuration:) — https://developer.apple.com/documentation/swiftui/animation/spring(response:dampingfraction:blendduration:)
- matchedGeometryEffect(id:in:…) — https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:)
- Color.init(nsColor:) — https://developer.apple.com/documentation/swiftui/color/init(nscolor:)

### AppKit
- NSApplicationDelegate.applicationDidFinishLaunching(_:) — https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationdidfinishlaunching(_:)
- NSApplication.windows — https://developer.apple.com/documentation/appkit/nsapplication/windows
- NSWindow.minSize — https://developer.apple.com/documentation/appkit/nswindow/minsize
- NSWindow.contentMinSize — https://developer.apple.com/documentation/appkit/nswindow/contentminsize
- NSWindow.titlebarAppearsTransparent — https://developer.apple.com/documentation/appkit/nswindow/titlebarappearstransparent
- NSColor（NSCoding / NSSecureCoding 一致性）— https://developer.apple.com/documentation/appkit/nscolor

### Foundation · 进程与文件句柄
- Process（单实例只能 run 一次；沙箱告警）— https://developer.apple.com/documentation/foundation/process
- Process.standardOutput（Pipe 写端自动关闭）— https://developer.apple.com/documentation/foundation/process/standardoutput
- Process.terminationHandler — https://developer.apple.com/documentation/foundation/process/terminationhandler
- Process.waitUntilExit() — https://developer.apple.com/documentation/foundation/process/waituntilexit()
- Pipe — https://developer.apple.com/documentation/foundation/pipe
- FileHandle.readabilityHandler — https://developer.apple.com/documentation/foundation/filehandle/readabilityhandler
- FileHandle.read(upToCount:)（EOF 返回空 Data）— https://developer.apple.com/documentation/foundation/filehandle/read(uptocount:)

### Foundation · 归档 / 网络 / 文件系统 / 派发源
- NSKeyedArchiver — https://developer.apple.com/documentation/foundation/nskeyedarchiver
- NSKeyedUnarchiver（正文未抓取到）— https://developer.apple.com/documentation/foundation/nskeyedunarchiver
- URLSessionConfiguration.timeoutIntervalForResource — https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforresource
- URLSessionConfiguration.httpMaximumConnectionsPerHost — https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpmaximumconnectionsperhost
- URLSessionConfiguration.connectionProxyDictionary — https://developer.apple.com/documentation/foundation/urlsessionconfiguration/connectionproxydictionary
- URLSessionConfiguration.httpShouldUsePipelining — https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpshouldusepipelining
- URLSessionConfiguration.urlCache — https://developer.apple.com/documentation/foundation/urlsessionconfiguration/urlcache
- FileManager.urls(for:in:) — https://developer.apple.com/documentation/foundation/filemanager/urls(for:in:)
- Data.write(to:options:) — https://developer.apple.com/documentation/foundation/nsdata/write(to:options:)
- NSItemProvider.loadItem(forTypeIdentifier:options:completionHandler:)（弃用）— https://developer.apple.com/documentation/foundation/nsitemprovider/loaditem(fortypeidentifier:options:completionhandler:)
- DispatchSource.makeMemoryPressureSource(eventMask:queue:) — https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource(eventmask:queue:)
- DispatchSource.MemoryPressureEvent — https://developer.apple.com/documentation/dispatch/dispatchsource/memorypressureevent
- DispatchSourceProtocol.activate() — https://developer.apple.com/documentation/dispatch/dispatchsourceprotocol/activate()
- DispatchSourceProtocol.cancel() — https://developer.apple.com/documentation/dispatch/dispatchsourceprotocol/cancel()

---

## 7. 附：本次核对涉及的项目文件与统计

### 7.1 逐字阅读的文件

| 文件 | 命中 API 域 |
|---|---|
| `qwq/App/qwqApp.swift` | App/Scene、`@NSApplicationDelegateAdaptor`、`.windowStyle`、根视图 frame |
| `qwq/App/AppDelegate.swift` | `NSApplicationDelegate`、`NSWindow.minSize/styleMask/setFrame`、`NSImage.lockFocus` |
| `qwq/App/ContentView.swift` | `@StateObject`/`@ObservedObject`/`@EnvironmentObject`、`ZStack`、`overlay`、`onDrop`、`onChange`、`alert`、`onAppear`、`DragGesture`、`withAnimation` |
| `qwq/App/AppContext.swift` | `URLSessionConfiguration` 三项、`FileManager.urls`、`DispatchSource.makeMemoryPressureSource` |
| `qwq/App/ViewModels/NavigationState.swift` | `@MainActor + ObservableObject`、`objectWillChange` 转发、spring 曲线 |
| `qwq/App/ViewModels/LaunchPanelState.swift` | ObservedObject 透传转发 |
| `qwq/App/ViewModels/DropInstallCoordinator.swift` | `onDrop` 返回语义、`ObservableObject` |
| `qwq/Services/DragDropHandler.swift` | `NSItemProvider.loadItem`（弃用） |
| `qwq/UI/Modifiers/LauncherWindowModifier.swift` | `ViewModifier`、`onAppear` 写窗口属性 |
| `qwq/UI/Shell/RootOverlays.swift` | `ZStack` + `zIndex` 层级链、`allowsHitTesting` |
| `qwq/UI/Notices/NoticeOverlay.swift` | `.task(id:)`、`.animation(value:)`、`transition`、`onAppear/onDisappear` |
| `qwq/UI/Notices/NoticeCenter.swift` | `@Published`、`withCheckedContinuation`（并发部分见同事手册） |
| `qwq/UI/AnimationExtensions.swift` | `Animation.spring` / `interpolatingSpring` 参数 |
| `qwq/Features/Settings/AppSettingsStore.swift` | `@Published + didSet`、`NSKeyedArchiver` 归档 |
| `qwq/Features/Settings/ThemeManager.swift` | 同上（`ThemeManager` + `LauncherSettings`） |
| `qwq/Features/Launch/Adapters/ProcessPoolGameProcessController.swift` | `Process` 长驻进程、FileHandle 直写 |
| `qwq/PCLCore/Minecraft/Launch/MinecraftLauncher.swift` | `Process` + `Pipe` + `readabilityHandler` + 排空顺序 + 自实现等待 |
| `qwq/PCLCore/Download/NetDownloader.swift`（只读） | `URLSession.bytes(for:)`、`FileHandle` 读写、`FileManager`、`URLCache` 语义 |
| `qwq/PCLCore/Utils/Requests.swift` | 直连 `URLSession` 配置三项 |

### 7.2 全库统计（grep，用于判断影响面）

| 项 | 数量 | 备注 |
|---|---|---|
| `@main` | 1 | 唯一入口 |
| `@StateObject` | 7 | 其中 1 处指向单例（`ContentView.swift:6`） |
| `@ObservedObject` | 41 | 其中 **35 处带 `= .shared` 初值**（官方不建议），含 `ThemeManager.shared` 27 处 |
| `@EnvironmentObject` | 5 | 全部由 `ContentView.swift:39` 注入 |
| `@Observable`（宏） | 0 | 未采用 Observation |
| `.onChange(` 单参数形式 | 17 | macOS 14+ SDK 下弃用 |
| `NSApp.windows.first` | 3 | 官方明文顺序无保证 |
| `NSKeyedArchiver … requiringSecureCoding: false` | 2 | 建议改 `true` |
| `waitUntilExit()` | 0 | 已完全规避 |
| `matchedGeometryEffect` | 0 | 未使用 |
| `AnyView` | 0 | 无类型擦除代价问题 |

### 7.3 与同事手册的分工边界

| 主题 | 归属 |
|---|---|
| `Task`/`actor`/`Sendable`/续体/锁/信号量、默认 MainActor 隔离 | `docs/SWIFT_LANGUAGE_CHECKLIST.md` |
| SwiftUI 数据流与视图生命周期语义、修饰器与层级、动画参数、AppKit 窗口与归档、Foundation 进程/管道/网络/文件/派发源 | **本手册** |
| `AppContext` 内存压力源：源本身的创建/激活/取消语义（本手册 §1.7 F10–F12、§2.10）；handler 的队列与隔离违反（同事手册 §2.8） | 交叉引用，不重复 |

---

## 8. 本次核对的边界声明

1. **未修改 `qwq/` 下任何源码**：本手册新增文件位于 `docs/`，所有问题只记录、只给建议改法。
2. **未执行任何 git 写操作**（无 `commit` / `checkout` / `push`）。
3. **未运行 `xcodebuild`**（被沙箱拦截），也未运行 `swiftc -typecheck`（同事已在语言侧执行，结果见其手册 §0.1）；本手册的结论全部来自「源码逐字阅读 + 官方文档原文比对」。
4. 所有「有风险 / 错误」条目均已给出官方链接；所有「存疑」条目集中在 §5，未以猜测替代官方依据。
