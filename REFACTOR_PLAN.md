# SL 重构计划表

> 分支：`refactor/modular`（项目本地副本 `~/Downloads/Swim111Launcher_副本`）
> 备份：你的 61 个维护改动在 `backup/local-wip-20260920`
> 验证手段：`xcodebuild` 在本机被系统沙箱拦截，统一使用全量类型检查代替
> ```
> cd ~/Downloads/Swim111Launcher_副本
> xcrun swiftc -typecheck -target arm64-apple-macosx13.0 -I /tmp/deps $(find qwq -name "*.swift")
> ```
> 判定标准：exit=0 且 `grep -c "error:"` 为 0

---

## 一、已完成

| # | 事项 | 提交 | 关键产出 | 风险 |
|---|---|---|---|---|
| 1 | 模块内核 | `35d9a61` | `SLModule` / `ModuleContext`（引用类型）/ `ModuleRegistry` / `AppModuleBootstrap` | 低 |
| 2 | 设置层收口 | `35d9a61` | `AppSettingsStore` 成为唯一存储点，复用原有 `UDK` 键名 | 低 |
| 3 | Java 模块 + 接线 | `35d9a61` `b281217` | 统一模型 / `JavaResolver` / `JavaResolverBridge`（同步桥接） | 中 |
| 4 | 下载模块抽象 + 适配器 | `c265f10` | 12 个领域文件 + 3 个适配器 + `MIGRATION.md` | 低 |
| 5 | 下载调用方切换 | `608803b` `364a087` | `ModFileDownloadTask`、`ForgeInstaller`（2 处） | 中 |
| 6 | 启动模块骨架 + 适配器 | `a5b5b19` | 10 个领域文件 + 3 个适配器 + `DUAL_FLOW.md` | 低 |
| 7 | 四模块骨架 | `f2a73fc` `4c631cb8` | ModBrowser / Minecraft / Skin / Theme（22 个文件） | 低 |
| 8 | 伪实现治理 | `f2a73fc` | `AccountError`、`AnyAccount` 明确标注未实现、`STUBS_AUDIT.md` | 低 |
| 9 | **提示通道修复** | `f2a73fc` | `NoticeCenter` + `NoticeOverlay`，修复 3 处"用户看不到提示" | 中 |
| 10 | 工程配置清理 | `5e410aa` | 删除 iOS/visionOS 残留，`SUPPORTED_PLATFORMS = macosx` | 低 |
| 11 | UI 收口（第一批） | `0c0fd53` | `ContentView` 297 → 216 行，抽出 3 个 ViewModel | 中 |
| 12 | 测试体系 | `35d9a61` | 65 个单元测试（Java 选择 / 下载校验 / 分片合并 / 状态边界） | 低 |

---

## 二、待做（按风险从低到高）

| # | 事项 | 风险 | 需要什么才能收尾 |
|---|---|---|---|
| A | 剩余下载调用方切换 | 低-中 | 逐个切换 + 全量类型检查；遇到"切换会改变行为"的必须记录不切 |
| B | `qwqTests` 加入工程 target | 中 | 需改 `project.pbxproj` 或 Xcode 手工建 Unit Testing Bundle（本机 xcodebuild 不可用，建议你在 Xcode 里点一下） |
| C | UI 剩余职责 | 中 | 窗口壳/标题栏、`searchText`、`isDropTargeted`、画布手势与 spring 参数、按钮与详情页渲染 |
| D | 5 个启动缺陷修复 | 中 | 其中"客户端 JAR 不校验"是**行为变更**，需你拍板 |
| E | 旧兼容层清理（`PCLStubs` / `PCLLaunchBridge`） | 中-高 | 需先完成 E/F，否则会断掉回退路径 |
| F | 双启动流程合并 | **高** | **必须真机启动游戏验证**：Java 扫描等待、日志 flush、进程退出与回调时序 |

---

## 三、已确认的缺陷清单

| 编号 | 缺陷 | 状态 |
|---|---|---|
| D1 | 桥接启动路径**无客户端 JAR 校验**，缺文件照样启动，进游戏才崩 | 待决策（修 = 行为变更） |
| D2 | `MinecraftLauncher` 的 catch 走 `reportCompletion(1)`，"启动失败"与"崩溃退出"不可区分 | 待修 |
| D3 | `exitCode == 0` 时删除日志文件，但会话面板 / `LaunchResult.logURL` 仍指向它 | 待修 |
| D4 | 退管时先置 `readabilityHandler = nil` 再关句柄，管道残留数据丢失（日志尾部） | 待修 |
| D5 | Java 扫描等待是无人 signal 的信号量忙等 | 待修 |
| D6 | 桥接路径漏掉"未实现账号"告警 | 待修 |
| D7 | `PopupManager.show` 空实现导致 3 处安装失败提示不可见 | **已修** |
| D8 | `showAsync` 恒返回 0 导致「导出错误报告」分支永不执行 | **已修** |
| D9 | `hint()` 只写日志，下载完成/失败提示不可见 | **已修** |

---

## 四、每一类的收尾标准

- **模块骨架类**：协议 + 默认实现 + 模块注册 + README，且 `typecheck` 0 error
- **调用方切换类**：对外接口零变化；进度口径一致；错误文案逐字一致；切换后 `typecheck` 0 error
- **缺陷修复类**：修完必须说明"修前现象 / 修后现象 / 是否行为变更"
- **启动合并类**：必须真机启动至少一次游戏，确认：Java 选择成功、资源校验通过、进程启动、日志可见、正常退出无异常弹窗

---

## 五、不做什么

- 不做动态 Bundle 加载、`NSClassFromString`、XPC、插件市场、`Plugin.json` 清单
- 不实现微软登录 / Yggdrasil 登录（本轮范围外，只做"不再假装支持"）
- 不新增功能（主题、多目录、新动画一律冻结）
