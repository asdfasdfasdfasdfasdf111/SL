# 交接文档（HANDOVER）

> 面向**第一次接手这个仓库的人**（也包括几个月后的你自己）。
> 目标：30 分钟内能跑起来、知道改动该怎么验、不踩已经踩过的坑。
>
> **本文不重复其他文档的内容**，分工如下：
>
> | 文档 | 回答什么问题 |
> |---|---|
> | **HANDOVER.md（本文）** | **怎么上手、怎么验、坑在哪** |
> | `README.md` | 这是什么应用、功能状态、怎么构建、给用户看 |
> | `ARCHITECTURE.md` | **当前真实存在**的结构与分层（不写目标结构） |
> | `REFACTOR_PLAN.md` | 重构的**计划与历史**（做到哪了、还剩什么；部分内容已成历史） |
> | `docs/MODULE-INVENTORY.md` | ⚠️ **2026-10 起部分过期**：其中的 `Module/` 模块内核盘点已作废（该体系已删除，见 `ARCHITECTURE.md` §三） |
> | `qwqTests/TESTING.md` | 测试**怎么跑、覆盖了什么、哪些没覆盖** |
> | `CHANGELOG.md` | 每一轮改了什么、为什么（2026-10 起冻结，不再手写新条目） |
> | `qwq/SLCore/STUBS_AUDIT.md` | 哪些是桩实现、哪些看着像桩其实是真代码 |
>
> 基线（2026-10-02）：`qwq/` 下 **237 个 Swift 文件 / 约 31,000 行**，测试 **57 个文件**。
> 文件数与行数会随每次改动漂移，复核用 `find qwq -name '*.swift' | wc -l`；用例数以 CI 为准
> （`.github/workflows/test.yml`）。

---

## 一、30 秒跑起来

```bash
git clone https://github.com/asdfasdfasdfasdfasdf111/SL.git
cd SL
open qwq.xcodeproj        # Xcode 里 ⌘R
```

命令行构建：

```bash
xcodebuild -project qwq.xcodeproj -scheme qwq -configuration Debug build
```

**关键配置**（改代码前必须知道，见 `project.pbxproj`）：

| 项 | 值 | 为什么重要 |
|---|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | **13.0** | 用 macOS 14+ 的新 API 会编译不过；`onChange(of:initial:_:)` 这类要 14 的**不能用** |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | **MainActor** | 没标注的声明**默认被推断为主 actor 隔离**，这会影响测试写法（见 §三） |
| `SWIFT_VERSION` | 5.0 | 语言模式是 5，不是 6；但部分诊断会提示「Swift 6 下是错误」 |
| 测试宿主 | `TEST_HOST = qwq.app/Contents/MacOS/qwq` | **测试进程里 `UserDefaults.standard` 就是用户真实偏好域**（见 §三末） |

### 无人值守启动一次游戏（验证启动链用）

AI 会话里点不到按钮（无辅助功能权限），所以有个仅 DEBUG 的开关：

```bash
SL_DEBUG_AUTO_LAUNCH=1 SL_DEBUG_AUTO_LAUNCH_DELAY=4 \
  <derived>/Build/Products/Debug/qwq.app/Contents/MacOS/qwq
```

⚠️ **必须直接跑二进制**（不要 `open`），否则环境变量传不进去。
它调的是 `LaunchCoordinator.start(settings:sessionManager:)` —— 与点按钮**同一条路径**。

---

## 二、项目地图

```
qwq/
├── App/           13 文件  应用入口、装配根、窗口壳、App 级组件（ContentView 等）
├── Core/          12 文件  跨功能领域抽象：Download 引擎门面 / Events
├── Features/     118 文件  按功能划分（最大的一块）
│   ├── Download/ Launch/ Game/ ModBrowser/
│   └── Java/ Settings/ Skin/ Theme/ Translation/
├── SLCore/        80 文件  原生重写的启动核心（下载 / 安装 / 启动 / 加载器 / 账号 / 存储）
├── UI/            13 文件  Notices / Shell / Modifiers 等公共 UI
├── Models/         1 文件  纯数据模型（GameModels 等）
└── qwqTests/      57 文件  单元测试（目录自动同步，新增 .swift 会自动进 target）
```

**从哪读起**（按推荐顺序）：

1. **`qwq/App/AppCompositionRoot.swift`** —— 装配根。整个应用启动时注册了什么，看这一个文件就够。
   入口是 `registerRuntimeServices()`，`SLApp.init()` 里只留一行调用。
2. **`qwq/App/ContentView.swift`** —— 窗口壳，能看出界面由哪几个大类目组成。
3. **`qwq/SLCore/SLLaunchBridge.swift`** —— **新旧世界的接缝**。这是重构中最关键的兼容层：
   上层的 `LaunchCoordinator`（新）通过它驱动下层的原生启动核心。
   启动链的两个「取消」概念都汇在这里（见 §四）。
4. **`qwqTests/TESTING.md`** —— 读它比读代码更快地知道「哪些行为已被钉住、哪些还是裸的」。

---

## 三、改代码前必读：验证纪律

这个项目**最贵的一课**是「类型检查通过 ≠ 编译得过 ≠ 行为正确」。三级阶梯，**不可互相替代**：

| 级别 | 命令 | 用途 | 耗时 |
|---|---|---|---|
| 1 | `./scripts/typecheck.sh` | 两口径类型检查，**必须都是 0 错误** | 秒级 |
| 2 | `./scripts/verify-build.sh` | 真实 `xcodebuild`，**最终判定**；日志 `/tmp/sl_build.log` | ~30s |
| 3 | `./scripts/verify-test.sh run` | 单元测试（会启动 qwq.app 作宿主） | ~1min |

### 三个必须知道的陷阱

**① `typecheck.sh` 会漏整类错误。** 它用裸 `swiftc -typecheck` 模拟编译，但有两类诊断它发不出来：

- 闭包捕获同一作用域里**后声明**的 `let`（诊断由 SILGen 发出）
- **逃逸闭包捕获非 `@escaping` 的参数** —— 两口径**完全静默**，真实编译才报错
  （给函数加「可注入闭包参数」时高频踩到；⚠️ 标 `@MainActor` / `@Sendable` 都**不改变逃逸性**）

⇒ **给任何函数加闭包参数之后，必须跑真实编译。**

**② 判定标准是「告警集合逐条 diff」，不是比数字。** 因为：

- 口径一有个**脚本产物**：它把 `qwq` 与 `qwqTests` 编进同一模块，于是每个测试文件的
  `@testable import qwq` 都会产生一条 `ignoring import` 告警，**每加一个测试文件 +2**。
- **有编译错误时后续文件的告警会被吞掉**，所以「告警数变少」可能是被短路了，不是变好。
- 裸 `grep -c 'error:'` 会把源码上下文行也计进去。

**当前基线：口径一 0 错 / 57 条唯一告警（2026-10-02），口径二 0 错 / 12 条唯一告警。**
口径一的 57 = 56 条「ignoring import」脚本产物（= 测试文件数）+ 1 条真实告警
（`NoticeCenterTests` 的 Sendable 捕获）；口径二的 12 条全是真实告警。
上限即「基线值」，任何真实告警新增都会让 typecheck 红线失败（具体见 `scripts/typecheck.sh` 注释）。
复核方式（只读，安全）：

```bash
git archive HEAD | tar -x -C /tmp/base   # 导出 HEAD 做对照
# 分别跑 typecheck，把 warning 行归一化（去掉行列号）后 sort 再 diff
```

⚠️ **不要用 `git stash` 做对照** —— 沙箱内会留下 0 字节 `.git/index.lock`，后续提交全废。

**③ `verify-build.sh` 不编测试 target。** 改了 `qwqTests/*.swift` 必须**另外**跑
`verify-test.sh`（不带 `run` 就只编译不运行）。

### 测试的两个硬规矩

**用例一律写成 `async`。** 同步用例里创建并释放 `@MainActor` 类实例 → 宿主 **100% abort**
（`malloc: pointer being freed was not allocated`）、XCTest 无限重启。这是 Xcode 26.2 的
工具链缺陷（上游 `swiftlang/swift#87422`），与本工程逻辑无关。
**不要**给每个类加 `nonisolated deinit {}`，也**不要**关掉 `SWIFT_DEFAULT_ACTOR_ISOLATION`
（后者编译 0 报错但隔离会静默失效）。

**测试套件有约 1/4 概率 abort。** 该缺陷还有第二个触发面（嵌套隔离析构），发生在**真实启动路径**里，
表现为在 `LaunchCancellationTests` 处崩。**实测：工作区与 HEAD 导出副本都是 3 通 1 崩**
⇒ **单次 abort 不能判定代码有问题**，要定性必须**同一命令在 HEAD 上对照跑**。
abort 之后**换全新的 `SL_DERIVED`**（旧派生目录会退化，`build-for-testing` 也修不回来）。

**测试进程写的是用户真实 `UserDefaults`。** 因为 `TEST_HOST` 就是 `qwq.app`，bundle id 与正式版相同。
⇒ 涉及 `AccountManager.shared` 这类会**回写**的代码，测试里不要驱动它
（参考 `qwqTests/AccountPersistenceCompatTests.swift` 的做法：只读真实键 + 断言不碰）。

### 反向验证：别问「这条还绿吗」，去删一次

断言写完不算完，必须构造「该被拦住」的条件，确认它**真的会红**，且**红得精确**
（一条性质只由一条具名用例守卫）。做法：临时破坏被测代码 → 跑 → 还原 → 确认零残留标记。
⚠️ 还原后**必须重新 `build-for-testing`**：`test-without-building` 会拿旧二进制跑出**假失败**。

### 改动规模上限（硬规矩）

**超过约 15 个文件 / 200 行就停下来问。** 这个上限来自一次真实事故：
一次改 29 文件 / +363−218，被判定「能跑但不如之前」，整批还原重做。

判据三条**缺一不可**：① 真会出问题 ② 修法**局部** ③ 有**硬依据**。不全 → 只列清单，不动手。
**发现与修复分离**：先交清单，点了才改。

---

## 四、踩过的坑（避免重犯）

### 编译 / 构建

| 坑 | 现象 | 教训 |
|---|---|---|
| 拆分丢 `import` | 裸 typecheck 报 0 错误，真实编译报 5 个 error | `import` 是**按文件**生效的；行比对查不出这类问题（那行还在别的文件里），**只有编译器能查** |
| 并行任务抢派生目录 | 并发跑 xcodebuild 互相破坏中间产物 | 各自用 `SL_DERIVED=/tmp/SL-DD-<任务名>` |
| 沙箱内跑 git 写操作 | 留下 0 字节 `.git/index.lock` | 出现时在沙箱外 `rm -f .git/index.lock` |

### 测试 / 验证

| 坑 | 现象 | 教训 |
|---|---|---|
| 断言读**进程级状态** | 单例 / `static var` / 订阅条数被先前用例污染 → 假绿 | 无重置接口的一律断言**差值**，收尾还原成进程启动态 |
| 被测代码有**按环境早退**的分支 | 测试恰好跑在该环境里 → 整段真实路径从未执行 | 把调用环境变成**显式选择**的入口，并把环境前提钉成断言 |
| 同步用例 | 宿主 abort、无限重启 | 一律 `async`（见 §三） |
| 沙箱内跑 XCTest | `The test runner hung before establishing connection` | 宿主型 XCTest 依赖 testmanagerd 的 XPC，**AI 沙箱内跑不了**；编译可以在沙箱内完成，运行要在 Terminal |

### 环境

| 坑 | 现象 | 教训 |
|---|---|---|
| 命令行工具不读系统代理 | `github.com` 直连返回 `000` | push 必须显式：`git -c http.proxy=http://127.0.0.1:12001 push …` |
| `screencapture` 无屏幕录制权限 | 命令成功、图片 4.5MB，但内容是**桌面壁纸** | 不能用它验证 UI；UI 只能靠代码审查 + 肉眼 |
| `CGEvent.postToPid` 绕权限 | 投递无报错，但按钮毫无反应 | 鼠标事件基本不生效；要无人值守跑启动用 `SL_DEBUG_AUTO_LAUNCH=1` |

---

## 五、关键架构事实（动手前先看这几条）

- **装配根**：入口 = `App/AppCompositionRoot.swift` 的 `registerRuntimeServices()`，
  `SLApp.init()` 只留一行。`didRegisterRuntimeServices` 是**单调标志**，唯一置位点在入口最后一行。
  ⚠️ 三个成员的**重复调用语义不一致**：`CrashReporter.install()` ✅ 幂等、
  `MemoryCacheReclaimer.register()` ✅ 幂等、**`LocalModCatalog.warmUp()` ❌ 不幂等**
  （置位前重复调用会再起一个预热任务）。

- **启动链的两个「取消」不可互相替代**：
  - `MinecraftLauncher.isUserTerminated` + `terminate()` = 「进程已起、要终止」
  - `LaunchCancellationToken`（`SLLaunchBridge.swift`）= 「进程没起、别起了」
    （准备阶段取不到 launcher）。5 处判定点统一以 `LaunchError.cancelled` 收口。
  - ⚠️ 令牌**每次新建**，挂在 `LaunchSessionManager` 上；
    **不要**塞进 `LaunchRequest`（那是 `Equatable` 值类型）。
  - UI 判「用户取消」看**令牌本身**，不看错误文案。

- 🧨 **游戏实例扫描有写副作用**：`MinecraftVersionManager.getVersions` →
  `normalizeVersionFolderNames` **会重命名磁盘上的真实版本目录并改写其中的 json**
  ⇒ **测试绝不要驱动真实扫描**。

- **皮肤尺寸**：Java 版**原版**上限就是 **64×64**（128 是基岩版）→ 原版可用只有 64×64 / 64×32。
  ⚠️ 但**高清皮肤是支持的**，走另一条路：`SkinHDSupport` 做**纯逻辑尺寸分类**（三分支）——
  原版可用 / 合法整倍数（128×128、256×256…，归为 `needsPatch`）/ 根本不该接受（非整倍数、自造尺寸）。
  第二类会弹卡片询问是否装 **CustomSkinLoader**（「万用皮肤补丁」）。
  ⚠️ 取景坐标按 64×64 写死 ⇒ **降采样之后**才能进裁剪，不能把高清图直接喂进去。
  最易误放行的是 **`128×32`**（长宽不成对）。分类规则与白名单**两处必须同步**。

- **部署目标孤儿**：清理时扫描**两个方向** —— `#available(macOS 13…)`（恒真的 else）
  **和** `#unavailable(macOS 13…)`（恒假的块整段不执行）。

- **Modrinth**：官方 `api.modrinth.com` 与国内镜像 `mod.mcimirror.top` **不可互换**
  （官方能用是因为本机开着代理）。**改超时或改接口都属行为变更**。

- **账号持久化**：磁盘 JSON 形状 = `[{"offline":{"_0":{"id,uuid,name}}}]`，
  由 Swift 合成 Codable 决定（case 名即键、`_0` 为关联值键）。
  ⚠️ 键序**不稳定**（数组 vs 单值不同）⇒ 断言只比结构。
  契约已被 `qwqTests/AccountPersistenceCompatTests.swift` 钉死 —— 动账号模型前先读它。

---

## 六、当前状态与下一步

**已完成**（详见 `REFACTOR_PLAN.md`、`ARCHITECTURE.md` 与 `git log`）：
模块骨架、装配根收口、`Stubs.swift` 按职责拆分（`Notices/`、`Storage/`、`Account/`
等，原文件已删除）、双启动流程合并（`MinecraftInstance.launch()` 流程 A 已删除，
收敛到 `slLaunchInternal` 单一流程）、`AnyAccount` 持久化契约前置用例、
D1–D9 九条缺陷关闭、失败分类结构化（去掉中文文案反猜与假进度分母）、
`LaunchFix` 拆分接线、VersionUtils 规范化隔离、注释文化末轮收口。

**待办（剩余实义项很少）**：

| # | 事项 | 状态 |
|---|---|---|
| ① | CI 首次实跑 | 🧱 workflow 文件（`test.yml` / `probe.yml`）已就位，但**尚未在 CI 上实际跑过**（本地无网络出口验证 runner 环境）。启用前先手动触发 `probe.yml` 看清 runner 的 Xcode 版本，再依赖门禁 —— 否则「绿在本地、红在 CI」 |
| ② | `AnyAccount` 模型分层 | **已决：保持现状**（SLOP-AUDIT REV3 C）。枚举形状保留为兼容历史持久化数据解码，运行期经 `unimplementedError` 显式告警；实现 OAuth 属新功能，超出当前范畴。仅存的未知是 `getAccount()` 回写分支无覆盖（与 ③ 同类） |
| ③ | 已知覆盖缺口 | 装配根幂等门无用例、`ModDragInstaller.findInstances` 匹配规则、`AccountManager.getAccount()` 回写分支、`NoticeCenter` 300s 兜底超时（登记在 `qwqTests/TESTING.md`，属有意延后，非遗漏） |

**长期保留项（勿动）**：`GameSessionStore` 待接线、纯协议三件、`gameSubCategory`
中文 rawValue、`filter` 死字段删留（详见 `ARCHITECTURE.md` §十处置记录）。

---

## 七、不要做什么

- **不做**：动态 `.bundle` 加载、`NSClassFromString`、XPC、插件市场、`Plugin.json` 清单
- **不实现**：微软登录 / Yggdrasil 登录（本轮范围外，只做「不再假装支持」）
- **不新增功能**：主题、多目录、新动画一律冻结
- **不做**「顺手一起改」：删死代码 /「现代化」换 API 一律不做
- **不做**注释性产出：注释不是产出，改动要有硬依据
