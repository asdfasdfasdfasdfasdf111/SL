//
//  AccountPersistenceCompatTests.swift
//  qwqTests
//
//  这份测试在保护什么行为（为什么在动 `AnyAccount` 之前必须先有它）：
//
//  `AccountManager` 把账号以 **JSON** 落在 `UserDefaults` 的 `"accounts"` / `"accountId"`
//  两个键上。落盘格式**不是我们写的解析器**，而是 Swift 为「带关联值的 enum」与
//  「合成的 Codable 类」自动生成的形状 —— 也就是说，**它由 case 名、声明顺序和字段集合决定**。
//  于是任何一次「账号模型分层」重构（把 `AnyAccount` 的 enum 拆成 struct、改 case 名、
//  增删字段、给 `OfflineAccount` 加/减属性）都会**静默**改变磁盘上的字节，
//  让用户既有的账号数据解码失败 —— 而这类失败在 UI 上只表现为「账号没了」。
//
//  本轮之前，全库**没有任何用例**碰过这条持久化契约（TESTING.md 旧文把 `SLCore/Account/`
//  列在「因依赖链未覆盖」一侧）。所以在动模型分层之前，先把当前形状钉死。
//
//  钉死的是**两个方向**：
//  A. 读方向（真正的兼容性）：按**历史字面量**硬写的 JSON（不是由被测代码现编出来的，
//     否则重构时编码器与解码器一起改就会「自洽地」通过）必须仍能解码，且字段值正确；
//  B. 写方向：当前编码器必须仍然产出**同一个形状**，否则旧版本读不了新写的数据。
//
//  ⚠️ 两侧都必须「先解析成 JSON 对象再比结构」，**不能整串 byte 比较**：
//  Swift 合成的 Codable 对同一份值**不保证键序稳定**（实测 `[AnyAccount]` 数组形态下
//  键序是 `id,uuid,name`，单值形态下是 `uuid,name,id`）。写死字符串会得到一个
//  「今天绿、明天红」的用例。
//
//  ⚠️ 本文件**不读写用户真实账号数据**（2026-10-10 起）：测试 bundle 的宿主就是 qwq.app 本体
//  （`TEST_HOST = qwq.app/Contents/MacOS/qwq`，bundle id 与正式 App 同为
//  `io.github.asdfasdfasdfasdfasdf111.SL`），因此测试进程里的 `UserDefaults.standard`
//  就是**用户真实启动器的偏好域**。而 `getAccount()` 在 `accountId == nil` 时会**回写** `accountId`
//  —— 一旦直接调用它，就等于改用户的真实账号数据。
//    · 需要读写账号的用例一律经 `makeScratchStore()` 拿一个 `UserDefaults(suiteName:)`
//      独立偏好域，再用 `AccountManager.makeForTesting(store:)` 驱动 —— 隔离由**存储位置**
//      保证，真实域全程连删除都不做；
//    · 历史做法（2026-10-02 起）是 `withScrubbedAccountKeys`：删掉真实键、断言、`defer` 还原。
//      它有个测试自身堵不住的洞：宿主 abort 会直接杀进程、**`defer` 不执行**
//      （Xcode 26.2 隔离析构缺陷，见 `qwqTests/TESTING.md` §五），于是「跑一次测试」
//      可能真的抹掉用户已保存的账号。2026-10-10 已按上述注入点替换掉。
//    · 仅有的真实偏好域访问都是**只读**的：护栏用例前后的 `snapshotRealAccountKeys()` 快照，
//      以及 `testRealStoredAccountsStillDecodeWhenPresent` 的活体校验。
//
//  被测：SLCore/Account/AnyAccount.swift、SLCore/Account/OfflineAccount.swift、
//        SLCore/Storage/CodableAppStorage.swift
//

import XCTest
import Foundation
@testable import qwq

/// ⚠️ `@MainActor` 与 `async` 用例体都是**必需**的（与 `DropInstallCoordinatorTests` 同理）：
/// 工程开启了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，未显式标注的类（含 `OfflineAccount`）
/// 都是主 actor 隔离的；在同步用例里构造并释放这类实例会命中 Xcode 26.2 的隔离析构缺陷
/// （`malloc: pointer being freed was not allocated`，实测宿主 100% abort），把测试宿主打崩。
@MainActor
final class AccountPersistenceCompatTests: XCTestCase {

    // MARK: - 真实持久化契约（键名是用户数据的地址，**不可改**）

    /// `AccountManager.accounts` 的键
    private static let accountsKey = "accounts"
    /// `AccountManager.accountId` 的键
    private static let accountIdKey = "accountId"

    // MARK: - 固定值（写进字面量，避免用例依赖随机生成的 id）

    /// `OfflineAccount.id`（随机生成，这里固定成字面量）。
    /// `nonisolated` 是**必需**的：下面夹具的**默认参数**在非隔离上下文里求值，
    /// 而本类是 `@MainActor`，不标注会让静态成员在主 actor 之外被引用（Swift 6 下是错误）。
    private nonisolated static let fixedId = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    /// `OfflineAccount.uuid`（由用户名按 PCL2 算法确定，这里显式传入以固定值）；`nonisolated` 理由同上。
    private nonisolated static let fixedUuid = "11111111-2222-3333-4444-555555555555"

    /// 本套用例专用的一次性键，与真实键严格区分。
    /// 现在它只在一个**一次性偏好域**内使用（见 `makeScratchStore()`），
    /// 因此即使用例中途 abort，留下的也只是一个待清理的独立域，不触及真实键。
    private var scratchKey = ""

    /// 一次性偏好域的固定前缀。`sweepStaleScratchDomains()` 只认这个前缀，
    /// 绝不触碰其它偏好域文件。
    private static let scratchDomainPrefix = "__qwqTests_AccountPersistence_"

    override func setUp() {
        super.setUp()
        scratchKey = "__qwqTests_CodableAppStorage_\(UUID().uuidString)"
        Self.sweepStaleScratchDomains()
    }

    /// 一个**独立偏好域**：本套用例对账号/包装器的所有读写都落在这里。
    ///
    /// 为什么不是「读真实域 + 还原」：宿主 abort 会直接杀进程，`defer` 不执行，
    /// 还原动作不存在 → 真实数据被留在被改过的状态。改成独立域后，
    /// **真实域从头到尾没有被写过**，不依赖任何收尾动作。
    ///
    /// 清理分两处，**缺一不可**（实测过，不要删其中任何一处）：
    ///  · 下面注册的收尾块负责清内容（`removePersistentDomain`）并删掉 cfprefsd 留下的
    ///    **0 键空壳 plist**（42 B）；
    ///  · 但 cfprefsd 可能在 unlink **之后**把空壳重新落盘（收尾块里 `store` 此时仍存活），
    ///    所以收尾只能算「尽力而为」—— 真正的兜底是 `setUp` 里的
    ///    `sweepStaleScratchDomains()`，它在**下一次运行开始时**扫掉上一轮的空壳。
    private func makeScratchStore() throws -> UserDefaults {
        let name = "\(Self.scratchDomainPrefix)\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name), "无法创建独立偏好域 \(name)")
        addTeardownBlock {
            store.removePersistentDomain(forName: name)
            let shell = Self.preferencesDirectory.appendingPathComponent("\(name).plist")
            try? FileManager.default.removeItem(at: shell)
        }
        return store
    }

    /// `~/Library/Preferences`（本工程未沙箱化，偏好域就在此处）。
    private static var preferencesDirectory: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences")
    }

    /// 扫掉上一轮遗留的一次性域空壳。**必须放在运行开始时做**：此刻测试进程对这些旧域名
    /// 没有活跃实例，删除不会被 cfprefsd 写回；放到运行结束后做则会与 cfprefsd 抢同一个文件。
    private static func sweepStaleScratchDomains() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: preferencesDirectory, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(scratchDomainPrefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 夹具

    /// 按**历史字面量**构造落盘 JSON。
    /// 注意这里的结构是硬编码的：`[{<case>:{_0:{id,uuid,name}}}]`。
    /// 它**不是** `JSONEncoder` 现编出来的 —— 后者会跟着重构一起变，测不出兼容性。
    private func legacyAccountsJSON(caseName: String,
                                   id: String = AccountPersistenceCompatTests.fixedId,
                                   uuid: String = AccountPersistenceCompatTests.fixedUuid,
                                   name: String = "Steve") -> Data {
        Data("""
        [{"\(caseName)":{"_0":{"id":"\(id)","uuid":"\(uuid)","name":"\(name)"}}}]
        """.utf8)
    }

    private func makeOffline(name: String = "Steve", uuid: String = AccountPersistenceCompatTests.fixedUuid) -> AnyAccount {
        .offline(OfflineAccount(name, UUID(uuidString: uuid)!))
    }

    /// 微软账号夹具（新形状载荷）。id 显式固定，与 `OfflineAccount` 夹具一样避免依赖随机值。
    /// 字段集合即 MicrosoftAccount 的持久化形状
    /// （id/uuid/name/msaRefreshToken/accessToken/accessTokenExpiry），
    /// 由本文件的 `testCurrentEncoderStillProducesSynthesizedShape` 与
    /// `testRoundTripPreservesIdentityFieldsAndKind` 钉住。
    private func makeMicrosoft(id: String = AccountPersistenceCompatTests.fixedId,
                               name: String = "Steve") -> MicrosoftAccount {
        MicrosoftAccount(
            id: UUID(uuidString: id)!,
            uuid: UUID(uuidString: AccountPersistenceCompatTests.fixedUuid)!,
            name: name,
            msaRefreshToken: "msa-refresh-token",
            accessToken: "mc-access-token",
            accessTokenExpiry: Date().addingTimeInterval(3600)
        )
    }

    private static func snapshotRealAccountKeys() -> (accounts: Data?, accountId: Data?) {
        (UserDefaults.standard.data(forKey: accountsKey),
         UserDefaults.standard.data(forKey: accountIdKey))
    }

    // MARK: - A. 读方向：历史数据必须仍能解码

    /// 历史 `.offline` 数据必须仍能解码，且 `id` / `uuid` / `name` 三个字段逐字保留。
    func testLegacyOfflineJSONStillDecodes() async throws {
        let decoded = try JSONDecoder().decode([AnyAccount].self,
                                               from: legacyAccountsJSON(caseName: "offline"))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].name, "Steve")
        XCTAssertEqual(decoded[0].uuid.uuidString, Self.fixedUuid)
        XCTAssertEqual(decoded[0].id.uuidString, Self.fixedId)
        XCTAssertNil(decoded[0].unimplementedError, "`.offline` 是已实现种类，不得自报未实现")
    }

    /// 模型变更（2026-10-…，微软登录落地）后的兼容契约：
    ///  - **`.microsoft` 旧载荷（OfflineAccount 形状）** 必须仍能解码，且被**迁移为 `.offline`**
    ///    —— 桩时代微软账号运行期本就按离线账号处理，迁移不丢用户名/UUID，
    ///    也不因一条旧数据拖垮整份 `[AnyAccount]` 解码；
    ///  - **`.yggdrasil`** 仍是桩：解码后自报未实现，不得被当成已实现。
    func testLegacyMicrosoftPayloadMigratesToOfflineAndYggdrasilSelfReports() async throws {
        for caseName in ["microsoft", "yggdrasil"] {
            let decoded = try JSONDecoder().decode([AnyAccount].self,
                                                  from: legacyAccountsJSON(caseName: caseName))
            XCTAssertEqual(decoded.count, 1, "\(caseName) 的历史数据应能解码")

            if caseName == "microsoft" {
                // 旧微软件数据迁移为 .offline：
                //  - 字段（id/uuid/name）必须逐字保留（迁移不得丢数据）
                //  - 迁移后是已实现种类，不得自报未实现
                //  - 不出现微软账号形状（microsoftAccount 为 nil）
                switch decoded[0] {
                case .offline: break
                default: XCTFail("旧 .microsoft 载荷必须迁移为 .offline，实际为别的 case")
                }
                XCTAssertEqual(decoded[0].id.uuidString, Self.fixedId)
                XCTAssertEqual(decoded[0].uuid.uuidString, Self.fixedUuid)
                XCTAssertEqual(decoded[0].name, "Steve")
                XCTAssertNil(decoded[0].unimplementedError, "迁移为 .offline 后是已实现种类，不得自报未实现")
                XCTAssertNil(decoded[0].microsoftAccount, "旧载荷不包含微软账号字段，microsoftAccount 必须为 nil")
            } else {
                // yggdrasil 保持桩语义：解码后自报未实现
                XCTAssertEqual(decoded[0].unimplementedError, .yggdrasilLoginNotImplemented,
                               "yggdrasil 解码后必须自报未实现")
                XCTAssertTrue(decoded[0].accountKindDescription.contains("尚未实现"),
                              "yggdrasil 的展示文案必须显式标注尚未实现，避免 UI 把它呈现为可用登录方式")
            }
        }
    }

    /// **未知 case 必须报错，不得被兜底成 `.offline`**。
    /// 将来若有人为了「向后兼容」加一个 `default:` 兜底，这条用例会立刻变红 ——
    /// 把「未知账号悄悄变成离线账号」这种静默降级挡在门外。
    func testUnknownKindIsRejectedNotSilentlyCoerced() async {
        let data = Data(#"[{"mojang":{"_0":{"id":"a","uuid":"b","name":"c"}}}]"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([AnyAccount].self, from: data))
    }

    /// 确认「不存在第二种历史形状」。
    /// 实测：把账号拍平成 `{id,uuid,name,kind}` 的字典**解不出来**，
    /// 所以任何「顺手加个扁平解码」都不是兼容性修复，而是新增格式 —— 该红。
    func testFlatDictionaryShapeIsNotASecondHistoricalFormat() async {
        let data = Data("""
        [{"id":"\(Self.fixedId)","uuid":"\(Self.fixedUuid)","name":"Steve","kind":"offline"}]
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([AnyAccount].self, from: data))
    }

    // MARK: - B. 写方向：编码器必须仍然产出同一形状

    /// 当前编码器必须仍产出「合成形状」：顶层数组 → 单键 case 名 → `_0` → 载荷字段集合。
    /// 这是「旧版本能不能读新数据」的判据。
    /// ⚠️ 只比**结构**（键集合），不比字符串：实测合成 Codable 的键序不稳定。
    func testCurrentEncoderStillProducesSynthesizedShape() async throws {
        // 离线形状：`{offline:{_0:{id,uuid,name}}}`
        let data = try JSONEncoder().encode([makeOffline()])
        let shape = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(shape.count, 1)

        let entry = try XCTUnwrap(shape[0] as? [String: Any])
        XCTAssertEqual(Set(entry.keys), ["offline"],
                       "case 名就是磁盘格式的键，改名即让旧数据解码失败")

        let payload = try XCTUnwrap(entry["offline"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["_0"], "关联值必须以 `_0` 为键")

        let fields = try XCTUnwrap(payload["_0"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["id", "uuid", "name"],
                       "OfflineAccount 的持久化字段集合不得增减；增减都会让旧数据解码失败")

        // 微软形状：`{microsoft:{_0:{id,uuid,name,msaRefreshToken,accessToken,accessTokenExpiry}}}`。
        // 字段集合必须与 `MicrosoftAccount` 的 Codable 合成形状一致（键序不稳定，只比键集合）。
        let msData = try JSONEncoder().encode([AnyAccount.microsoft(makeMicrosoft())])
        let msShape = try XCTUnwrap(try JSONSerialization.jsonObject(with: msData) as? [Any])
        let msEntry = try XCTUnwrap(msShape[0] as? [String: Any])
        XCTAssertEqual(Set(msEntry.keys), ["microsoft"], "微软账号 case 键必须是 `microsoft`")
        let msPayload = try XCTUnwrap(msEntry["microsoft"] as? [String: Any])
        XCTAssertEqual(Set(msPayload.keys), ["_0"], "微软账号关联值同样以 `_0` 为键")
        let msFields = try XCTUnwrap(msPayload["_0"] as? [String: Any])
        XCTAssertEqual(Set(msFields.keys),
                       ["id", "uuid", "name", "msaRefreshToken", "accessToken", "accessTokenExpiry"],
                       "MicrosoftAccount 的持久化字段集合不得增减")
    }

    /// 往返：offline / microsoft（新形状）/ yggdrasil 编解码一轮后，字段逐一保留，且 case 不被换掉。
    func testRoundTripPreservesIdentityFieldsAndKind() async throws {
        let offline = OfflineAccount("Steve", UUID(uuidString: Self.fixedUuid)!)
        let microsoft = makeMicrosoft()
        let cases: [(name: String, value: AnyAccount)] = [
            ("offline", .offline(offline)),
            ("microsoft", .microsoft(microsoft)),
            ("yggdrasil", .yggdrasil(offline))
        ]

        for (caseName, original) in cases {
            let decoded = try JSONDecoder().decode([AnyAccount].self,
                                                  from: try JSONEncoder().encode([original]))
            let roundTripped = try XCTUnwrap(decoded.first, "\(caseName) 往返后必须仍有 1 条")
            XCTAssertEqual(roundTripped.id, original.id)
            XCTAssertEqual(roundTripped.uuid, original.uuid)
            XCTAssertEqual(roundTripped.name, original.name)

            // case 必须原样保留（`.microsoft` 不得被降级成 `.offline` 或反之）
            switch (caseName, roundTripped.unimplementedError) {
            case ("offline", nil): break
            case ("microsoft", nil): break // 微软登录已实现（2026-10-…），不得自报未实现
            case ("yggdrasil", .yggdrasilLoginNotImplemented): break
            default: XCTFail("\(caseName) 往返后被换成了别的 case")
            }

            // 微软账号的专属字段逐一保留（新形状契约）
            if caseName == "microsoft" {
                let rt = try XCTUnwrap(roundTripped.microsoftAccount, "往返后必须仍是微软账号")
                XCTAssertEqual(rt.msaRefreshToken, microsoft.msaRefreshToken)
                XCTAssertEqual(rt.accessToken, microsoft.accessToken)
                XCTAssertEqual(rt.accessTokenExpiry, microsoft.accessTokenExpiry,
                               "accessTokenExpiry 应精确保留（Date 按秒精度落盘）")
                XCTAssertEqual(rt.uuid, microsoft.uuid)
            }
        }
    }

    // MARK: - C. 包装器机制

    /// 包装器机制：`CodableAppStorage` 必须能把 `[AnyAccount]` 落盘、再读回。
    /// 同时钉住「包装器写出的字节 == 历史字面量的形状」—— 把读方向与写方向的用例接成同一条链。
    func testCodableAppStorageWritesLegacyShapeReadableByJSONDecoder() async throws {
        XCTAssertNotEqual(scratchKey, Self.accountsKey, "用例键绝不能等于真实键")
        let store = try makeScratchStore()

        let storage = CodableAppStorage<[AnyAccount]>(wrappedValue: [], scratchKey, store: store)
        storage.wrappedValue = [makeOffline()]

        let raw = try XCTUnwrap(store.data(forKey: scratchKey),
                                "包装器必须把 JSON 写进注入的偏好域")

        // 用「读方向」的解析器去读「写方向」的产物：两边形状必须一致
        let viaJSONDecoder = try JSONDecoder().decode([AnyAccount].self, from: raw)
        XCTAssertEqual(viaJSONDecoder.count, 1)
        XCTAssertEqual(viaJSONDecoder[0].name, "Steve")

        let viaWrapper = storage.wrappedValue
        XCTAssertEqual(viaWrapper.count, 1)
        XCTAssertEqual(viaWrapper[0].id, viaJSONDecoder[0].id)
    }

    /// 包装器机制：键不存在时必须返回声明处的默认值（`AccountManager` 依赖它给出空账号列表），
    /// 而不是崩溃或返回上一次的值。
    func testCodableAppStorageFallsBackToDeclaredDefaultAndReadsThrough() async throws {
        let store = try makeScratchStore()
        store.removeObject(forKey: scratchKey)
        let storage = CodableAppStorage<[AnyAccount]>(wrappedValue: [], scratchKey, store: store)
        XCTAssertTrue(storage.wrappedValue.isEmpty, "无数据时必须回落到默认值")

        // 写入后再看：`nonmutating set` 直接落 `UserDefaults`，因此读回必须立刻可见
        storage.wrappedValue = [makeOffline()]
        XCTAssertEqual(storage.wrappedValue.count, 1,
                       "包装器读数必须走存储本身，不得缓存（否则外部改动看不见）")

        // 删掉存储 → 必须回到默认值（证明它真的每读一次都问存储）
        store.removeObject(forKey: scratchKey)
        XCTAssertTrue(storage.wrappedValue.isEmpty)
    }

    /// `accountId` 的落盘形状：`UUID?` 经包装器落地是**裸 JSON 字符串**（不是 `{"uuid":…}` 这类包装），
    /// `nil` 落成 `null`。`AccountManager.accountId` 用的是同一个包装器 + 同一个类型，
    /// 所以这条钉的就是「已选账号」的磁盘形状。
    func testAccountIdPersistsAsBareUUIDStringAndNull() async throws {
        let id = UUID(uuidString: Self.fixedUuid)!
        let store = try makeScratchStore()
        // `let` 足够：`CodableAppStorage.wrappedValue` 是 `nonmutating set`，写入直接落 `UserDefaults`
        let storage = CodableAppStorage<UUID?>(wrappedValue: nil, scratchKey, store: store)

        storage.wrappedValue = id
        let raw = try XCTUnwrap(store.data(forKey: scratchKey))
        XCTAssertEqual(String(data: raw, encoding: .utf8), "\"\(id.uuidString)\"",
                       "已选账号 id 必须是裸 UUID 字符串")
        XCTAssertEqual(try JSONDecoder().decode(UUID?.self, from: raw), id)

        storage.wrappedValue = nil
        let rawNil = try XCTUnwrap(store.data(forKey: scratchKey))
        XCTAssertEqual(String(data: rawNil, encoding: .utf8), "null",
                       "未选账号必须落成 null，而不是缺键")
    }

    // MARK: - D. 身份语义（模型分层最容易顺手改掉的部分）

    /// `==` 只比 `id`，**不看 case** —— 同一个 payload 的 `.offline` 与 `.microsoft` 会被判为相等。
    /// 这是既成事实（`AnyAccount.==` 就是 `lhs.id == rhs.id`）；钉住它是因为模型分层时
    /// 很容易顺手改成「case + 字段全比」，那会改变去重与列表刷新的行为。
    func testEqualityIsByIDOnlyAndIgnoresKind() async {
        let payload = OfflineAccount("Steve", UUID(uuidString: Self.fixedUuid)!)
        XCTAssertEqual(AnyAccount.offline(payload), AnyAccount.yggdrasil(payload))
        // 微软账号与离线账号虽 id 相同（夹具显式传入 fixedId），但种类不同——仍按 id 判等。
        // 这钉住的是「`==` 只比 id、不看 case」的既成事实（微软登录落地后语义不变）。
        let microsoft = makeMicrosoft(id: payload.id.uuidString)
        XCTAssertEqual(AnyAccount.offline(payload), AnyAccount.microsoft(microsoft))
        XCTAssertEqual(AnyAccount.microsoft(microsoft), AnyAccount.yggdrasil(payload))
    }

    /// `id`（随机、`getAccount()` 的匹配依据）与 `uuid`（由用户名按 PCL2 算法确定）是**两件不同的事**：
    /// 同名记录 id 各不相同，而 uuid 必须可复现；显式传入的 uuid 则原样保留（玩家自定义 uuid 的语义）。
    func testIDIsRandomWhileUUIDIsDerivedFromName() async {
        // id 随机：每次新建都是新的，不从 uuid 派生
        let a = OfflineAccount("Steve")
        let b = OfflineAccount("Steve")
        XCTAssertNotEqual(a.id, b.id, "id 每次新建都是新的，不从 uuid 派生")

        // uuid 可复现：算法是纯函数，同名同 uuid
        XCTAssertEqual(a.uuid, b.uuid, "同名账号的 uuid 必须可复现")
        XCTAssertNotEqual(OfflineAccount("Alex").uuid, a.uuid, "不同名的 uuid 应当不同")

        // 显式传入的 uuid 必须原样保留，不得被算法覆盖（注意：它与算法算出的同名 uuid 并不相同）
        let fixed = UUID(uuidString: Self.fixedUuid)!
        XCTAssertEqual(OfflineAccount("Steve", fixed).uuid, fixed)
        XCTAssertNotEqual(a.uuid, fixed, "显式 uuid 与算法算出的同名 uuid 是两回事")

        // 算法产出必须是**合法 RFC 4122**：第 13 位（version）= 3、第 17 位（variant）= 9
        // （PCL2 `McLoginLegacyUuid` 的强制位；不做这一步的话任意用户名都可能算出非法 UUID）
        let hex = Array(a.uuid.uuidString.replacingOccurrences(of: "-", with: ""))
        XCTAssertEqual(hex.count, 32)
        XCTAssertEqual(hex[12], "3", "version 位必须被强制为 3")
        XCTAssertEqual(hex[16], "9", "variant 位必须被强制为 9")
    }

    // MARK: - E. 安全护栏

    /// 本套用例**不得改动用户真实账号数据**。
    /// 之所以要有这条断言，是因为测试 bundle 的宿主就是 qwq.app 本体，测试进程里的
    /// `UserDefaults.standard` 就是用户真实偏好域（见文件头）。
    /// 这里做一轮「写—读」的包装器操作，然后断言：① 产物落在**注入的域**里；
    /// ② `accounts` / `accountId` 两个真实键**逐字节未变**。
    func testWrapperMechanismLeavesRealAccountKeysUntouched() async throws {
        let before = Self.snapshotRealAccountKeys()
        let store = try makeScratchStore()
        XCTAssertFalse(store === UserDefaults.standard,
                       "用例必须跑在独立偏好域上；一旦等于 .standard，本用例后续断言就失去意义")

        let storage = CodableAppStorage<[AnyAccount]>(wrappedValue: [], scratchKey, store: store)
        storage.wrappedValue = [makeOffline()]
        _ = storage.wrappedValue

        XCTAssertNotNil(store.data(forKey: scratchKey),
                        "写入必须落在注入的域里（否则隔离根本没生效）")
        XCTAssertNil(UserDefaults.standard.data(forKey: scratchKey),
                     "注入域之外不得出现用例键")

        let after = Self.snapshotRealAccountKeys()
        XCTAssertEqual(before.accounts, after.accounts,
                       "用例改动了真实的 accounts 键（会覆盖用户账号数据）")
        XCTAssertEqual(before.accountId, after.accountId,
                       "用例改动了真实的 accountId 键")
    }

    /// 活体检查（**只读**）：本机若真有账号数据落在 `accounts` 上，它必须仍能被解码。
    /// 无数据（新装机 / CI）时用 `XCTSkip` **显式跳过**，不做「静默通过」——
    /// 静默通过会让人误以为这条检查跑过了。
    func testRealStoredAccountsStillDecodeWhenPresent() async throws {
        guard let data = UserDefaults.standard.data(forKey: Self.accountsKey) else {
            throw XCTSkip("本机 UserDefaults 的 accounts 键没有数据（新装机或从未添加账号），跳过活体校验")
        }
        let decoded = try JSONDecoder().decode([AnyAccount].self, from: data)
        XCTAssertFalse(decoded.isEmpty, "accounts 键有数据却解出空数组，说明落盘格式已变")
    }

    // MARK: - F. getAccount() 分支语义（2026-10-02 补覆盖）
    //
    // 这四个分支都要驱动一个 `AccountManager` 实例。2026-10-10 之前用的是
    // `AccountManager.shared` + `withScrubbedAccountKeys`（删真实键、`defer` 还原），
    // 现改为 `AccountManager.makeForTesting(store:)` + 独立偏好域：真实键**全程不被写**，
    // 因此不再存在「abort 导致还原没跑、用户账号被删」这条路径。
    // 断言口径不变：分支 1 回填 first.id / 分支 2 无账号返回 nil / 分支 3 命中 accountId / 分支 4 无匹配返回 nil。

    /// 管道护栏：`AccountManager` 的**两个**包装器都必须落在注入的域里。
    ///
    /// 为什么单靠上面那些语义断言不够：如果将来有人删掉 `AccountManager.init` 里
    /// `_accounts` / `_accountId` 的任一行显式构造，那个包装器会**静默回落到
    /// `UserDefaults.standard`**（= 用户真实偏好域）。而四个分支用例**照样会全绿** ——
    /// 写和读都走同一个域，自洽；`store` 那边只是空着，没有任何断言在看它。
    /// 于是「隔离失效」这件事只有在真实账号数据被改写之后才会暴露。
    /// 这条断言把「落盘位置」本身钉住：写完之后，**注入域里必须真的有那两个键**。
    private func assertBothWrappersStoredInInjectedDomain(_ store: UserDefaults) {
        XCTAssertNotNil(store.data(forKey: Self.accountsKey),
                        "accounts 没落在注入域 → 说明它回落到真实偏好域了，会写用户的账号数据")
        XCTAssertNotNil(store.data(forKey: Self.accountIdKey),
                        "accountId 没落在注入域 → 说明它回落到真实偏好域了，会写用户的已选账号")
    }

    /// 分支 1：accountId 为空 + accounts 非空 ⇒ 回写 first.id 并返回 first。
    func testGetAccountBackfillsAccountIdWhenMissing() async throws {
        let store = try makeScratchStore()
        let manager = AccountManager.makeForTesting(store: store)
        let account = makeOffline()
        manager.accounts = [account]
        manager.accountId = nil

        let result = manager.getAccount()
        XCTAssertEqual(result?.id, account.id, "accountId 缺失时必须回填 first 的 id 并返回它")
        XCTAssertEqual(manager.accountId, account.id,
                       "getAccount() 必须把缺失的 accountId 回写成 first.id")
        assertBothWrappersStoredInInjectedDomain(store)
    }

    /// 分支 2：accountId 为空 + accounts 也空 ⇒ 返回 nil（不回写）。
    func testGetAccountReturnsNilWhenNoAccounts() async throws {
        let store = try makeScratchStore()
        let manager = AccountManager.makeForTesting(store: store)
        manager.accounts = []
        manager.accountId = nil
        let result = manager.getAccount()
        XCTAssertNil(result, "无账号时必须返回 nil")
        XCTAssertNil(manager.accountId, "无账号时不得回写 accountId")
        assertBothWrappersStoredInInjectedDomain(store)
    }

    /// 分支 3：accountId 非空且匹配 accounts 之一 ⇒ 返回对应账号。
    func testGetAccountReturnsMatchingStoredAccount() async throws {
        let store = try makeScratchStore()
        let manager = AccountManager.makeForTesting(store: store)
        let first = makeOffline(name: "First")
        let second = makeOffline(name: "Second")
        manager.accounts = [first, second]
        manager.accountId = second.id

        let result = manager.getAccount()
        XCTAssertEqual(result?.id, second.id, "必须返回 accountId 指向的账号")
        assertBothWrappersStoredInInjectedDomain(store)
    }

    /// 分支 4：accountId 非空但不匹配任何账号 ⇒ 返回 nil（不因残留 id 崩）。
    func testGetAccountReturnsNilWhenStoredIDDoesNotMatch() async throws {
        let store = try makeScratchStore()
        let manager = AccountManager.makeForTesting(store: store)
        manager.accounts = [makeOffline()]
        manager.accountId = UUID()

        let result = manager.getAccount()
        XCTAssertNil(result, "accountId 无匹配时必须返回 nil")
        assertBothWrappersStoredInInjectedDomain(store)
    }
}
