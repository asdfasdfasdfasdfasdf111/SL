# qwq 单元测试说明

本目录是给 `qwq` 工程补的第一批单元测试，覆盖三个新模块：`Features/Java/`、`Core/Download/`、`Features/Launch/`。

**当前状态：工程里还没有 XCTest target，本目录下的文件也尚未加入任何 target，现在直接 Cmd+U 不会跑起来。** 需要先按下一节建 target 并手动把文件加进去。

## 一、在 Xcode 中添加 XCTest target

1. 打开 `qwq.xcodeproj`，菜单 `File → New → Target…`
2. 选 `macOS` 分页下的 `Unit Testing Bundle`，Next
3. Product Name 填 **qwqTests**，语言 Swift，其余默认，Finish
4. 选中新建的 `qwqTests` target → `General` → `Testing` 区域（或 `Build Phases` 上方的 Host Application）
   把 **Host Application** 设为 **qwq**
5. `Build Settings` 中确认：
   - `SWIFT_VERSION` = 5.0（与 app target 一致）
   - `MACOSX_DEPLOYMENT_TARGET` = 13.0（与 app target 一致）
   - `ENABLE_TESTABILITY`（Debug）= Yes，否则 `@testable import qwq` 取不到 internal 类型
6. 建好 target 后，把本目录的 5 个文件拖进 Xcode 的 `qwqTests` 目录，并在 `File Inspector` 的
   Target Membership 中勾选 **qwqTests**（不要勾 qwq，否则测试代码会打进 app）

需要加入 target 的文件：

| 文件 | 被测对象 | 备注 |
| --- | --- | --- |
| `JavaResolverTests.swift` | JavaRequirement / DefaultJavaResolver / JavaInstallation | 经 `JavaRepository` 协议注入 fake，无需真实扫描 |
| `DownloadVerifierTests.swift` | CryptoKitDownloadVerifier | 临时目录造真实文件，不依赖网络 |
| `DownloadMergerTests.swift` | DownloadMerger 契约 | 协议无默认实现，用测试替身验证契约 |
| `DownloadStateTests.swift` | DownloadProgress / DownloadState / DownloadError | 纯值类型 |
| `LaunchStateTests.swift` | LaunchState / LaunchError / LaunchResult | 纯值类型 |

每个测试文件顶部都有 `@testable import qwq`，因为 `JavaInstallation`、`JavaRequirement`、
`DefaultJavaResolver`、`JavaResolutionError` 是 internal，不加这一行编译不过。

## 二、不建 target 也能做的类型检查

没有 target 时可用下面的命令做编译期校验（只做 `-typecheck`，不链接、不运行）。
`XCTest` 的 Swift 模块不在 SDK 里，需要显式指定平台 Frameworks 与 `usr/lib` 路径：

```bash
cd /path/to/Swim111Launcher
SDK=$(xcrun --show-sdk-path)
DEV=$(xcode-select -p)
FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"
LIB="$DEV/Platforms/MacOSX.platform/Developer/usr/lib"

# 例：校验下载状态测试
xcrun swiftc -typecheck \
  -sdk "$SDK" -F "$FW" -I "$LIB" \
  -target arm64-apple-macosx13.0 -module-name qwq \
  qwqTests/DownloadStateTests.swift \
  qwq/Core/Download/DownloadState.swift \
  qwq/Core/Download/DownloadProgress.swift \
  qwq/Core/Download/DownloadError.swift
```

其它文件对应的源文件集合：

- `DownloadVerifierTests.swift` → `Core/Download/DownloadVerifier.swift`、`DownloadError.swift`
- `DownloadMergerTests.swift` → `Core/Download/DownloadMerger.swift`、`DownloadSliceStore.swift`
- `LaunchStateTests.swift` → `Features/Launch/LaunchState.swift`、`LaunchError.swift`、`LaunchResult.swift`
- `JavaResolverTests.swift` → `Features/Java/` 下的 `JavaResolver.swift`、`JavaInstallation.swift`、
  `JavaRequirement.swift`、`JavaInfo.swift`，外加 `PCLCore` 的 `Architecture.swift`、
  `Java/JavaVirtualMachine.swift`、`Utils/MyLocalizedError.swift`、`Utils/PropertiesParser.swift`

> `JavaResolverTests` 的命令行校验有个已知折中：被测主体（`JavaResolver` / `JavaInstallation` /
> `JavaRequirement` / `JavaVirtualMachine`）都是真实源码，但三处**直接依赖**用签名一致的替身
> 顶替，否则会牵出整条依赖链（`JavaRepository` → `JavaManager` → `LauncherSettings` /
> `AppContext` / SwiftUI；`URL.parent()` 所在的 `PCLStubs.swift` 依赖 `VersionManifest` /
> `MinecraftDirectory`；全局 `err()` 所在的 `LogManager.swift` 依赖 `SharedConstants`）。
> 替身放在 `/tmp`，不入库；在 Xcode 里跑真身 target 时不受此影响。

单模块编译下 `@testable import qwq` 会产生一条
`file ... is part of module 'qwq'; ignoring import` 警告，属预期，不影响结果。

## 三、已知覆盖率缺口与后续计划

本轮只覆盖纯值类型、纯计算逻辑与可在临时目录内闭环的文件校验。
以下高风险行为**尚未覆盖**，按优先级列出后续计划：

1. **下载器的真实并发与断点续传（最高优先级）**
   - 未覆盖：`DownloadScheduler` 的分片切分与并发额度、`DownloadSliceStore` 的续传台账、
     `DownloadEngine` 的状态流发布。
   - 阻塞原因：三者都只有协议声明，无实现；且真实验证需要受控 HTTP 服务端。
   - 计划：引入进程内 mock HTTP server（`Swifter` 或基于 `Network.framework` 的最小实现），
     支持返回 206 + `Content-Range`、可控限速、中途断连，再补：
     - 分片切分边界（文件大小不能被分片数整除、单分片、0 字节）
     - 续传：写入半片后中断 → 重连带 `Range` → 合并结果哈希一致
     - 源切换：主源 5xx → 落到备用源（配合 `SequentialDownloadSourceResolver`）
     - 取消：`.cancelled` 终态后临时文件被清理

2. **`DownloadMerger` 的真实实现**
   - 协议注释已约定「单分片允许直接移动临时文件」，但工程内无实现（旧逻辑在 `NetManager.merge`）。
   - 计划：落地 `FileManagerDownloadMerger` 后，把 `DownloadMergerTests` 里的
     `OffsetOrderingMerger` 替换为真实实现，保留现有断言（乱序/倒序拼接、目录自动创建、
     分片缺失报错、空分片列表）。

3. **`LaunchService` 全链路**
   - `LaunchService` / `LaunchArgumentBuilder` / `GameProcessController` 均为纯协议，无实现、无注入点。
   - 计划：落地 `DefaultLaunchService` 时把参数组装器与进程控制器作为构造参数注入，
     用 fake 断言参数顺序（JVM 参数 → 主类 → 游戏参数）、classpath 拼接符与 `-Xmx` 生成。

4. **`DefaultLaunchPreflight`**
   - 已有可注入的四个校验器（`ClientFileVerifier` / `LibraryFileVerifier` /
     `AssetFileVerifier` / `NativeInstaller`），具备可测性，本轮未覆盖。
   - 计划：补 `LaunchPreflightTests`，断言 `skipResourceCheck` 短路、四段调用顺序、
     进度区间映射（支持库 0~0.5、资源 0.5~1）。

5. **`GameSessionStore`**
   - `InMemoryGameSessionStore` 有实现，但 `register` 需要 `ManagedProcess`，
     而 `ManagedProcess` 直接持有 `Process`，缺少协议抽象。
   - 建议改造：把 `ManagedProcess` 抽成协议（如 `GameProcess`），
     或在测试中以 `/bin/sleep` 作为受控进程验证 register → observe → terminate。

6. **`JavaModule`**
   - 依赖 `SLModule` / `ModuleContext` / `ModuleCapabilityKey`，Core/Module 层尚未落地，当前无法编译。
   - 计划：`SLModule.swift` 就位后补测「注册后可从 ModuleContext 取到 java.resolver」。

7. **CI**
   - 工程当前没有任何 CI。计划：target 建好后接一条
     `xcodebuild -scheme qwq -destination 'platform=macOS' test` 的流水线，
     并逐步给出覆盖率门禁。
