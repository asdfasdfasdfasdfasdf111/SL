import Foundation

/// 模块注册表：应用生命周期内唯一的模块登记处。
///
/// 目前模块是静态注册的（在 `AppModuleBootstrap` 中显式列出），
/// 保持编译期可见、可追踪，避免“扫一遍运行时把什么都拉起来”的黑盒行为。
final class ModuleRegistry {
    let context = ModuleContext()
    private(set) var registeredIdentifiers: [String] = []

    func register(_ modules: [any SLModule]) throws {
        for module in modules {
            guard !registeredIdentifiers.contains(module.identifier) else {
                throw ModuleRegistryError.duplicateIdentifier(module.identifier)
            }
            try module.register(in: context)
            registeredIdentifiers.append(module.identifier)
        }
    }

    /// 已注册的模块数量，便于调试与测试断言。
    var count: Int {
        registeredIdentifiers.count
    }
}

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
