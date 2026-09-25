//
//  CodableAppStorage.swift
//  `UserDefaults` + JSON 的属性包装器（简化版）。
//
//  历史：本文件原属 `SLCore/Stubs.swift`。
//
//  职责：把符合 `Codable` 的值以 JSON 存入 `UserDefaults`，读写都走存储本身。
//  边界：**没有 `@AppStorage` 的 KVO 联动**（名字里的 simplified 指的就是这一点）——
//        外部改动 `UserDefaults` 不会通知本包装器，视图也不会自动刷新；
//        需要刷新语义时不要用它。
//
//  注释引用约定：一律写「文件 + 符号/场景」，**不写行号**（行号会随任何一次编辑漂移）。
//

import Foundation

// MARK: - CodableAppStorage (simplified)
/// `UserDefaults` + JSON 的属性包装器（简化版：无 `@AppStorage` 的 KVO 联动）。
/// 使用方：`SLCore/Account/AnyAccount.swift` 的 `AccountManager.accounts` / `.accountId`，
/// 全库其余位置无引用。
/// 线程安全前提：`wrappedValue` 直接读写 `UserDefaults`（线程安全 API），不持有隔离状态。
@propertyWrapper
public struct CodableAppStorage<Value: Codable> {
    private let key: String
    private let defaultValue: Value
    public init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.defaultValue = wrappedValue
    }
    public var wrappedValue: Value {
        get {
            if let data = UserDefaults.standard.data(forKey: key),
               let value = try? JSONDecoder().decode(Value.self, from: data) {
                return value
            }
            return defaultValue
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}
