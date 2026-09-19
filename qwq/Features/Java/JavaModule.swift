import Foundation

// MARK: - Java 模块

/// Java 能力的模块注册入口。
///
/// 注册完成后，启动流程只需从 `ModuleContext` 取 `java.resolver`，
/// 即可完成 Java 选取，无需再走 DataManager / 预扫描 / findSuitableJava / 兜底重扫的多级降级链。
///
/// 依赖：`SLModule`、`ModuleContext`、`ModuleCapabilityKey` 由 Core/Module 层的 `SLModule.swift` 提供。
final class JavaModule: SLModule {

    let identifier: String = "java"

    func register(in context: ModuleContext) throws {
        let repository = DefaultJavaRepository()
        let resolver = DefaultJavaResolver(repository: repository)
        context.register(resolver, for: ModuleCapabilityKey<JavaResolver>("java.resolver"))
    }
}
