//
//  ModuleRegistryTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//  1. 重复注册必须报错，且报错发生在被重复模块执行注册逻辑之前（否则第二个模块会覆盖第一个
//     写进上下文的能力，形成「谁后注册谁生效」的隐性行为）；
//  2. 注册成功的能力必须能从 `ModuleContext` 解析出来，且解析受泛型类型约束
//     （同名不同类型的键不得互相串读）；
//  3. `ModuleContext` 必须是引用类型：`SLModule.register(in:)` 传入的是引用，
//     模块内部写入的能力必须对注册表持有者可见——若退化为 struct，能力会写进栈上副本，
//     注册「成功」但解析不到，是静默失效；
//  4. 注册中途抛错时，该模块不得被计入 `registeredIdentifiers`，后续模块不再尝试；
//  5. `AppModuleBootstrap.makeRegistry()` 这条真实装配路径必须能注册成功
//     （它内部 catch 掉错误只打日志，装配失败不会崩溃，只能靠测试发现）。
//
//  被测：Core/Module/SLModule.swift、Core/Module/ModuleRegistry.swift
//

import XCTest
@testable import qwq

// MARK: - 测试替身

/// 注册失败用的哨兵错误，用于区分「模块自己抛的错」与「注册表抛的错」。
private struct StubModuleError: Error {}

/// 最小 `SLModule` 替身：记录调用次数、收到的上下文对象身份，并按需写入一个能力或抛错。
private final class StubModule: SLModule {

    let identifier: String

    private let capabilityKey: String
    private let capabilityValue: String?
    private let failure: Error?

    /// `register(in:)` 被调用的次数
    private(set) var registerCallCount = 0
    /// 收到的上下文对象（弱引用，用于断言引用语义）
    private(set) weak var receivedContext: ModuleContext?

    init(identifier: String,
         capabilityKey: String = "stub.value",
         capabilityValue: String? = nil,
         failure: Error? = nil) {
        self.identifier = identifier
        self.capabilityKey = capabilityKey
        self.capabilityValue = capabilityValue
        self.failure = failure
    }

    func register(in context: ModuleContext) throws {
        registerCallCount += 1
        receivedContext = context

        if let failure { throw failure }
        if let capabilityValue {
            context.register(capabilityValue, for: ModuleCapabilityKey<String>(capabilityKey))
        }
    }
}

// MARK: - 测试

final class ModuleRegistryTests: XCTestCase {

    // MARK: 注册与清单

    /// 注册后模块标识按注册顺序进入清单，count 与清单长度一致
    func testRegisterRecordsIdentifiersInOrder() throws {
        let registry = ModuleRegistry()
        XCTAssertEqual(registry.count, 0)
        XCTAssertTrue(registry.registeredIdentifiers.isEmpty)

        try registry.register([StubModule(identifier: "alpha"), StubModule(identifier: "beta")])

        XCTAssertEqual(registry.count, 2)
        XCTAssertEqual(registry.registeredIdentifiers, ["alpha", "beta"])
    }

    /// 空清单是合法输入：不抛错、不产生任何登记
    func testRegisterEmptyListIsNoOp() throws {
        let registry = ModuleRegistry()
        try registry.register([])
        XCTAssertEqual(registry.count, 0)
        XCTAssertTrue(registry.registeredIdentifiers.isEmpty)
    }

    /// 跨批次重复注册：抛 duplicateIdentifier，且第二个模块的 register 完全不被执行
    func testDuplicateIdentifierAcrossBatchesThrowsAndSkipsRegistration() throws {
        let registry = ModuleRegistry()
        let first = StubModule(identifier: "dup", capabilityValue: "first")
        let second = StubModule(identifier: "dup", capabilityValue: "second")
        try registry.register([first])

        XCTAssertThrowsError(try registry.register([second])) { error in
            guard case ModuleRegistryError.duplicateIdentifier(let identifier) = error else {
                return XCTFail("应抛 duplicateIdentifier，实际为 \(error)")
            }
            XCTAssertEqual(identifier, "dup")
        }

        XCTAssertEqual(first.registerCallCount, 1)
        XCTAssertEqual(second.registerCallCount, 0, "重复模块不得执行注册逻辑，否则会覆盖先注册的能力")
        XCTAssertEqual(registry.count, 1)
        // 先注册的能力未被覆盖
        XCTAssertEqual(registry.context.resolve(ModuleCapabilityKey<String>("stub.value")), "first")
    }

    /// 同一批次内重复：抛错时首个模块已生效且不回滚（装配期由调用方记录日志）
    func testDuplicateIdentifierWithinSameBatchKeepsFirstRegistration() {
        let registry = ModuleRegistry()
        let first = StubModule(identifier: "same", capabilityValue: "kept")
        let second = StubModule(identifier: "same", capabilityValue: "dropped")

        XCTAssertThrowsError(try registry.register([first, second]))

        XCTAssertEqual(registry.registeredIdentifiers, ["same"])
        XCTAssertEqual(second.registerCallCount, 0)
        XCTAssertEqual(registry.context.resolve(ModuleCapabilityKey<String>("stub.value")), "kept")
    }

    /// 模块自行抛错：错误原样上抛，该模块不登记，批次内后续模块不再尝试
    func testModuleThrowingDuringRegisterIsNotRecordedAndAbortsBatch() {
        let registry = ModuleRegistry()
        let ok = StubModule(identifier: "ok")
        let failing = StubModule(identifier: "boom", failure: StubModuleError())
        let after = StubModule(identifier: "after")

        XCTAssertThrowsError(try registry.register([ok, failing, after])) { error in
            XCTAssertTrue(error is StubModuleError, "模块抛出的错误应原样上抛，实际为 \(error)")
        }

        XCTAssertEqual(registry.registeredIdentifiers, ["ok"])
        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(failing.registerCallCount, 1)
        XCTAssertEqual(after.registerCallCount, 0, "失败模块之后的模块不应再被尝试")
    }

    // MARK: 能力解析

    /// 注册后能力可解析；`require` 返回同一份值
    func testCapabilityIsResolvableAfterRegister() throws {
        let registry = ModuleRegistry()
        try registry.register([StubModule(identifier: "m", capabilityKey: "demo", capabilityValue: "值")])

        let key = ModuleCapabilityKey<String>("demo")
        XCTAssertEqual(registry.context.resolve(key), "值")
        XCTAssertEqual(try registry.context.require(key), "值")
        XCTAssertEqual(registry.context.registeredCapabilityCount, 1)
    }

    /// 未注册的能力：resolve 返回 nil，require 抛 capabilityNotFound 且带键名
    func testRequireThrowsWhenCapabilityMissing() {
        let context = ModuleContext()
        let key = ModuleCapabilityKey<Int>("java.resolver")

        XCTAssertNil(context.resolve(key))

        XCTAssertThrowsError(try context.require(key)) { error in
            guard case ModuleRegistryError.capabilityNotFound(let name) = error else {
                return XCTFail("应抛 capabilityNotFound，实际为 \(error)")
            }
            XCTAssertEqual(name, "java.resolver")
            XCTAssertTrue(error.localizedDescription.contains("java.resolver"),
                          "错误描述必须带键名，否则启动期缺能力时无法定位")
        }
    }

    /// 同名键写入两次：后写覆盖先写，条目数不增长
    func testRegisteringSameKeyNameOverwritesValue() throws {
        let registry = ModuleRegistry()
        try registry.register([
            StubModule(identifier: "a", capabilityKey: "settings.store", capabilityValue: "旧"),
            StubModule(identifier: "b", capabilityKey: "settings.store", capabilityValue: "新")
        ])

        XCTAssertEqual(registry.context.registeredCapabilityCount, 1)
        XCTAssertEqual(registry.context.resolve(ModuleCapabilityKey<String>("settings.store")), "新")
    }

    /// 键按「名称 + 泛型类型」定址：同名不同类型的读取不得互相串读
    func testCapabilityKeyIsTypeConstrained() {
        let context = ModuleContext()
        context.register("文本", for: ModuleCapabilityKey<String>("shared.key"))

        XCTAssertEqual(context.registeredCapabilityCount, 1)
        XCTAssertEqual(context.resolve(ModuleCapabilityKey<String>("shared.key")), "文本")
        // 该条目确实存在，但以 Int 读取时必须落空，而不是拿到 String 的桥接值
        XCTAssertNil(context.resolve(ModuleCapabilityKey<Int>("shared.key")))
        XCTAssertThrowsError(try context.require(ModuleCapabilityKey<Int>("shared.key")))
    }

    // MARK: 引用语义

    /// 模块收到的上下文必须与注册表持有的是同一个对象
    func testModuleReceivesSameContextInstanceAsRegistry() throws {
        let registry = ModuleRegistry()
        let module = StubModule(identifier: "m")
        try registry.register([module])

        XCTAssertNotNil(module.receivedContext)
        XCTAssertTrue(module.receivedContext === registry.context,
                      "ModuleContext 必须是引用类型；退化为值类型时模块内的注册会写进副本而静默失效")
    }

    /// 模块内写入的能力对「另行持有的同一上下文引用」可见
    func testCapabilityWrittenByModuleIsVisibleThroughAliasedReference() throws {
        let registry = ModuleRegistry()
        let alias = registry.context
        try registry.register([StubModule(identifier: "m", capabilityValue: "可见")])

        XCTAssertEqual(alias.registeredCapabilityCount, 1)
        XCTAssertEqual(alias.resolve(ModuleCapabilityKey<String>("stub.value")), "可见")
    }

    // MARK: 错误描述

    /// 两个错误 case 都有面向调用方的中文描述
    func testRegistryErrorDescriptionsAreLocalized() {
        let duplicate = ModuleRegistryError.duplicateIdentifier("mod.browser")
        XCTAssertEqual(duplicate.errorDescription, "重复注册模块：mod.browser")
        XCTAssertEqual(duplicate.localizedDescription, "重复注册模块：mod.browser")

        let missing = ModuleRegistryError.capabilityNotFound("skin.service")
        XCTAssertEqual(missing.errorDescription, "未找到已注册的能力：skin.service")
        XCTAssertEqual(missing.localizedDescription, "未找到已注册的能力：skin.service")
    }

    // MARK: 装配清单

    /// 真实装配路径：`AppModuleBootstrap.makeRegistry()` 必须把 settings 模块注册成功。
    /// 该方法内 catch 掉注册错误只打日志，装配失败不会崩溃，因此只能靠本用例发现。
    func testBootstrapRegistryRegistersSettingsModule() {
        let registry = AppModuleBootstrap.makeRegistry()

        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(registry.registeredIdentifiers, ["settings"])
        XCTAssertNotNil(registry.context.appSettingsStore(),
                        "SettingsModule 注册后必须能从上下文取到 AppSettingsStore")
        XCTAssertTrue(registry.context.appSettingsStore() === AppSettingsStore.shared,
                      "上下文里的设置存储必须与既有单例同一实例，否则出现第二套设置状态")
    }
}
