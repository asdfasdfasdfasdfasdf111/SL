# 更新日志

本文件只记录已合并、可验证且仍然对当前版本有意义的变更。历史补丁、重复描述和已失效的设计说明不再堆积在这里；详细架构迁移另见 `ARCHITECTURE.md` 与重构计划。

## Unreleased

### 架构治理

- 建立编译期模块注册基础，保留明确的能力键和模块装配入口。
- 将设置持久化集中到 `AppSettingsStore`；`ThemeManager` 与 `LauncherSettings` 暂时保留为兼容入口。
- 账号启动准备逻辑统一到 `AnyAccount.prepareLaunch(options:)`。
- Microsoft 与 Yggdrasil 账号在未实现时显式返回错误，不再静默伪装成离线账号。
- 启动桥的 Java 回退路径改为直接使用 `JavaManager`，不再读取 `LauncherSettings` 中的第二份 Java 扫描列表。
- 删除恒返回在线的未使用 `NetworkTest` 存根。

### 可靠性

- 修复下载、安装、启动、资源校验、日志管道和缓存索引中的多项已验证缺陷。
- 启动前资源检查失败时停止启动并向用户报告原因。
- 保护异步任务和进程回调的归属，避免旧任务覆盖新状态。
- 修复 Java 需求推导、资源包格式、游戏扫描迟到结果和启动进程退出竞态。
- 增加账号持久化兼容性验证，避免重构破坏既有账户数据格式。

### 当前限制

- 项目仍处于 Beta 阶段。
- Microsoft 登录、Yggdrasil 登录、完整主题系统和多 Minecraft 目录尚未实现。
- `PCLCore`、兼容层和多个全局状态入口仍在迁移中；本版本不宣称架构重构已完成。
- 真实构建依赖 Xcode 与 Swift Package Manager；网络不可用时不能把依赖解析失败误判为源码编译失败。

## Beta 0.1.x

- 支持 macOS Minecraft 离线启动、原版/Fabric/Forge/NeoForge/Quilt 安装、Java 扫描与选择、Modrinth 模组浏览、模组包安装和离线皮肤。
- 启动器包含下载缓存、完整性检查、游戏日志管道和崩溃报告能力。
- 详细历史变更已归档，不再作为当前架构或行为契约使用。
