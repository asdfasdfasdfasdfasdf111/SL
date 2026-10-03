//
//  ModDragInstallerTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//
//  `ModDragInstaller.findInstances` 的「匹配 + 去重」逻辑 —— 给定一组游戏根目录
//  （含用户单独选择的根目录），按模组版本范围过滤出匹配实例，且同一目录因
//  「扫描全盘」与「savedRoot 单独传入」双路出现时只算一次。
//
//  为什么能测（2026-10-03 重构后）：
//  原实现把「扫描根目录」与「匹配 + 去重」耦合在一个函数里，而扫描
//  （`findGameRootDirectories`）会把用户真实的游戏根目录灌进来 —— 测试要么依赖
//  用户环境、要么需要注入目录列举器替身。现拆出
//  `findInstances(versionRange:savedRoot:scanning:)`：接受**显式根目录数组**，
//  生产入口传扫描结果、测试直接传临时目录。
//  驱动真实逻辑安全的前提：`MinecraftVersionManager.getVersions(from:)`
//  自 2026-10-02 起**默认零写副作用**（`autoNormalizeOnRead` 默认关闭，
//  不会重命名磁盘上的版本文件夹，见 VersionUtils.swift 头部注释）。
//
//  ⚠️ 不覆盖的部分（有意）：
//  - `findInstances(for:savedRoot:)` 生产入口（内部调 `findGameRootDirectories`
//    全盘扫描，测试不驱动）；
//  - `findInstances` 范围内不涉及文件拷贝 —— `install(modURL:to:)` 的落盘行为
//    由 `DropInstallCoordinatorTests` 覆盖（注入替身 + 真实 `install`）。
//
//  被测：Features/Download/ModDragInstaller.swift
//

import XCTest
@testable import qwq

final class ModDragInstallerTests: XCTestCase {

    /// 建一个带 versions/ 子目录的临时游戏根目录。
    /// `versionNames` 里的每一项都会成为 versions 下的一个**目录**。
    private func makeGameRoot(versions versionNames: [String]) throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModDragInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in versionNames {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("versions/\(name)"),
                withIntermediateDirectories: true
            )
        }
        return root.path
    }

    /// 清理临时根目录。
    private func removeGameRoot(_ root: String) {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// 断言 findInstances 结果包含指定 (root, version) 对（按内容比，GameInstance.id 是 UUID 不可比）。
    private func assertInstances(_ actual: [GameInstance],
                                 contains exactRoot: String,
                                 versions: [String],
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        for version in versions {
            XCTAssertTrue(
                actual.contains { $0.rootPath == exactRoot && $0.version == version },
                "应匹配实例 \(version)@\(exactRoot)（实际：\(actual.map { "\($0.version)@\($0.rootPath)" })）",
                file: file, line: line
            )
        }
    }

    // MARK: - 匹配

    /// 版本号精确命中时匹配该实例。
    func testFindInstancesMatchesExactVersion() throws {
        let root = try makeGameRoot(versions: ["1.20.1", "1.19.2"])
        defer { removeGameRoot(root) }

        let instances = ModDragInstaller.findInstances(versionRange: "1.20.1", savedRoot: "", scanning: [root])

        XCTAssertEqual(instances.count, 1)
        assertInstances(instances, contains: root, versions: ["1.20.1"])
    }

    /// 模组声明 1.20 时，1.20.1 按「段边界前缀」规则也算兼容（声明 1.1 不会误匹配 1.10.2）。
    func testFindInstancesMatchesSegmentPrefix() throws {
        let root = try makeGameRoot(versions: ["1.20.1", "1.10.2"])
        defer { removeGameRoot(root) }

        let instances = ModDragInstaller.findInstances(versionRange: "1.20", savedRoot: "", scanning: [root])

        assertInstances(instances, contains: root, versions: ["1.20.1"])
        XCTAssertFalse(
            instances.contains { $0.version == "1.10.2" },
            "声明 1.1 不该匹配 1.10.2（旧实现字符级前缀的误判，已修）"
        )
    }

    /// 无匹配时返回空数组（不报错）。
    func testFindInstancesNoMatchReturnsEmpty() throws {
        let root = try makeGameRoot(versions: ["1.21"])
        defer { removeGameRoot(root) }

        let instances = ModDragInstaller.findInstances(versionRange: "1.8.9", savedRoot: "", scanning: [root])

        XCTAssertTrue(instances.isEmpty)
    }

    // MARK: - 去重

    /// 同一根目录同时出现在「扫描集合」与「savedRoot」时只计一次。
    func testFindInstancesDeduplicatesDoubleRoot() throws {
        let root = try makeGameRoot(versions: ["1.20.1"])
        defer { removeGameRoot(root) }

        let instances = ModDragInstaller.findInstances(versionRange: "1.20.1",
                                                       savedRoot: root,
                                                       scanning: [root])

        XCTAssertEqual(instances.count, 1, "同一目录双路出现只算一次（savedRoot 去重）")
        assertInstances(instances, contains: root, versions: ["1.20.1"])
    }

    /// savedRoot 不在扫描集合里时也能单独匹配（用户手动选的目录兜底场景）。
    func testFindInstancesMatchesSavedRootAlone() throws {
        let scanned = try makeGameRoot(versions: ["1.19.2"])
        let saved = try makeGameRoot(versions: ["1.20.1"])
        defer { removeGameRoot(scanned); removeGameRoot(saved) }

        let instances = ModDragInstaller.findInstances(versionRange: "1.20.1",
                                                       savedRoot: saved,
                                                       scanning: [scanned])

        assertInstances(instances, contains: saved, versions: ["1.20.1"])
        XCTAssertFalse(instances.contains { $0.rootPath == scanned },
                       "扫描目录里不匹配的版本不应出现在结果里")
    }

    /// 两个不同的根目录都匹配时都返回（多实例场景）。
    func testFindInstancesMatchesAcrossMultipleRoots() throws {
        let rootA = try makeGameRoot(versions: ["1.20.1"])
        let rootB = try makeGameRoot(versions: ["1.20.1"])
        defer { removeGameRoot(rootA); removeGameRoot(rootB) }

        let instances = ModDragInstaller.findInstances(versionRange: "1.20.1",
                                                       savedRoot: "",
                                                       scanning: [rootA, rootB])

        XCTAssertEqual(instances.count, 2)
        assertInstances(instances, contains: rootA, versions: ["1.20.1"])
        assertInstances(instances, contains: rootB, versions: ["1.20.1"])
    }
}