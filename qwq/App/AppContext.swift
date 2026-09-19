import Foundation

/// Minimal dependency injection hook for the settings layer so the app has a
/// single explicit access point instead of deep global reads scattered across
/// the project.
final class AppContext {
    static let shared = AppContext()

    let settingsStore = AppSettingsStore.shared

    private init() {}
}
