import Foundation

/// A small, explicit boundary for application modules.
///
/// Modules are compile-time units for now. They are not dynamic plug-ins and
/// must not reach into another module's implementation. Cross-module access is
/// provided through `ModuleContext` capabilities.
protocol SLModule {
    var identifier: String { get }
    func register(in context: ModuleContext) throws
}

/// A capability key keeps registrations typed while avoiding global singletons.
struct ModuleCapabilityKey<Value>: Hashable {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}

struct ModuleContext {
    private var values: [String: Any] = [:]

    mutating func register<Value>(_ value: Value, for key: ModuleCapabilityKey<Value>) {
        values[key.name] = value
    }

    func resolve<Value>(_ key: ModuleCapabilityKey<Value>) -> Value? {
        values[key.name] as? Value
    }
}
