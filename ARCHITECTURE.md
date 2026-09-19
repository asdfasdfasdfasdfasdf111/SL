# SL 模块边界

这份文档记录 SL 当前采用的重构方向：**先做编译期模块化，不做动态插件加载**。

## 原则

1. `App` 只负责启动和组装模块。
2. `Core` 只放稳定的领域模型、协议和模块基础设施。
3. `Features` 负责用户功能和用例编排。
4. `Infrastructure` 负责网络、文件、进程和持久化实现。
5. `UI` 只负责展示、导航和用户意图，不直接编排下载或启动流程。
6. 模块之间只能依赖公开协议和数据模型，不能访问另一个模块的单例或私有实现。

## 当前迁移策略

本次重构从 `Core/Module` 开始，但暂时不移动现有业务文件，也不改变启动流程。每次后续迁移都必须满足：

- 一个明确的模块职责；
- 一个对外协议；
- 一个可替换的实现；
- 至少一个针对边界的测试；
- 编译通过后再迁移下一个模块。

第一条实际业务迁移线是：

```text
LauncherSettings / ThemeManager
    -> Settings module
JavaManager
    -> Java module
LaunchCoordinator / PCLLaunchBridge
    -> Launch module
NetDownloader
    -> Download module
```

`PCLCore` 暂时作为兼容区保留，禁止继续向其中添加新的 UI 状态或全局单例。等启动、Java、下载三个边界稳定后，再逐步删除兼容桥。

## 现在不做的事

- 不引入动态 `.bundle` 插件；
- 不一次性重写整个项目；
- 不把每个文件都包装成“插件”；
- 不在没有测试的情况下重写下载器或启动器。
