import Foundation

/// 模块注册表：应用生命周期内唯一的模块登记处。
///
/// 目前模块是静态注册的（在 `AppModuleBootstrap` 中显式列出），
/// 保持编译期可见、可追踪，避免“扫一遍运行时把什么都拉起来”的黑盒行为。
final class ModuleRegistry {
    let context = ModuleContext()
    /// 已注册模块的标识符，**按注册顺序**累积（数组而非 Set：顺序就是模块初始化顺序，
    /// 将来若有依赖关系会依赖这个序）。重复检查是 O(n) 线性扫描 ——
    /// 模块数量是个位数，不值得为此换成集合。
    private(set) var registeredIdentifiers: [String] = []

    /// 依次注册模块。某个模块的标识符与已注册的重复时，抛
    /// `ModuleRegistryError.duplicateIdentifier` 并**中止后续模块**（剩下的不再尝试）。
    ///
    /// ⚠️ 本方法**不是事务性的**：已注册成功的模块不会回滚 ——
    /// 它们写进 `context` 的能力与副作用都已生效。因此调用方拿到错误后，
    /// 不能假定注册表回到了调用前状态。
    func register(_ modules: [any SLModule]) throws {
        for module in modules {
            guard !registeredIdentifiers.contains(module.identifier) else {
                throw ModuleRegistryError.duplicateIdentifier(module.identifier)
            }
            try module.register(in: context)
            // 记在 module.register 成功**之后**：这样 register 抛错时该标识符不会被计入，
            // 调用方修好问题后重试注册同一模块，不会撞上自己留下的「重复标识符」。
            registeredIdentifiers.append(module.identifier)
        }
    }

    /// 已注册的模块数量（等于 `registeredIdentifiers.count`），便于调试与测试断言。
    /// 只反映**标识符登记数**：注册过程中途抛错时，失败的模块没有被计入。
    var count: Int {
        registeredIdentifiers.count
    }
}

/// 模块装配期的错误。两个 case 都属于**开发期配置问题**，不是用户运行时会遇到的错误。
/// - `capabilityNotFound` 由 `SLModule` 的 `require` 抛出（见 Core/Module/SLModule.swift），
///   即「代码要一项能力，但没有任何模块提供它」——同样意味着装配清单配错了。
enum ModuleRegistryError: LocalizedError {
    case duplicateIdentifier(String)
    case capabilityNotFound(String)

    var errorDescription: String? {
        switch self {
        case .duplicateIdentifier(let identifier):
            return "重复注册模块：\(identifier)"
        case .capabilityNotFound(let name):
            return "未找到已注册的能力：\(name)"
        }
    }
}

/// 模块装配清单。
///
/// 新增模块时在这里登记，不要在各处零散调用 `register`。
enum AppModuleBootstrap {
    /// 构造并装配模块注册表。**永不失败**：注册异常被吞掉，只写一行 NSLog。
    ///
    /// ⚠️ 静默降级：某个模块注册失败时应用照常启动，但该模块提供的能力全部缺失，
    /// 症状要到后续真正用到时才以「找不到能力」的形式暴露，排查时容易误判。
    ///
    /// ⚠️ 接线状态：本方法目前在**生产代码里零调用方**（全库只有
    /// `qwqTests/ModuleRegistryTests.swift` 在调）。也就是说模块内核已经能跑通、
    /// 有测试覆盖，但尚未接进 `qwqApp` 的启动流程 —— 真实运行时并不存在这个注册表。
    /// 若要让模块真正生效，需要在 App 启动处调用本方法并持有其返回值。
    static func makeRegistry() -> ModuleRegistry {
        let registry = ModuleRegistry()
        let modules: [any SLModule] = [
            SettingsModule()
            // JavaModule()  — 待模块内核稳定后接入
        ]
        // 注册失败属于装配期错误，直接记录并继续，避免应用启动被单个模块拖死。
        do {
            try registry.register(modules)
        } catch {
            NSLog("[ModuleRegistry] 模块注册失败：\(error.localizedDescription)")
        }
        return registry
    }
}
