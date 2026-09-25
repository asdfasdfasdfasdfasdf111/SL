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
//  ⚠️ 本文件**刻意不驱动 `AccountManager.shared`**：测试 bundle 的宿主就是 qwq.app 本体
//  （`TEST_HOST = qwq.app/Contents/MacOS/qwq`，bundle id 与正式 App 同为
//  `io.github.asdfasdfasdfasdfasdf111.SL`），因此测试进程里的 `UserDefaults.standard`
//  就是**用户真实启动器的偏好域**。而 `getAccount()` 在 `accountId == nil` 时会**回写** `accountId`
//  —— 一旦在用例里调用它，就等于改用户的真实账号数据。所以：
//    · `getAccount()` 的分支语义本轮**未覆盖**，需先给 `AccountManager` / `CodableAppStorage`
//      注入 `UserDefaults` 才能安全地测（属模型分层那一轮的范围）；
//    · 本文件只对两个真实键做**只读**访问，并用
//      `testWrapperMechanismLeavesRealAccountKeysUntouched` 把「本套用例不碰真实键」
//      变成可执行断言。
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

    /// 本套用例专用的一次性键，与真实键严格区分；`tearDown` 负责删除。
    /// 用一个不可能与真实键碰撞的名字，即使用例中途 abort 也只会留下一个无害的孤儿键。
    private var scratchKey = ""

    override func setUp() {
        super.setUp()
        scratchKey = "__qwqTests_CodableAppStorage_\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: scratchKey)
        scratchKey = ""
        super.tearDown()
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

    /// `.microsoft` / `.yggdrasil` 这两个**只为兼容历史数据而保留**的 case 必须仍能解码
    /// —— 删掉它们就等于让老用户的整份 `[AnyAccount]` 一起解码失败。
    /// 同时钉住「解出来的未实现账号仍会自报未实现」，不得被静默当成已实现。
    func testLegacyUnimplementedKindsStillDecodeAndSelfReport() async throws {
        for caseName in ["microsoft", "yggdrasil"] {
            let decoded = try JSONDecoder().decode([AnyAccount].self,
                                                  from: legacyAccountsJSON(caseName: caseName))
            XCTAssertEqual(decoded.count, 1, "\(caseName) 的历史数据应能解码")

            switch decoded[0].unimplementedError {
            case .microsoftLoginNotImplemented:
                XCTAssertEqual(caseName, "microsoft")
            case .yggdrasilLoginNotImplemented:
                XCTAssertEqual(caseName, "yggdrasil")
            case nil:
                XCTFail("\(caseName) 解码后必须自报未实现，实际返回 nil")
            }

            XCTAssertTrue(decoded[0].accountKindDescription.contains("尚未实现"),
                          "\(caseName) 的展示文案必须显式标注尚未实现，避免 UI 把它呈现为可用登录方式")
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

    /// 当前编码器必须仍产出「合成形状」：顶层数组 → 单键 case 名 → `_0` → `{id,uuid,name}`。
    /// 这是「旧版本能不能读新数据」的判据。
    /// ⚠️ 只比**结构**（键集合），不比字符串：实测合成 Codable 的键序不稳定。
    func testCurrentEncoderStillProducesSynthesizedShape() async throws {
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
    }

    /// 往返：三种 case 编解码一轮后，`id` / `uuid` / `name` 逐一保留，且 case 不被换掉。
    func testRoundTripPreservesIdentityFieldsAndKind() async throws {
        let payload = OfflineAccount("Steve", UUID(uuidString: Self.fixedUuid)!)
        let cases: [(name: String, value: AnyAccount)] = [
            ("offline", .offline(payload)),
            ("microsoft", .microsoft(payload)),
            ("yggdrasil", .yggdrasil(payload))
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
            case ("microsoft", .microsoftLoginNotImplemented): break
            case ("yggdrasil", .yggdrasilLoginNotImplemented): break
            default: XCTFail("\(caseName) 往返后被换成了别的 case")
            }
        }
    }

    // MARK: - C. 包装器机制

    /// 包装器机制：`CodableAppStorage` 必须能把 `[AnyAccount]` 落盘、再读回。
    /// 同时钉住「包装器写出的字节 == 历史字面量的形状」—— 把读方向与写方向的用例接成同一条链。
    func testCodableAppStorageWritesLegacyShapeReadableByJSONDecoder() async throws {
        XCTAssertNotEqual(scratchKey, Self.accountsKey, "用例键绝不能等于真实键")

        let storage = CodableAppStorage<[AnyAccount]>(wrappedValue: [], scratchKey)
        storage.wrappedValue = [makeOffline()]

        let raw = try XCTUnwrap(UserDefaults.standard.data(forKey: scratchKey),
                                "包装器必须把 JSON 写进 UserDefaults")

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
        UserDefaults.standard.removeObject(forKey: scratchKey)
        let storage = CodableAppStorage<[AnyAccount]>(wrappedValue: [], scratchKey)
        XCTAssertTrue(storage.wrappedValue.isEmpty, "无数据时必须回落到默认值")

        // 写入后再看：`nonmutating set` 直接落 `UserDefaults`，因此读回必须立刻可见
        storage.wrappedValue = [makeOffline()]
        XCTAssertEqual(storage.wrappedValue.count, 1,
                       "包装器读数必须走存储本身，不得缓存（否则外部改动看不见）")

        // 删掉存储 → 必须回到默认值（证明它真的每读一次都问存储）
        UserDefaults.standard.removeObject(forKey: scratchKey)
        XCTAssertTrue(storage.wrappedValue.isEmpty)
    }

    /// `accountId` 的落盘形状：`UUID?` 经包装器落地是**裸 JSON 字符串**（不是 `{"uuid":…}` 这类包装），
    /// `nil` 落成 `null`。`AccountManager.accountId` 用的是同一个包装器 + 同一个类型，
    /// 所以这条钉的就是「已选账号」的磁盘形状。
    func testAccountIdPersistsAsBareUUIDStringAndNull() async throws {
        let id = UUID(uuidString: Self.fixedUuid)!
        // `let` 足够：`CodableAppStorage.wrappedValue` 是 `nonmutating set`，写入直接落 `UserDefaults`
        let storage = CodableAppStorage<UUID?>(wrappedValue: nil, scratchKey)

        storage.wrappedValue = id
        let raw = try XCTUnwrap(UserDefaults.standard.data(forKey: scratchKey))
        XCTAssertEqual(String(data: raw, encoding: .utf8), "\"\(id.uuidString)\"",
                       "已选账号 id 必须是裸 UUID 字符串")
        XCTAssertEqual(try JSONDecoder().decode(UUID?.self, from: raw), id)

        storage.wrappedValue = nil
        let rawNil = try XCTUnwrap(UserDefaults.standard.data(forKey: scratchKey))
        XCTAssertEqual(String(data: rawNil, encoding: .utf8), "null",
                       "未选账号必须落成 null，而不是缺键")
    }

    // MARK: - D. 身份语义（模型分层最容易顺手改掉的部分）

    /// `==` 只比 `id`，**不看 case** —— 同一个 payload 的 `.offline` 与 `.microsoft` 会被判为相等。
    /// 这是既成事实（`AnyAccount.==` 就是 `lhs.id == rhs.id`）；钉住它是因为模型分层时
    /// 很容易顺手改成「case + 字段全比」，那会改变去重与列表刷新的行为。
    func testEqualityIsByIDOnlyAndIgnoresKind() async {
        let payload = OfflineAccount("Steve", UUID(uuidString: Self.fixedUuid)!)
        XCTAssertEqual(AnyAccount.offline(payload), AnyAccount.microsoft(payload))
        XCTAssertEqual(AnyAccount.offline(payload), AnyAccount.yggdrasil(payload))
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
    /// `UserDefaults.standard` 就是用户真实偏好域（见文件头）。这里做一轮「写—读—删」
    /// 的包装器操作，然后断言 `accounts` / `accountId` 两个真实键**逐字节未变**。
    func testWrapperMechanismLeavesRealAccountKeysUntouched() async throws {
        let before = Self.snapshotRealAccountKeys()

        let storage = CodableAppStorage<[AnyAccount]>(wrappedValue: [], scratchKey)
        storage.wrappedValue = [makeOffline()]
        _ = storage.wrappedValue

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
}
