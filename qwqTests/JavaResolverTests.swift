//
//  JavaResolverTests.swift
//  qwqTests
//
//  覆盖 `Features/Java/` 下的三个新文件：
//  - JavaRequirement：Minecraft 版本号 -> 最低 Java 主版本的推导规则
//  - DefaultJavaResolver：候选集排序与过滤策略（经 `JavaRepository` 协议注入 fake）
//  - JavaInstallation：由 `JavaInfo` / `JavaVirtualMachine` 转换的字段映射
//
//  不覆盖 JavaModule.swift：其依赖的 `SLModule` / `ModuleContext` / `ModuleCapabilityKey`
//  在 Core/Module 层尚未落地，无法编译，需等 SLModule.swift 就位后补测。
//

import XCTest
@testable import qwq

// MARK: - 测试替身

/// `JavaRepository` 的测试替身。
///
/// `DefaultJavaResolver` 的构造参数接受 `JavaRepository` 协议，
/// 因此无需拉起真实扫描（会 fork `java -version` 子进程）即可验证选取策略。
private final class FakeJavaRepository: JavaRepository, @unchecked Sendable {

    /// `installed()` 的返回值
    let installedResult: [JavaInstallation]
    /// `refresh()` 的返回值；nil 表示与 `installed()` 返回同一份数据
    let refreshResult: [JavaInstallation]?

    /// 调用序列，用于断言「先 installed，空则 refresh」的降级顺序
    private(set) var callLog: [String] = []
    /// 被 `save(_:)` 记录的安装
    private(set) var saved: [JavaInstallation] = []

    init(installed: [JavaInstallation] = [], refresh: [JavaInstallation]? = nil) {
        self.installedResult = installed
        self.refreshResult = refresh
    }

    func installed() async -> [JavaInstallation] {
        callLog.append("installed")
        return installedResult
    }

    func refresh() async -> [JavaInstallation] {
        callLog.append("refresh")
        return refreshResult ?? installedResult
    }

    func save(_ installation: JavaInstallation) async {
        callLog.append("save")
        saved.append(installation)
    }

    /// 预扫描在本 fake 中只记录调用，不触发真实扫描。
    func preScan() {
        callLog.append("preScan")
    }
}

// MARK: - 测试数据构造

/// 本机原生架构（含 universal），`isNative` 恒为 true。
private let nativeArchitecture: JavaArchitecture = JavaArchitecture.system

/// 非本机架构，需 Rosetta 转译，`isNative` 恒为 false。
/// 按本机实际架构推导，避免测试在 Apple Silicon / Intel 上结论不同。
private let foreignArchitecture: JavaArchitecture = (JavaArchitecture.system == .arm64) ? .x64 : .arm64

private func makeInstallation(
    path: String,
    major: Int,
    architecture: JavaArchitecture = .universal,
    isCompatible: Bool = true,
    vendor: String? = nil
) -> JavaInstallation {
    JavaInstallation(
        executableURL: URL(fileURLWithPath: path),
        majorVersion: major,
        fullVersion: "\(major).0.1",
        architecture: architecture,
        vendor: vendor,
        isCompatible: isCompatible,
        isJDK: true
    )
}

// MARK: - 测试用例

final class JavaResolverTests: XCTestCase {

    // MARK: JavaRequirement 版本推导

    /// 官方版本区间的最低 Java 要求：1.16.5 及更早 -> 8，1.17 -> 16，1.18~1.20.4 -> 17，1.20.5+ -> 21
    func testMinimumMajorForReleaseVersions() async {
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.8.9"), 8)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.12.2"), 8)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.16.5"), 8)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.17"), 16)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.17.1"), 16)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.18.2"), 17)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.19.4"), 17)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.20"), 17)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.20.4"), 17)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.20.5"), 21)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.20.6"), 21)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.21"), 21)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.21.4"), 21)
    }

    /// 快照按 (年份, 周序号) 近似映射：24w14a 起 -> 21，21w~23w -> 17，更早 -> 8
    func testMinimumMajorForSnapshots() async {
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "24w14a"), 21)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "25w02a"), 21)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "23w51b"), 17)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "21w03a"), 17)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "20w14a"), 8)
    }

    /// 无法解析的版本号兜底为 Java 8；非 "1.x" 的新版本号方案按 Java 21 处理
    func testMinimumMajorForUnparsableVersions() async {
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: ""), JavaRequirement.fallbackMinimumMajor)
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "unknown"), JavaRequirement.fallbackMinimumMajor)
        // 未来版本号方案（去掉 "1." 前缀）：保守按 Java 21 处理
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "21.0.1"), 21)
        // 带预发布后缀的版本号只取纯数字前缀参与比较
        XCTAssertEqual(JavaRequirement.minimumMajor(forMinecraftVersion: "1.20.5-rc1"), 21)
    }

    /// 由 Minecraft 版本构造需求时，同时回填 minimumMajor 与 mcVersion
    func testRequirementFromMinecraftVersion() async {
        let requirement = JavaRequirement(mcVersion: "1.20.1", preferredMajor: 21, remarks: "manifest.javaVersion=21")
        XCTAssertEqual(requirement.minimumMajor, 17)
        XCTAssertEqual(requirement.preferredMajor, 21)
        XCTAssertEqual(requirement.mcVersion, "1.20.1")
        XCTAssertEqual(requirement.remarks, "manifest.javaVersion=21")
    }

    /// manifest 声明优先于版本推断；未声明或 <= 0 时回落到推断值；两者皆无时取兜底 8
    func testRequirementFromManifestJavaVersion() async {
        let fromManifest = JavaRequirement(manifestJavaVersion: 21, mcVersion: "1.18.2")
        XCTAssertEqual(fromManifest.minimumMajor, 21, "manifest 声明优先于由 mcVersion 推断的值")

        let ignoredZero = JavaRequirement(manifestJavaVersion: 0, mcVersion: "1.18.2")
        XCTAssertEqual(ignoredZero.minimumMajor, 17, "manifest 为 0 时按未声明处理")

        let withoutManifest = JavaRequirement(manifestJavaVersion: nil, mcVersion: "1.17.1")
        XCTAssertEqual(withoutManifest.minimumMajor, 16)

        let empty = JavaRequirement(manifestJavaVersion: nil, mcVersion: nil)
        XCTAssertEqual(empty.minimumMajor, JavaRequirement.fallbackMinimumMajor)
    }

    // MARK: DefaultJavaResolver 选取策略

    /// preferredMajor 命中优先于「版本更高」
    func testResolvePrefersPreferredMajorOverHigherVersion() async throws {
        let java21 = makeInstallation(path: "/Library/Java/21/bin/java", major: 21)
        let java17 = makeInstallation(path: "/Library/Java/17/bin/java", major: 17)
        let resolver = DefaultJavaResolver(repository: FakeJavaRepository(installed: [java21, java17]))

        let selected = try await resolver.resolve(JavaRequirement(minimumMajor: 8, preferredMajor: 17))
        XCTAssertEqual(selected.majorVersion, 17)
        XCTAssertEqual(selected.executablePath, "/Library/Java/17/bin/java")
    }

    /// 本机原生架构优先于「版本更高」：原生 17 胜过需转译的 21
    func testResolvePrefersNativeArchitectureOverHigherVersion() async throws {
        let native17 = makeInstallation(path: "/opt/java/17/bin/java", major: 17, architecture: nativeArchitecture)
        let foreign21 = makeInstallation(path: "/opt/java/21/bin/java", major: 21, architecture: foreignArchitecture)
        let resolver = DefaultJavaResolver(repository: FakeJavaRepository(installed: [foreign21, native17]))

        let selected = try await resolver.resolve(JavaRequirement(minimumMajor: 8))
        XCTAssertEqual(selected.majorVersion, 17)
        XCTAssertEqual(selected.executablePath, "/opt/java/17/bin/java")
    }

    /// 架构与 preferredMajor 都相同时取主版本最高者
    func testResolvePicksHighestMajorVersionWhenArchitectureIsEqual() async throws {
        let candidates = [
            makeInstallation(path: "/opt/java/8/bin/java", major: 8),
            makeInstallation(path: "/opt/java/21/bin/java", major: 21),
            makeInstallation(path: "/opt/java/17/bin/java", major: 17)
        ]
        let resolver = DefaultJavaResolver(repository: FakeJavaRepository(installed: candidates))

        let selected = try await resolver.resolve(JavaRequirement(minimumMajor: 8))
        XCTAssertEqual(selected.majorVersion, 21)
    }

    /// 版本与架构均相同时按路径字典序取较小者，保证选取结果稳定
    func testResolveBreaksTieByExecutablePath() async throws {
        let candidates = [
            makeInstallation(path: "/usr/bin/java", major: 21),
            makeInstallation(path: "/opt/homebrew/bin/java", major: 21)
        ]
        let resolver = DefaultJavaResolver(repository: FakeJavaRepository(installed: candidates))

        let selected = try await resolver.resolve(JavaRequirement(minimumMajor: 8))
        XCTAssertEqual(selected.executablePath, "/opt/homebrew/bin/java")
    }

    /// 低于 minimumMajor 的候选全部被过滤，抛出 noCompatibleVersion 并回传候选集
    func testResolveThrowsWhenNoCandidateMeetsMinimumMajor() async throws {
        let candidates = [
            makeInstallation(path: "/opt/java/8/bin/java", major: 8),
            makeInstallation(path: "/opt/java/17/bin/java", major: 17)
        ]
        let repository = FakeJavaRepository(installed: candidates)
        let resolver = DefaultJavaResolver(repository: repository)
        let requirement = JavaRequirement(mcVersion: "1.20.6")

        // XCTAssertThrowsError 的 autoclosure 不支持 async，故自行 do/catch 捕获
        do {
            _ = try await resolver.resolve(requirement)
            XCTFail("候选均不满足 Java 21 时应抛出错误")
        } catch let error as JavaResolutionError {
            guard case .noCompatibleVersion(let captured, let available) = error else {
                return XCTFail("期望 .noCompatibleVersion，实际为 \(error)")
            }
            XCTAssertEqual(captured.minimumMajor, 21)
            XCTAssertEqual(available.count, 2)
        } catch {
            XCTFail("期望 JavaResolutionError，实际为 \(error)")
        }
    }

    /// isCompatible 为 false 的候选不参与选取
    func testResolveExcludesIncompatibleInstallations() async throws {
        let incompatible21 = makeInstallation(path: "/opt/java/21-broken/bin/java", major: 21, isCompatible: false)
        let compatible17 = makeInstallation(path: "/opt/java/17/bin/java", major: 17)
        let resolver = DefaultJavaResolver(repository: FakeJavaRepository(installed: [incompatible21, compatible17]))

        let selected = try await resolver.resolve(JavaRequirement(minimumMajor: 8))
        XCTAssertEqual(selected.executablePath, "/opt/java/17/bin/java")

        // 唯一的候选不可用时走 noCompatibleVersion 分支
        let resolverWithoutUsable = DefaultJavaResolver(repository: FakeJavaRepository(installed: [incompatible21]))
        do {
            _ = try await resolverWithoutUsable.resolve(JavaRequirement(minimumMajor: 8))
            XCTFail("唯一候选不可用时不应返回安装")
        } catch let error as JavaResolutionError {
            guard case .noCompatibleVersion = error else {
                return XCTFail("期望 .noCompatibleVersion，实际为 \(error)")
            }
        } catch {
            XCTFail("期望 JavaResolutionError，实际为 \(error)")
        }
    }

    /// 首次取用为空时降级为强制重扫，调用顺序为 installed -> refresh -> save
    func testResolveFallsBackToRefreshWhenInstalledIsEmpty() async throws {
        let java21 = makeInstallation(path: "/opt/java/21/bin/java", major: 21)
        let repository = FakeJavaRepository(installed: [], refresh: [java21])
        let resolver = DefaultJavaResolver(repository: repository)

        let selected = try await resolver.resolve(JavaRequirement(minimumMajor: 21))
        XCTAssertEqual(selected.executablePath, "/opt/java/21/bin/java")
        XCTAssertEqual(repository.callLog, ["installed", "refresh", "save"])
    }

    /// 两次取用均为空 -> scanFailed
    func testResolveThrowsScanFailedWhenBothLookupsAreEmpty() async throws {
        let repository = FakeJavaRepository(installed: [], refresh: [])
        let resolver = DefaultJavaResolver(repository: repository)

        do {
            _ = try await resolver.resolve(JavaRequirement(minimumMajor: 8))
            XCTFail("两次取用均为空时应抛出 scanFailed")
        } catch let error as JavaResolutionError {
            guard case .scanFailed = error else {
                return XCTFail("期望 .scanFailed，实际为 \(error)")
            }
        } catch {
            XCTFail("期望 JavaResolutionError，实际为 \(error)")
        }
        XCTAssertEqual(repository.callLog, ["installed", "refresh"], "候选为空时不应调用 save")
    }

    /// 已发现 Java 但全部版本号不可解析（majorVersion == 0）-> notFound
    func testResolveThrowsNotFoundWhenAllVersionsAreUnparsable() async throws {
        let unparsable = makeInstallation(path: "/opt/java/unknown/bin/java", major: 0)
        let repository = FakeJavaRepository(installed: [unparsable])
        let resolver = DefaultJavaResolver(repository: repository)

        do {
            _ = try await resolver.resolve(JavaRequirement(minimumMajor: 8))
            XCTFail("版本号全部不可解析时应抛出 notFound")
        } catch let error as JavaResolutionError {
            guard case .notFound = error else {
                return XCTFail("期望 .notFound，实际为 \(error)")
            }
        } catch {
            XCTFail("期望 JavaResolutionError，实际为 \(error)")
        }
        XCTAssertTrue(repository.saved.isEmpty)
    }

    /// 选取结果经 repository.save 回写，供下次快速命中
    func testResolveSavesSelectedInstallation() async throws {
        let java21 = makeInstallation(path: "/opt/java/21/bin/java", major: 21)
        let java17 = makeInstallation(path: "/opt/java/17/bin/java", major: 17)
        let repository = FakeJavaRepository(installed: [java17, java21])
        let resolver = DefaultJavaResolver(repository: repository)

        let selected = try await resolver.resolve(JavaRequirement(minimumMajor: 8))
        XCTAssertEqual(repository.saved.count, 1)
        XCTAssertEqual(repository.saved.first, selected)
    }

    /// 解析失败原因面向用户可读（非空且点明最低版本）
    func testResolutionErrorDescriptionsAreReadable() async {
        let requirement = JavaRequirement(mcVersion: "1.20.6")
        let notFound = JavaResolutionError.notFound(requirement)
        XCTAssertTrue(notFound.errorDescription?.contains("21") == true)

        let noCompatible = JavaResolutionError.noCompatibleVersion(
            requirement: requirement,
            available: [makeInstallation(path: "/opt/java/17/bin/java", major: 17)]
        )
        XCTAssertTrue(noCompatible.errorDescription?.contains("17") == true)

        XCTAssertFalse(JavaResolutionError.scanFailed.errorDescription?.isEmpty ?? true)
    }

    // MARK: JavaArchitecture 映射

    /// 由 PCLCore 的 Architecture 转换；fatFile 归并为 universal
    func testJavaArchitectureMappingFromPCLCoreArchitecture() async {
        XCTAssertEqual(JavaArchitecture(.arm64), .arm64)
        XCTAssertEqual(JavaArchitecture(.x64), .x64)
        XCTAssertEqual(JavaArchitecture(.fatFile), .universal)
        XCTAssertEqual(JavaArchitecture(.unknown), .unknown)
        XCTAssertEqual(JavaArchitecture.system, JavaArchitecture(Architecture.system))
    }

    /// 由架构字符串转换；无法识别时归为 unknown
    func testJavaArchitectureMappingFromString() async {
        XCTAssertEqual(JavaArchitecture(rawArchitecture: "arm64"), .arm64)
        XCTAssertEqual(JavaArchitecture(rawArchitecture: "aarch64"), .arm64)
        XCTAssertEqual(JavaArchitecture(rawArchitecture: "arm"), .arm64)
        XCTAssertEqual(JavaArchitecture(rawArchitecture: "x64"), .x64)
        XCTAssertEqual(JavaArchitecture(rawArchitecture: "x86_64"), .x64)
        XCTAssertEqual(JavaArchitecture(rawArchitecture: "amd64"), .x64)
        XCTAssertEqual(JavaArchitecture(rawArchitecture: "x86"), .x64)
        XCTAssertEqual(JavaArchitecture(rawArchitecture: "universal"), .universal)
        XCTAssertEqual(JavaArchitecture(rawArchitecture: "fat"), .universal)
        XCTAssertEqual(JavaArchitecture(rawArchitecture: "riscv64"), .unknown)
    }

    /// isNative：universal / unknown / 本机架构为原生，其余需转译
    func testJavaArchitectureNativeFlag() async {
        XCTAssertTrue(nativeArchitecture.isNative)
        XCTAssertTrue(JavaArchitecture.universal.isNative)
        XCTAssertTrue(JavaArchitecture.unknown.isNative)
        XCTAssertFalse(foreignArchitecture.isNative)
    }

    // MARK: JavaInstallation 转换

    /// 由 JavaInfo 转换：路径、版本、架构字符串归一化、isJDK 不可得
    func testInstallationFromJavaInfoMapsFields() async {
        let info = JavaInfo(
            path: "/Library/Java/21/bin/java",
            majorVersion: 21,
            fullVersion: "21.0.2",
            architecture: "aarch64",
            vendor: "Eclipse Adoptium",
            isValid: true
        )
        let installation = JavaInstallation(info)

        XCTAssertEqual(installation.executablePath, "/Library/Java/21/bin/java")
        XCTAssertEqual(installation.majorVersion, 21)
        XCTAssertEqual(installation.fullVersion, "21.0.2")
        XCTAssertEqual(installation.architecture, .arm64)
        XCTAssertEqual(installation.vendor, "Eclipse Adoptium")
        XCTAssertTrue(installation.isCompatible)
        XCTAssertNil(installation.isJDK, "JavaInfo 未携带 JDK 信息，转换后应为 nil")
        XCTAssertEqual(installation.id, "/Library/Java/21/bin/java")
    }

    /// 由 JavaInfo 转换：架构未识别 / 版本为 0 / isValid 为 false 均判为不可用
    func testInstallationFromJavaInfoFlagsIncompatible() async {
        let unknownArch = JavaInfo(path: "/a/java", majorVersion: 21, fullVersion: "21", architecture: "mips", vendor: nil, isValid: true)
        XCTAssertEqual(JavaInstallation(unknownArch).architecture, .unknown)
        XCTAssertFalse(JavaInstallation(unknownArch).isCompatible)

        let zeroVersion = JavaInfo(path: "/b/java", majorVersion: 0, fullVersion: "未知", architecture: "arm64", vendor: nil, isValid: true)
        XCTAssertFalse(JavaInstallation(zeroVersion).isCompatible)

        let invalid = JavaInfo(path: "/c/java", majorVersion: 21, fullVersion: "21", architecture: "arm64", vendor: nil, isValid: false)
        XCTAssertFalse(JavaInstallation(invalid).isCompatible)
    }

    /// 由 JavaVirtualMachine 转换：arch / version / displayVersion / implementor / isJdk 的字段映射
    func testInstallationFromJavaVirtualMachineMapsFields() async {
        let vm = JavaVirtualMachine(
            arch: .fatFile,
            version: 21,
            displayVersion: "21.0.2",
            implementor: "Oracle Corporation",
            executableURL: URL(fileURLWithPath: "/Library/Java/21/bin/java"),
            callMethod: .direct,
            isJdk: true
        )
        let installation = JavaInstallation(vm)

        XCTAssertEqual(installation.executablePath, "/Library/Java/21/bin/java")
        XCTAssertEqual(installation.majorVersion, 21)
        XCTAssertEqual(installation.fullVersion, "21.0.2")
        XCTAssertEqual(installation.architecture, .universal, "fatFile 应归并为 universal")
        XCTAssertEqual(installation.vendor, "Oracle Corporation")
        XCTAssertTrue(installation.isCompatible)
        XCTAssertEqual(installation.isJDK, true)
    }

    /// 由 JavaVirtualMachine 转换：错误占位 / callMethod 为 incompatible / 版本为 0 均判为不可用
    func testInstallationFromJavaVirtualMachineFlagsIncompatible() async {
        let errorPlaceholder = JavaVirtualMachine(
            arch: .arm64,
            version: 21,
            displayVersion: "错误",
            executableURL: URL(fileURLWithPath: "/a/java"),
            callMethod: .direct,
            _isError: true
        )
        XCTAssertFalse(JavaInstallation(errorPlaceholder).isCompatible)

        let incompatible = JavaVirtualMachine(
            arch: .arm64,
            version: 21,
            displayVersion: "21",
            executableURL: URL(fileURLWithPath: "/b/java"),
            callMethod: .incompatible
        )
        XCTAssertFalse(JavaInstallation(incompatible).isCompatible)

        let zeroVersion = JavaVirtualMachine(
            arch: .arm64,
            version: 0,
            displayVersion: "未知",
            executableURL: URL(fileURLWithPath: "/c/java"),
            callMethod: .direct
        )
        XCTAssertFalse(JavaInstallation(zeroVersion).isCompatible)

        // transition（Rosetta 转译）仍视为可用，仅在排序时降权
        let rosetta = JavaVirtualMachine(
            arch: .x64,
            version: 17,
            displayVersion: "17.0.9",
            executableURL: URL(fileURLWithPath: "/d/java"),
            callMethod: .transition
        )
        let rosettaInstallation = JavaInstallation(rosetta)
        XCTAssertTrue(rosettaInstallation.isCompatible)
        XCTAssertEqual(rosettaInstallation.architecture, .x64)
        XCTAssertNil(rosettaInstallation.isJDK)
    }

    /// id 以标准化后的可执行文件路径为准，同一份 Java 的不同写法应收敛为同一标识
    func testInstallationIdentityUsesStandardizedPath() async {
        let plain = JavaInstallation(
            executableURL: URL(fileURLWithPath: "/opt/java/21/bin/java"),
            majorVersion: 21,
            fullVersion: "21",
            architecture: .universal,
            isCompatible: true
        )
        let withDotComponent = JavaInstallation(
            executableURL: URL(fileURLWithPath: "/opt/java/21/./bin/java"),
            majorVersion: 21,
            fullVersion: "21",
            architecture: .universal,
            isCompatible: true
        )
        XCTAssertEqual(plain.id, withDotComponent.id)
    }
}
