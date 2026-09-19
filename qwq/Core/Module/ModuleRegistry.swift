import Foundation

/// Owns module registration for the application lifetime.
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
}

enum ModuleRegistryError: LocalizedError {
    case duplicateIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .duplicateIdentifier(let identifier):
            return "重复注册模块：\(identifier)"
        }
    }
}
