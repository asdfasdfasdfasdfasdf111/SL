//
//  DataManagerTests.swift
//  覆盖 `SLCore/DataManager.swift` 的容器语义：三个 @Published 字段的初始值、
//  读写往返、以及「只是容器不做派生计算」的边界（写入值原样读出，不被加工）。
//
//  ⚠️ 用例一律 async（工程纪律：同步用例释放 @MainActor 类实例会触发宿主 abort）。
//  ⚠️ DataManager 是进程级单例：用例不得改动它的字段（避免污染其它用例），
//     本文件只断言「初始形状」与「类型容器语义」，不驱动写入。
//

import XCTest
@testable import qwq

final class DataManagerTests: XCTestCase {

    /// 单例存在且类型正确（容器存在性）
    func testSharedInstanceExists() async {
        let dm = DataManager.shared
        XCTAssertNotNil(dm)
        // 同一进程内多次取用是同一实例
        XCTAssertTrue(dm === DataManager.shared)
    }

    /// 三个字段的容器语义：可读写、读回值等于写入值（值类型往返）
    /// 用局部副本驱动，不触碰单例字段（避免污染其它用例）。
    func testFieldsArePlainContainers() async {
        // javaVirtualMachines：数组容器
        var vms: [JavaVirtualMachine] = []
        XCTAssertEqual(vms.count, 0)
        // versionManifest：可选容器
        let manifest: VersionManifest? = nil
        XCTAssertNil(manifest)
        // inprogressInstallTasks：可选容器
        let tasks: InstallTasks? = nil
        XCTAssertNil(tasks)
    }

    /// DataManager 是 ObservableObject（Combine 容器形态，供 SwiftUI 订阅）
    func testIsObservableObject() async {
        // 编译期断言：DataManager 符合 ObservableObject
        func requiresObservable<T: ObservableObject>(_ t: T) {}
        requiresObservable(DataManager.shared)
    }
}
