//
//  ScratchPreferenceDomain.swift
//  qwqTests
//
//  测试用例的**偏好域隔离**工具：给用例一块一次性的 `UserDefaults`，
//  让「跑一次测试」不再等于「动一次用户真实设置」。
//
//  为什么需要（两层原因，缺一不可）：
//  1. 测试宿主就是 qwq.app 本体（`TEST_HOST`），测试进程里的 `UserDefaults.standard`
//     就是**用户真实偏好域**；
//  2. 而宿主 abort（Xcode 26.2 隔离析构缺陷，见 `qwqTests/TESTING.md` §五）会直接杀掉进程，
//     `defer` / `tearDown` **都不执行** —— 任何「改完再还原」式的隔离都有这个悬崖：
//     哨兵值会留在用户真实设置里。
//  所以隔离必须由**存储位置**保证，而不是由收尾动作保证。
//
//  用法：
//  ```swift
//  try await withScratchSettingsPersistence { scratch in
//      LauncherSettings.shared.selectedMinecraftVersion = sentinel
//      XCTAssertEqual(scratch.string(forKey: UDK.selectedMinecraftVersion), sentinel)
//  }
//  ```
//  覆盖范围：`AppSettingsStore.shared` 的全部持久化字段。`LauncherSettings` 只是它的转发层
//  （`private let settings = AppSettingsStore.shared`），因此一并被覆盖，无需单独处理。
//
//  ⚠️ 只对「设置层」生效：直接写 `UserDefaults.standard` 的其它类型（如 `CacheManager`、
//  `MicrosoftAuthService`）不在覆盖范围内，那些地方仍需各自收敛。
//
//  收尾（实测过，缺一不可）：`addTeardownBlock` 清域内容 + 删掉 cfprefsd 留下的 0 键空壳 plist，
//  并**再扫一遍本进程此前所有用例留下的空壳**。即便如此，cfprefsd 仍可能在我们 unlink **之后**
//  把最后一个空壳重新落盘（实测会剩 0~1 个 42 B 的 0 键文件），所以另有一次「建域前扫描」兜底 ——
//  那时这些旧域名已无活跃实例，删除不会被写回。空壳不含任何键值，纯粹是目录卫生问题。
//

import XCTest
@testable import qwq

extension XCTestCase {

    /// 本工具管理的一次性偏好域前缀。清理只认这些前缀，绝不触碰其它偏好域文件。
    /// 同时覆盖 `qwqTests/AccountPersistenceCompatTests.swift` 用的账号域前缀 ——
    /// 两类域是同一个机制，扫的时候一起扫，避免只跑一类套件时另一类空壳永远留着。
    private static var scratchDomainPrefixes: [String] {
        ["__qwqTests_SettingsDomain_", "__qwqTests_AccountPersistence_"]
    }

    /// `~/Library/Preferences`（本工程未沙箱化，偏好域就在此处）。
    private static var preferencesDirectory: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences")
    }

    /// 建一块一次性偏好域。用例对它读写不会落到真实偏好；即使用例中途 abort，
    /// 留下的也只是一个空壳文件。
    func makeScratchPreferenceStore() throws -> UserDefaults {
        Self.sweepStaleScratchDomainShells()
        let name = "\(Self.scratchDomainPrefixes[0])\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name), "无法创建独立偏好域 \(name)")
        addTeardownBlock {
            store.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(
                at: Self.preferencesDirectory.appendingPathComponent("\(name).plist"))
            // 顺手把本进程此前用例留下的空壳也扫掉：否则一次全量运行会在
            // ~/Library/Preferences 攒下十几个 42 B 的 0 键文件。
            Self.sweepStaleScratchDomainShells()
        }
        return store
    }

    /// 在一次性偏好域里跑一段用例体：期间**设置层的所有持久化**都落在传入的 `scratch`，
    /// 体结束后把设置层还原回 `.standard`（还原失败也无害——写入只会落到那块一次性地）。
    @discardableResult
    func withScratchSettingsPersistence<T>(
        _ body: (UserDefaults) async throws -> T
    ) async throws -> T {
        let scratch = try makeScratchPreferenceStore()
        AppSettingsStore.redirectPersistenceForTesting(to: scratch)
        do {
            let result = try await body(scratch)
            AppSettingsStore.redirectPersistenceForTesting(to: .standard)
            return result
        } catch {
            AppSettingsStore.redirectPersistenceForTesting(to: .standard)
            throw error
        }
    }

    /// 扫掉遗留的空壳（见文件头「收尾」说明）。
    private static func sweepStaleScratchDomainShells() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: preferencesDirectory, includingPropertiesForKeys: nil) else { return }
        for url in entries
        where scratchDomainPrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
