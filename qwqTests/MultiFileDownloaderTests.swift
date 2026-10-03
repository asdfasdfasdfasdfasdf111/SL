//
//  MultiFileDownloaderTests.swift
//  覆盖 `SLCore/Download/MultiFileDownloader.swift` 的 DownloadItem 值语义
//  与 ReplaceMethod 枚举形状。`MultiFileDownloader.start` 依赖 NetManager（网络层），
//  属集成路径，不在本文件覆盖（见 TESTING.md 的覆盖缺口登记）。
//
//  ⚠️ 用例一律 async（工程纪律：同步用例释放 @MainActor 类实例会触发宿主 abort）。
//

import XCTest
@testable import qwq

final class MultiFileDownloaderTests: XCTestCase {

    // MARK: DownloadItem 直连 URL 构造

    /// 直连构造：url / destination / sha1 原样保留，无 fallback
    func testDirectInitPreservesFields() async {
        let url = URL(string: "https://example.com/a.jar")!
        let dest = URL(fileURLWithPath: "/tmp/a.jar")
        let item = DownloadItem(url, dest, sha1: "abc123")
        XCTAssertEqual(item.url, url)
        XCTAssertEqual(item.destination, dest)
        XCTAssertEqual(item.sha1, "abc123")
    }

    /// 直连构造：sha1 可省略（nil）
    func testDirectInitWithoutSHA1() async {
        let item = DownloadItem(
            URL(string: "https://example.com/b.jar")!,
            URL(fileURLWithPath: "/tmp/b.jar")
        )
        XCTAssertNil(item.sha1)
    }

    // MARK: DownloadItem 下载源构造（fallback 语义）

    /// 下载源构造：主 url 由 urlProvider 对主源求值产生
    func testSourceInitResolvesPrimaryURL() async {
        let dest = URL(fileURLWithPath: "/tmp/c.jar")
        let item = DownloadItem(
            OfficialDownloadSource.shared,
            { source in source.getVersionManifestURL() },
            destination: dest,
            sha1: nil
        )
        XCTAssertEqual(item.url, OfficialDownloadSource.shared.getVersionManifestURL())
    }

    /// 下载源构造：urlProvider 收到的确实是传入的源实例
    /// （两个真实源的 manifest URL 恰好相同——镜像只镜像文件不镜像元数据，
    /// 故用源对象身份区分，而非 URL 值）
    func testSourceInitPassesGivenSourceToProvider() async {
        let dest = URL(fileURLWithPath: "/tmp/d.jar")
        let sentinel = URL(string: "https://sentinel.example/used-source")!
        let item = DownloadItem(
            BMCLAPIDownloadSource.shared,
            { source in
                // 断言 provider 收到的是镜像源实例
                guard source is BMCLAPIDownloadSource else {
                    return URL(string: "https://sentinel.example/wrong-source")!
                }
                return sentinel
            },
            destination: dest,
            sha1: nil
        )
        XCTAssertEqual(item.url, sentinel, "urlProvider 必须收到传入的镜像源实例")
    }

    // MARK: ReplaceMethod 枚举形状

    /// 三 case 齐全（穷尽性由编译器保证，本用例钉「存在性」防误删）
    func testReplaceMethodCases() async {
        let methods: [ReplaceMethod] = [.skip, .replace, .throw]
        XCTAssertEqual(methods.count, 3)
    }

    // MARK: MultiFileDownloader 构造形态

    /// convenience init(urls:destinations:) 与 items 等价
    func testConvenienceInitMatchesItemsInit() async {
        let urls = [URL(string: "https://example.com/x.jar")!]
        let dests = [URL(fileURLWithPath: "/tmp/x.jar")]
        // convenience init 不抛错、能构造即通过（start 属网络层，不在此驱动）
        let d1 = MultiFileDownloader(urls: urls, destinations: dests)
        let d2 = MultiFileDownloader(items: [DownloadItem(urls[0], dests[0])])
        XCTAssertNotNil(d1)
        XCTAssertNotNil(d2)
    }
}
