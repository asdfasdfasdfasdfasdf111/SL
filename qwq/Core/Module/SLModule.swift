import Foundation

/// 应用模块的注册入口。
///
/// 这里的“模块”是**编译期模块**：一个模块就是一组职责内聚的类型，
/// 通过 `ModuleContext` 对外提供能力（capability），而不是让别处直接访问内部单例。
///
/// 明确不做的事情：
/// - 不做动态 `.bundle` 加载
/// - 不做 `NSClassFromString` 运行时扫描
/// - 不做 XPC / 独立进程插件
/// - 不做插件市场、Plugin.json 清单机制
///
/// 目标是把“跨模块直接摸单例”改成“跨模块只依赖协议与值类型”。
protocol SLModule {
    var identifier: String { get }
    func register(in context: ModuleContext) throws
}

/// 能力的类型化键。用泛型约束注册与解析的类型一致。
struct ModuleCapabilityKey<Value>: Hashable {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}

/// 模块上下文。
///
/// **必须是引用类型（class）**：`SLModule.register(in:)` 传入的是值拷贝到栈上的 struct 语义，
/// 若上下文是值类型，模块内部注册的能力只会写进副本，注册不生效。
final class ModuleContext {
    private var values: [String: Any] = [:]

    func register<Value>(_ value: Value, for key: ModuleCapabilityKey<Value>) {
        values[key.name] = value
    }

    func resolve<Value>(_ key: ModuleCapabilityKey<Value>) -> Value? {
        values[key.name] as? Value
    }

    /// 已注册能力数量，便于调试与测试断言。
    var registeredCapabilityCount: Int {
        values.count
    }
}

extension ModuleContext {
    /// 便捷读取：已注册的能力不存在时直接中断，用于启动期“缺了就装不上”的强依赖。
    func require<Value>(_ key: ModuleCapabilityKey<Value>) throws -> Value {
        guard let value = resolve(key) else {
            throw ModuleRegistryError.capabilityNotFound(key.name)
        }
        return value
    }
}
