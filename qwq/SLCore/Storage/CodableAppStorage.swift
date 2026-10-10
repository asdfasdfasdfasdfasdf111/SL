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
//  偏好域（2026-10-10）：`store` 是**注入点**，默认 `UserDefaults.standard`（生产行为不变）。
//  存在它的原因：测试宿主的宿主 App 就是 qwq.app 本体，测试进程里的 `.standard` 是
//  **用户真实偏好域**；用例要读写账号这类真实数据时必须能指向独立域，否则「跑一次测试」
//  就等于「动一次用户数据」。见 `qwqTests/AccountPersistenceCompatTests.swift`。
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
    /// 落盘目标偏好域。默认 `.standard`；测试传 `UserDefaults(suiteName:)` 建的独立域。
    private let store: UserDefaults
    public init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = wrappedValue
        self.store = store
    }
    public var wrappedValue: Value {
        get {
            if let data = store.data(forKey: key),
               let value = try? JSONDecoder().decode(Value.self, from: data) {
                return value
            }
            return defaultValue
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                store.set(data, forKey: key)
            }
        }
    }
}
