import Foundation

/// Small, explicit boundary for application modules.
/// Modules are compile-time units for now; cross-module access is provided by
/// typed capabilities rather than direct singleton dependencies.
protocol SLModule {
    var identifier: String { get }
    func register(in context: ModuleContext) throws
}

struct ModuleCapabilityKey<Value>: Hashable {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}

/// Reference semantics are intentional: module registration must update the
/// shared context even though `SLModule.register` receives it as a value.
final class ModuleContext {
    private var values: [String: Any] = [:]

    func register<Value>(_ value: Value, for key: ModuleCapabilityKey<Value>) {
        values[key.name] = value
    }

    func resolve<Value>(_ key: ModuleCapabilityKey<Value>) -> Value? {
        values[key.name] as? Value
    }
}
