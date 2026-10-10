//
//  AppSettingsStorePersistenceTests.swift
//  qwqTests
//
//  覆盖 `Features/Settings/AppSettingsStore.swift` 的**读写一致性**契约：
//  每个 `@Published` 字段的 `didSet` 都要把值落到偏好域的 UDK 键，
//  本文件钉住「写字段 ⇒ 同一个键在偏好域里可见」的双向一致，防止
//  新增字段时漏写 `didSet`（写字段但没落盘 = 重启丢设置）或写错键。
//
//  ⚠️ 本文件**不读写用户真实偏好**（2026-10-10 起）：测试宿主就是 qwq.app（TEST_HOST），
//  `UserDefaults.standard` 是用户真实偏好域，过去这些用例靠「哨兵值 + `defer` 还原」隔离 ——
//  一旦宿主 abort（`defer` 不执行）哨兵就留在用户设置里。现改为经
//  `withScratchSettingsPersistence` 把设置层整体重定向到一次性偏好域（见
//  `qwqTests/ScratchPreferenceDomain.swift`），断言读注入域，**不再需要任何还原动作**。
//
//  用例一律 async（宿主 abort 规避，见 `qwqTests/TESTING.md`）。
//

import XCTest
@testable import qwq

final class AppSettingsStorePersistenceTests: XCTestCase {

    private var store: AppSettingsStore { AppSettingsStore.shared }

    // MARK: - 字符串字段读写一致性

    /// `selectedMinecraftVersion` 写入后，注入域的 UDK 键立即可见（同值）。
    func testSelectedMinecraftVersionWriteIsPersistedAndRestored() async throws {
        try await withScratchSettingsPersistence { scratch in
            let key = UDK.selectedMinecraftVersion
            let sentinel = "sentinel-\(UUID().uuidString)"

            self.store.selectedMinecraftVersion = sentinel

            XCTAssertEqual(scratch.string(forKey: key), sentinel,
                           "didSet 必须把新值写入偏好域的 UDK 键")
            XCTAssertEqual(self.store.selectedMinecraftVersion, sentinel,
                           "@Published 字段与存储保持一致")
        }
    }

    /// `selectedGameRoot` 同款契约。
    func testSelectedGameRootWriteIsPersistedAndRestored() async throws {
        try await withScratchSettingsPersistence { scratch in
            let key = UDK.selectedGameRoot
            let sentinel = "sentinel-\(UUID().uuidString)"

            self.store.selectedGameRoot = sentinel

            XCTAssertEqual(scratch.string(forKey: key), sentinel)
            XCTAssertEqual(self.store.selectedGameRoot, sentinel)
        }
    }

    func testOfflineUsernameWriteIsPersistedAndRestored() async throws {
        try await withScratchSettingsPersistence { scratch in
            let key = UDK.offlineUsername
            let sentinel = "sentinel-\(UUID().uuidString)"

            self.store.offlineUsername = sentinel

            XCTAssertEqual(scratch.string(forKey: key), sentinel)
            XCTAssertEqual(self.store.offlineUsername, sentinel)
        }
    }

    // MARK: - 可选 URL 字段：写与非写两条路径

    /// `avatarImageURL`：写入时落盘 `url.path`，清除（nil）时移除键——两条路径都要一致。
    func testAvatarImageURLWriteAndClearBothPersistCorrectly() async throws {
        try await withScratchSettingsPersistence { scratch in
            let key = UDK.avatarImagePath

            // 写入路径
            let sentinel = URL(fileURLWithPath: "/tmp/sl-avatar-\(UUID().uuidString).png")
            self.store.avatarImageURL = sentinel
            XCTAssertEqual(scratch.string(forKey: key), sentinel.path,
                           "写入 URL 必须落盘其 path")
            XCTAssertEqual(self.store.avatarImageURL, sentinel)

            // 清除路径：nil 必须移除键（而非写空串）
            self.store.avatarImageURL = nil
            XCTAssertNil(scratch.string(forKey: key),
                         "清除 URL 必须 removeObject，不得残留空串")
        }
    }

    /// `skinImageURL` 同款契约（皮肤路径与头像路径是独立键，不得串写）。
    func testSkinImageURLUsesItsOwnKey() async throws {
        try await withScratchSettingsPersistence { scratch in
            let avatarKey = UDK.avatarImagePath
            let skinKey = UDK.skinImagePath

            let sentinel = URL(fileURLWithPath: "/tmp/sl-skin-\(UUID().uuidString).png")
            self.store.skinImageURL = sentinel

            XCTAssertEqual(scratch.string(forKey: skinKey), sentinel.path)
            // 头像键不得被皮肤写入串改（键隔离）
            XCTAssertNotEqual(scratch.string(forKey: avatarKey), sentinel.path,
                              "皮肤写入不得落到头像键")
        }
    }

    // MARK: - 单例唯一性

    /// 四重设置里 `AppSettingsStore` 是唯一存储点：`shared` 必须恒同实例（读写一致性前提）。
    func testSharedSingletonIsStableInstance() async throws {
        let a = AppSettingsStore.shared
        let b = AppSettingsStore.shared
        XCTAssertTrue(a === b, "AppSettingsStore.shared 必须恒为同一实例")
    }
}
