import Foundation

/// Owns module registration for the application lifetime.
///
/// This is intentionally small: lifecycle, dependency ordering, and dynamic
/// code loading are out of scope until the module boundaries are proven by real
/// features. Keeping this registry boring makes it safe to migrate existing
/// code incrementally.
final class ModuleRegistry {
    private(set) var context = ModuleContext()
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
