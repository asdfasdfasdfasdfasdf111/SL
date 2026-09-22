//
//  DownloadAdapterTests.swift
//  qwqTests
//
//  这份测试在保护什么行为：
//  1. 候选源列表的契约（`DownloadSourceResolver`）：
//     - 主源（`DownloadRequest.url`）恒为第一个候选，列表永不为空；
//     - `SequentialDownloadSourceResolver` 按给定顺序追加备用源并去重
//       （含「备用源与主源相同」「备用源自身重复」两种）；
//     - 协议默认实现不做任何解析，只回传主源；
//  2. `DefaultDownloadSourceResolver` 的单源语义：非官方域名族、用户手动限定
//     「仅官方 / 仅镜像」、非 http(s) 请求，都只返回**一个**候选。
//     悄悄跨源兜底会突破用户的源选择，属于行为回归；
//  3. `NetDownloaderDownloadEngine` 的提交前置校验：
//     目标非本地文件路径、候选源为空都必须**提交前**抛错，不得登记任务；
//  4. 失败文案回放接口 `legacyFailureReason(taskID:)` 的边界：
//     非失败终态（成功/取消）与未知 taskID 一律返回 nil；
//  5. 终态回放：任务已终结后再 `observe` 只能拿到终态，未知 taskID 的流直接结束；
//  6. `DefaultDownloadVerifier.checker(for:)` 的映射规则：sha256 优先于 sha1、
//     expectedSize → actualSize、无期望值时 actualSize 为 -1（「存在即跳过」语义）。
//
//  被测：Core/Download/DownloadSourceResolver.swift、Adapters/DefaultDownloadSourceResolver.swift、
//        Adapters/NetDownloaderDownloadEngine.swift、Adapters/DefaultDownloadVerifier.swift
//

import XCTest
@testable import qwq

// MARK: - 测试替身

/// 不实现 `candidateURLs`，用于验证协议默认实现
private struct PassthroughResolver: DownloadSourceResolver {}

/// 永远不给候选源的解析器：用于验证引擎的 sourceUnavailable 分支
private struct EmptyResolver: DownloadSourceResolver {
    func candidateURLs(for request: DownloadRequest) async -> [URL] { [] }
}

// MARK: - 测试

final class DownloadAdapterTests: XCTestCase {

    private static let officialHost = "piston-meta.mojang.com"
    private static let mirrorHost = "bmclapi2.bangbang93.com"

    override func setUp() {
        super.setUp()
        // 单源断言依赖「用户已手动限定源」，默认值由这里显式设置并按 tearDown 还原
        AppSettings.shared.fileDownloadSource = .official
    }

    override func tearDown() {
        AppSettings.shared.fileDownloadSource = .both
        super.tearDown()
    }

    // MARK: - 构造辅助

    private func makeDestination() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qwqTests-dest-\(UUID().uuidString)")
    }

    private func makeRequest(host: String? = officialHost,
                             scheme: String = "https",
                             path: String = "/mc/game/version_manifest.json",
                             destination: URL? = nil) -> DownloadRequest {
        let string: String
        if let host {
            string = "\(scheme)://\(host)\(path)"
        } else {
            string = "\(scheme)://\(path.drop(while: { $0 == "/" }))"
        }
        return DownloadRequest(url: URL(string: string)!,
                               destinationURL: destination ?? makeDestination())
    }

    private func collect(_ stream: AsyncStream<DownloadState>) async -> [DownloadState] {
        var states: [DownloadState] = []
        for await state in stream { states.append(state) }
        return states
    }

    /// 已存在的目标文件 + 无校验要求 → 旧引擎预检判定「可用」，不会发起任何网络请求
    private func makeSkippableDestination() throws -> URL {
        let url = makeDestination()
        try Data("placeholder".utf8).write(to: url)
        return url
    }

    // MARK: - SequentialDownloadSourceResolver / 协议默认实现

    /// 无备用源时只返回主源一个候选
    func testSequentialResolverWithoutFallbacksReturnsSingleCandidate() async {
        let request = makeRequest()
        let candidates = await SequentialDownloadSourceResolver().candidateURLs(for: request)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first, request.url)
    }

    /// 备用源按给定顺序追加在主源之后
    func testSequentialResolverAppendsFallbacksInOrder() async {
        let request = makeRequest()
        let first = URL(string: "https://mirror-a.example.com/a.jar")!
        let second = URL(string: "https://mirror-b.example.com/a.jar")!

        let candidates = await SequentialDownloadSourceResolver(fallbacks: [first, second])
            .candidateURLs(for: request)

        XCTAssertEqual(candidates, [request.url, first, second])
    }

    /// 重复的备用源只保留首次出现
    func testSequentialResolverDeduplicatesRepeatedFallbacks() async {
        let request = makeRequest()
        let first = URL(string: "https://mirror-a.example.com/a.jar")!
        let second = URL(string: "https://mirror-b.example.com/a.jar")!

        let candidates = await SequentialDownloadSourceResolver(fallbacks: [first, second, first])
            .candidateURLs(for: request)

        XCTAssertEqual(candidates, [request.url, first, second])
    }

    /// 备用源与主源相同时不得重复追加
    func testSequentialResolverDoesNotDuplicatePrimary() async {
        let request = makeRequest()
        let other = URL(string: "https://mirror.example.com/a.jar")!

        let candidates = await SequentialDownloadSourceResolver(fallbacks: [request.url, other])
            .candidateURLs(for: request)

        XCTAssertEqual(candidates, [request.url, other])
    }

    /// 协议默认实现：不做任何解析，只回传主源
    func testProtocolDefaultImplementationReturnsSinglePrimaryCandidate() async {
        let request = makeRequest()
        let candidates = await PassthroughResolver().candidateURLs(for: request)

        XCTAssertEqual(candidates, [request.url])
    }

    /// 不变量：任何请求都拿得到非空候选列表，且主源恒在首位
    func testCandidateListAlwaysKeepsPrimaryFirstAndNonEmpty() async {
        let requests = [
            makeRequest(),
            makeRequest(host: Self.mirrorHost),
            makeRequest(host: nil, scheme: "file"),
            makeRequest(host: "localhost", scheme: "http", path: "/a/b/c.jar")
        ]
        let resolvers: [any DownloadSourceResolver] = [
            SequentialDownloadSourceResolver(),
            SequentialDownloadSourceResolver(fallbacks: [URL(string: "https://x.example.com/f")!]),
            PassthroughResolver()
        ]

        for resolver in resolvers {
            for request in requests {
                let candidates = await resolver.candidateURLs(for: request)
                XCTAssertFalse(candidates.isEmpty, "候选列表为空时调用方只能报 sourceUnavailable")
                XCTAssertEqual(candidates.first, request.url, "主源必须排在尝试顺序首位")
            }
        }
    }

    // MARK: - DefaultDownloadSourceResolver（单源语义）

    /// 非官方域名族（镜像站）：无论设置如何都只返回一个候选，不做反向兜底
    func testNonOfficialHostReturnsSingleCandidate() async {
        let request = makeRequest(host: Self.mirrorHost, path: "/assets/ab/abcdef")

        let candidates = await DefaultDownloadSourceResolver().candidateURLs(for: request)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first, request.url)
    }

    /// 用户手动限定「仅官方」：官方域名请求也只返回一个候选
    func testManualOfficialOnlyOptionReturnsSingleCandidate() async {
        AppSettings.shared.fileDownloadSource = .official
        let request = makeRequest()

        let candidates = await DefaultDownloadSourceResolver().candidateURLs(for: request)

        XCTAssertEqual(candidates, [request.url])
    }

    /// 用户手动限定「仅镜像」：官方域名请求同样只返回一个候选
    func testManualMirrorOptionReturnsSingleCandidate() async {
        AppSettings.shared.fileDownloadSource = .mirror
        let request = makeRequest()

        let candidates = await DefaultDownloadSourceResolver().candidateURLs(for: request)

        XCTAssertEqual(candidates, [request.url])
    }

    /// 非 http(s) 请求（无 host）不参与镜像合成，只返回主源
    func testRequestWithoutHostReturnsSingleCandidate() async {
        let request = DownloadRequest(url: URL(fileURLWithPath: "/tmp/local.jar"),
                                      destinationURL: makeDestination())

        let candidates = await DefaultDownloadSourceResolver().candidateURLs(for: request)

        XCTAssertEqual(candidates, [request.url])
    }

    // MARK: - 引擎提交前置校验

    /// 目标不是本地文件路径：提交阶段即抛错，错误描述带上原始地址便于定位
    func testSubmitRejectsNonFileDestination() async {
        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver())
        let remote = URL(string: "https://example.invalid/out.jar")!
        let request = DownloadRequest(url: remote, destinationURL: remote)

        do {
            _ = try await engine.submit(request)
            XCTFail("目标不是本地文件路径时必须拒绝提交")
        } catch let error as DownloadError {
            guard case .unknown(let reason) = error else {
                return XCTFail("应为 unknown（携带原始描述），实际为 \(error)")
            }
            XCTAssertTrue(reason.contains(remote.absoluteString),
                          "错误描述必须带上原始目标地址，否则排查无处下手")
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    /// 候选源为空：提交阶段抛 sourceUnavailable，不登记任务
    func testSubmitThrowsSourceUnavailableWhenResolverReturnsNoCandidate() async {
        let engine = NetDownloaderDownloadEngine(resolver: EmptyResolver())
        let request = makeRequest()

        do {
            _ = try await engine.submit(request)
            XCTFail("候选源为空时必须抛 sourceUnavailable，否则任务会停在无法推进的状态")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .sourceUnavailable)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    // MARK: - 引擎状态流与终态回放

    /// 目标文件已存在且无校验要求 → 预检直接跳过，状态流以 completed 收尾，全程无网络
    func testSubmitCompletesWithoutNetworkWhenDestinationAlreadySatisfiesChecker() async throws {
        let destination = try makeSkippableDestination()
        defer { try? FileManager.default.removeItem(at: destination) }

        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver(),
                                                replaceMethod: .skip)
        // 该地址不会被访问：预检跳过发生在任何请求之前
        let request = DownloadRequest(url: URL(string: "https://example.invalid/never-requested")!,
                                      destinationURL: destination)

        let handle = try await engine.submit(request)
        let states = await collect(engine.observe(taskID: handle.taskID))

        XCTAssertEqual(handle.destination, destination)
        XCTAssertFalse(states.isEmpty, "状态流至少应给出终态")
        XCTAssertEqual(states.last, .completed, "已存在且校验通过属成功路径")
        XCTAssertFalse(states.contains { $0.isTerminal && $0 != .completed },
                       "跳过已存在文件不得产生失败/取消终态")
    }

    /// 成功终态的 legacyFailureReason 必须为 nil（只有失败终态才携带旧链路文案）
    func testLegacyFailureReasonIsNilForCompletedTask() async throws {
        let destination = try makeSkippableDestination()
        defer { try? FileManager.default.removeItem(at: destination) }

        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver(),
                                                replaceMethod: .skip)
        let request = DownloadRequest(url: URL(string: "https://example.invalid/never-requested")!,
                                      destinationURL: destination)

        let handle = try await engine.submit(request)
        _ = await collect(engine.observe(taskID: handle.taskID))

        XCTAssertNil(engine.legacyFailureReason(taskID: handle.taskID),
                     "非失败终态携带失败文案会让调用方把成功当失败展示")
    }

    /// 失败终态必须原样回放**旧链路错误的原始描述**，而不是结构化 `DownloadError` 的归一化文案。
    ///
    /// 构造方式（确定性、全程不触网）：目标文件已存在 + `replaceMethod = .throw`，
    /// 旧引擎的预检会直接抛 `NetDownloadError.fileExists`，因此这是无需网络后端就能稳定复现的失败终态。
    /// 期望值取自旧错误类型自身的 `errorDescription`，断言的是「与旧描述同源」而非某个手写字符串。
    func testLegacyFailureReasonReplaysLegacyErrorDescriptionOnFailure() async throws {
        let destination = try makeSkippableDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let fileName = destination.lastPathComponent

        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver(),
                                                replaceMethod: .throw)
        let request = DownloadRequest(url: URL(string: "https://example.invalid/never-requested")!,
                                      destinationURL: destination)

        let handle = try await engine.submit(request)
        let states = await collect(engine.observe(taskID: handle.taskID))

        guard let legacyDescription = NetDownloadError.fileExists(fileName).errorDescription else {
            return XCTFail("NetDownloadError.fileExists 必须提供 errorDescription")
        }
        guard let terminal = states.last, case .failed(let error) = terminal else {
            return XCTFail("目标已存在且 replaceMethod = .throw 时必须失败终结，实际状态流：\(states)")
        }

        XCTAssertEqual(error, .unknown(legacyDescription),
                       "归类不出时落入 unknown 并保留原始描述，不得丢信息")
        XCTAssertEqual(engine.legacyFailureReason(taskID: handle.taskID),
                       legacyDescription,
                       "legacyFailureReason 必须逐字回放旧链路错误的 errorDescription")
        XCTAssertEqual(error.errorDescription, legacyDescription,
                       "本用例的原始描述不含 HTTP 状态码等可归一化信息，两侧文案应完全相同")
    }

    /// 未知 taskID 一律返回 nil
    func testLegacyFailureReasonIsNilForUnknownTaskID() async {
        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver())

        XCTAssertNil(engine.legacyFailureReason(taskID: UUID()))
    }

    /// 任务终结后再观察：只回放终态
    func testLateObserverOnlyReceivesTerminalState() async throws {
        let destination = try makeSkippableDestination()
        defer { try? FileManager.default.removeItem(at: destination) }

        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver(),
                                                replaceMethod: .skip)
        let request = DownloadRequest(url: URL(string: "https://example.invalid/never-requested")!,
                                      destinationURL: destination)

        let handle = try await engine.submit(request)
        let live = await collect(engine.observe(taskID: handle.taskID))
        XCTAssertEqual(live.last, .completed)

        let replay = await collect(engine.observe(taskID: handle.taskID))

        XCTAssertEqual(replay, [.completed],
                       "终结后重新订阅必须能拿到终态，否则「下载结束后才挂观察者」的调用方会永久等不到结果")
    }

    /// 未知 taskID 的观察流不含任何事件并正常结束
    func testObserveUnknownTaskIDFinishesWithoutEvents() async {
        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver())

        let states = await collect(engine.observe(taskID: UUID()))

        XCTAssertTrue(states.isEmpty)
    }

    /// 取消未知 taskID 是 no-op，不得崩溃；引擎缺省装配 DefaultDownloadVerifier
    func testCancelUnknownTaskIsNoOp() async {
        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver())

        await engine.cancel(taskID: UUID())

        XCTAssertNotNil(engine.verifier as? DefaultDownloadVerifier,
                        "引擎缺省应装配 DefaultDownloadVerifier，调用方才能在预检阶段复用同一套校验语义")
    }

    /// 连续提交拿到互不相同的 taskID
    func testConsecutiveSubmitsGetDistinctTaskIDs() async throws {
        let first = try makeSkippableDestination()
        let second = try makeSkippableDestination()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let engine = NetDownloaderDownloadEngine(resolver: SequentialDownloadSourceResolver(),
                                                replaceMethod: .skip)
        let handleA = try await engine.submit(DownloadRequest(url: URL(string: "https://example.invalid/a")!,
                                                              destinationURL: first))
        let handleB = try await engine.submit(DownloadRequest(url: URL(string: "https://example.invalid/b")!,
                                                              destinationURL: second))

        XCTAssertNotEqual(handleA.taskID, handleB.taskID)
        XCTAssertEqual(handleA.destination, first)
        XCTAssertEqual(handleB.destination, second)

        _ = await collect(engine.observe(taskID: handleA.taskID))
        _ = await collect(engine.observe(taskID: handleB.taskID))
    }

    // MARK: - DefaultDownloadVerifier.checker(for:)

    /// sha256 优先于 sha1，两者都不会被丢进同一个 checker
    func testCheckerPrefersSha256OverSha1() async {
        let request = DownloadRequest(url: URL(string: "https://example.invalid/a.jar")!,
                                      destinationURL: makeDestination(),
                                      sha1: "a".repeated(40),
                                      sha256: "b".repeated(64))

        XCTAssertEqual(DefaultDownloadVerifier.checker(for: request).hash, "b".repeated(64))
    }

    /// 无 sha256 时回退到 sha1；空串视为未提供
    func testCheckerFallsBackToSha1AndIgnoresEmptyStrings() async {
        let sha1Only = DownloadRequest(url: URL(string: "https://example.invalid/a.jar")!,
                                       destinationURL: makeDestination(),
                                       sha1: "c".repeated(40),
                                       sha256: nil)
        XCTAssertEqual(DefaultDownloadVerifier.checker(for: sha1Only).hash, "c".repeated(40))

        let emptySha256 = DownloadRequest(url: URL(string: "https://example.invalid/a.jar")!,
                                          destinationURL: makeDestination(),
                                          sha1: "d".repeated(40),
                                          sha256: "")
        XCTAssertEqual(DefaultDownloadVerifier.checker(for: emptySha256).hash, "d".repeated(40))

        let bothEmpty = DownloadRequest(url: URL(string: "https://example.invalid/a.jar")!,
                                        destinationURL: makeDestination(),
                                        sha1: "",
                                        sha256: "")
        XCTAssertNil(DefaultDownloadVerifier.checker(for: bothEmpty).hash)
    }

    /// expectedSize → actualSize（必须相等）；无期望值时 actualSize 为 -1，即「存在即跳过」
    func testCheckerMapsExpectedSizeAndDefaultsToNoSizeRequirement() async {
        let sized = DownloadRequest(url: URL(string: "https://example.invalid/a.jar")!,
                                    destinationURL: makeDestination(),
                                    expectedSize: 4096)
        let sizedChecker = DefaultDownloadVerifier.checker(for: sized)
        XCTAssertEqual(sizedChecker.actualSize, 4096)
        XCTAssertEqual(sizedChecker.minSize, -1, "DownloadRequest 无 minSize 字段，必须保持不校验")
        XCTAssertFalse(sizedChecker.isJson, "DownloadRequest 无 isJson 字段，必须保持不校验")

        let unsized = DownloadRequest(url: URL(string: "https://example.invalid/a.jar")!,
                                      destinationURL: makeDestination())
        let unsizedChecker = DefaultDownloadVerifier.checker(for: unsized)
        XCTAssertEqual(unsizedChecker.actualSize, -1)
        XCTAssertTrue(unsizedChecker.canUseExistsFile,
                      "无校验要求时「存在即跳过」，canUseExistsFile 必须为 true")
    }

    /// 无校验要求的 checker 对已存在文件返回 nil（存在即可复用），对不存在文件返回描述文本
    func testCheckerSemanticsForExistingAndMissingFiles() async throws {
        let existing = try makeSkippableDestination()
        defer { try? FileManager.default.removeItem(at: existing) }

        let request = DownloadRequest(url: URL(string: "https://example.invalid/a.jar")!,
                                      destinationURL: existing)
        let checker = DefaultDownloadVerifier.checker(for: request)

        XCTAssertNil(checker.check(existing), "已存在文件在无校验要求时必须判定为可用")

        let missing = makeDestination()
        let failure = checker.check(missing)
        XCTAssertNotNil(failure, "文件不存在时必须给出失败描述，供上层映射为 DownloadError")
        XCTAssertTrue(failure?.contains("文件不存在") == true)
    }

    /// 校验器自身的失败映射：哈希不符 → checksumMismatch，文件不存在 → unknown
    func testVerifierMapsFailureDescriptions() async throws {
        let verifier = DefaultDownloadVerifier()
        let existing = try makeSkippableDestination()
        defer { try? FileManager.default.removeItem(at: existing) }

        let mismatched = FileChecker(actualSize: -1, hash: "e".repeated(40))
        XCTAssertThrowsError(try verifier.verify(fileAt: existing, checker: mismatched)) { error in
            XCTAssertEqual(error as? DownloadError, DownloadError.checksumMismatch)
        }

        let missing = makeDestination()
        let notFound = FileChecker(actualSize: -1, hash: nil)
        XCTAssertThrowsError(try verifier.verify(fileAt: missing, checker: notFound)) { error in
            guard case .unknown(let reason)? = error as? DownloadError else {
                return XCTFail("文件不存在应映射为 unknown，实际为 \(error)")
            }
            XCTAssertTrue(reason.contains("文件不存在"))
        }
    }
}

// MARK: - 覆盖率缺口（本文件不覆盖的原因）
//
//  1. 「文件大小不符 / JSON 不合法」两类失败也走 `unknown`，但需要先造出
//     符合大小或非法 JSON 的临时文件才可断言，属已有 `DownloadVerifierTests` 的范围，
//     本文件只覆盖适配器新增的前缀映射分支。
//  2. `DefaultDownloadSourceResolver` 的「自动切换（both）+ 官方域名 → 追加 BMCLAPI 备用源」
//     分支不覆盖：`DownloadSourceManager` 是单例，`getDownloadSource()` 在 both 模式下
//     会触发真实的官方源测速后台任务，且测速结果会改写当前主源 → 候选个数在
//     官方源与镜像源之间漂移，无法稳定断言。需要给源管理器加注入点或改成纯函数。
//  3. `legacyFailureReason(taskID:)` 的**网络失败**正向路径不覆盖。
//     本文件已用「目标已存在 + replaceMethod = .throw」构造出确定性的失败终态，
//     覆盖了「回放旧错误描述」这条链路；但真实线上最常见的失败来自 HTTP 层
//     （无可用源 / 慢速断开 / 分片校验失败），这些文案能否被 `map(_:)` 正确归类、
//     以及被归类后 `legacyFailureReason` 是否仍为原文，都需要受控网络失败才能断言。
//     `NetDownloaderDownloadEngine` 内部直接调用 `NetManager.shared`（actor 单例，
//     无网络后端注入点）。若要补：给引擎加 `NetManager` 协议抽象，注入返回
//     「远程服务器返回了 404」一类错误的 fake，再断言 `legacyFailureReason` 保留原始文本
//     而 `.failed` 为结构化 `.httpStatus(404)`（两者文案不同，正是该接口存在的理由）。
//  4. 分片调度、断点续传、源黑名单与终态清理不覆盖：依赖受控 HTTP 服务端，
//     与 `TESTING.md` 第三节第 1 条同一缺口。
//  5. `terminalHistoryLimit`（256）的淘汰行为不覆盖：需要提交 256 个以上任务，
//     成本高且与本文件目标无关。

// MARK: - 字符串重复辅助

private extension String {
    /// 生成 N 个自身字符的重复串，用于构造长度符合判定规则的指纹
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
