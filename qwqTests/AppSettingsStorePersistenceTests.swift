//
//  AppSettingsStorePersistenceTests.swift
//  qwqTests
//
//  覆盖 `Features/Settings/AppSettingsStore.swift` 的**读写一致性**契约：
//  每个 `@Published` 字段的 `didSet` 都直写 `UserDefaults.standard`（UDK 键），
//  本文件钉住「写字段 ⇒ UserDefaults 里同一个键可见」的双向一致，防止
//  新增字段时漏写 `didSet`（写字段但没落盘 = 重启丢设置）或写错键。
//
//  ⚠️ 测试宿主就是 qwq.app（TEST_HOST），`UserDefaults.standard` 是**用户真实偏好域**。
//  遵循 `HANDOVER.md` §三的既有纪律：不驱动回写、用**哨兵值 + defer 还原**、
//  还原写在最靠近写入处、只断言与真实键一致的键（写真实键等于写这份偏好）。
//
//  用例一律 async（宿主 abort 规避，见 `qwqTests/TESTING.md`）。
//

import XCTest
@testable import qwq

final class AppSettingsStorePersistenceTests: XCTestCase {

    private let store = AppSettingsStore.shared

    // MARK: - 字符串字段读写一致性

    /// `selectedMinecraftVersion` 写入后，UserDefaults 的 UDK 键立即可见（同值）。
    /// 用哨兵值 + defer 还原，避免污染真实偏好。
    func testSelectedMinecraftVersionWriteIsPersistedAndRestored() async throws {
        let key = UDK.selectedMinecraftVersion
        let original = UserDefaults.standard.string(forKey: key)
        let sentinel = "sentinel-\(UUID().uuidString)"

        store.selectedMinecraftVersion = sentinel
        defer { UserDefaults.standard.set(original, forKey: key) }

        XCTAssertEqual(UserDefaults.standard.string(forKey: key), sentinel,
                       "didSet 必须把新值写入 UserDefaults 的 UDK 键")
        XCTAssertEqual(store.selectedMinecraftVersion, sentinel,
                       "@Published 字段与存储保持一致")
    }

    /// `selectedGameRoot` 与 `offlineUsername` 同款契约。
    func testSelectedGameRootWriteIsPersistedAndRestored() async throws {
        let key = UDK.selectedGameRoot
        let original = UserDefaults.standard.string(forKey: key)
        let sentinel = "sentinel-\(UUID().uuidString)"

        store.selectedGameRoot = sentinel
        defer { UserDefaults.standard.set(original, forKey: key) }

        XCTAssertEqual(UserDefaults.standard.string(forKey: key), sentinel)
        XCTAssertEqual(store.selectedGameRoot, sentinel)
    }

    func testOfflineUsernameWriteIsPersistedAndRestored() async throws {
        let key = UDK.offlineUsername
        let original = UserDefaults.standard.string(forKey: key)
        let sentinel = "sentinel-\(UUID().uuidString)"

        store.offlineUsername = sentinel
        defer { UserDefaults.standard.set(original, forKey: key) }

        XCTAssertEqual(UserDefaults.standard.string(forKey: key), sentinel)
        XCTAssertEqual(store.offlineUsername, sentinel)
    }

    // MARK: - 可选 URL 字段：写与非写两条路径

    /// `avatarImageURL`：写入时落盘 `url.path`，清除（nil）时移除键——两条路径都要一致。
    func testAvatarImageURLWriteAndClearBothPersistCorrectly() async throws {
        let key = UDK.avatarImagePath
        let original = UserDefaults.standard.string(forKey: key)

        // 写入路径
        let sentinel = URL(fileURLWithPath: "/tmp/sl-avatar-\(UUID().uuidString).png")
        store.avatarImageURL = sentinel
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), sentinel.path,
                       "写入 URL 必须落盘其 path")
        XCTAssertEqual(store.avatarImageURL, sentinel)

        // 清除路径：nil 必须移除键（而非写空串）
        store.avatarImageURL = nil
        XCTAssertNil(UserDefaults.standard.string(forKey: key),
                     "清除 URL 必须 removeObject，不得残留空串")

        // 还原到原值（含「原本就没有」的情况）
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// `skinImageURL` 同款契约（皮肤路径与头像路径是独立键，不得串写）。
    func testSkinImageURLUsesItsOwnKey() async throws {
        let avatarKey = UDK.avatarImagePath
        let skinKey = UDK.skinImagePath
        let originalAvatar = UserDefaults.standard.string(forKey: avatarKey)
        let originalSkin = UserDefaults.standard.string(forKey: skinKey)

        let sentinel = URL(fileURLWithPath: "/tmp/sl-skin-\(UUID().uuidString).png")
        store.skinImageURL = sentinel
        defer {
            if let originalAvatar { UserDefaults.standard.set(originalAvatar, forKey: avatarKey) }
            else { UserDefaults.standard.removeObject(forKey: avatarKey) }
            if let originalSkin { UserDefaults.standard.set(originalSkin, forKey: skinKey) }
            else { UserDefaults.standard.removeObject(forKey: skinKey) }
        }

        XCTAssertEqual(UserDefaults.standard.string(forKey: skinKey), sentinel.path)
        // 头像键不得被皮肤写入串改（键隔离）
        XCTAssertNotEqual(UserDefaults.standard.string(forKey: avatarKey), sentinel.path,
                          "皮肤写入不得落到头像键")
    }

    // MARK: - 单例唯一性

    /// 四重设置里 `AppSettingsStore` 是唯一存储点：`shared` 必须恒同实例（读写一致性前提）。
    func testSharedSingletonIsStableInstance() async throws {
        let a = AppSettingsStore.shared
        let b = AppSettingsStore.shared
        XCTAssertTrue(a === b, "AppSettingsStore.shared 必须恒为同一实例")
    }
}
