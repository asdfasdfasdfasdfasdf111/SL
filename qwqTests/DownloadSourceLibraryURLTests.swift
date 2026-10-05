//
//  DownloadSourceLibraryURLTests.swift
//  qwqTests
//
//  覆盖 `SLCore/Download/DownloadSource.swift` 里两个源构造**库文件下载地址**的规则。
//
//  回归背景（2026-10-05 实测）：镜像源此前一律「按 Maven 坐标反推路径」，
//  遇到 **Maven 重定位**的库就会拼出 404 —— Forge 安装清单里的
//  `net.md-5:jarsplitter:1.1.2` 实际发布在 `net/minecraftforge/jarsplitter/1.1.2/`
//  （坐标还是老 group），实测 `net/md-5/...` → 404、`net/minecraftforge/...` → 200。
//  后果很重：处理器 jar 下不下来，安装要走到「执行安装器处理器」才以退出码 1 失败，
//  现场离病因很远（用户报告：「安装器处理器执行失败 …… 远程服务器返回了 404」）。
//
//  钉住两条：
//  1. 有 `downloads.artifact.path` 时，镜像地址必须**等于该权威路径**（不得按坐标反推）；
//  2. 没有 artifact 时退回坐标推路径（否则这类库在镜像源上会没有地址可用）。
//

import XCTest
@testable import qwq

final class DownloadSourceLibraryURLTests: XCTestCase {

    /// 造一个只含一条库的清单并解析出该库
    private func makeLibrary(libraryJSON: String, file: StaticString = #filePath, line: UInt = #line) throws -> ClientManifest.Library {
        let json = """
        { "id": "url-test", "mainClass": "M", "libraries": [ \(libraryJSON) ] }
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-dlsrc-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manifest.json")
        try Data(json.utf8).write(to: url)
        let manifest = try XCTUnwrap(try ClientManifest.parse(url: url), "夹具清单解析失败", file: file, line: line)
        return try XCTUnwrap(manifest.libraries.first, "夹具清单没有库", file: file, line: line)
    }

    /// 有 artifact 时按权威路径拼镜像地址（重定位库不再 404）
    func testMirrorLibraryURLUsesArtifactPathNotCoordinate() async throws {
        // 坐标 group 是老的 net.md-5，实际发布路径在 net.minecraftforge（真实案例）
        let library = try makeLibrary(libraryJSON: """
        { "name": "net.md-5:jarsplitter:1.1.2",
          "downloads": { "artifact": {
              "path": "net/minecraftforge/jarsplitter/1.1.2/jarsplitter-1.1.2.jar",
              "url": "https://maven.minecraftforge.net/net/minecraftforge/jarsplitter/1.1.2/jarsplitter-1.1.2.jar",
              "sha1": "0000000000000000000000000000000000000000", "size": 1 } } }
        """)

        let url = try XCTUnwrap(BMCLAPIDownloadSource.shared.getLibraryURL(library))
        XCTAssertTrue(
            url.absoluteString.hasSuffix("/maven/net/minecraftforge/jarsplitter/1.1.2/jarsplitter-1.1.2.jar"),
            "镜像地址应等于 artifact.path：\(url.absoluteString)"
        )
        XCTAssertFalse(url.absoluteString.contains("/net/md-5/"),
                       "不得按坐标反推出 net/md-5（该路径实测 404）")
    }

    /// 没有 artifact 时退回「坐标推路径」，保证这类库在镜像源上仍有地址
    func testMirrorLibraryURLFallsBackToCoordinateWithoutArtifact() async throws {
        let library = try makeLibrary(libraryJSON: """
        { "name": "net.example:thing:1.0" }
        """)

        let url = try XCTUnwrap(BMCLAPIDownloadSource.shared.getLibraryURL(library))
        XCTAssertTrue(
            url.absoluteString.hasSuffix("/maven/net/example/thing/1.0/thing-1.0.jar"),
            "无 artifact 时应按坐标推路径：\(url.absoluteString)"
        )
    }

    /// 官方源用清单里的 artifact.url（权威地址，天然不受重定位影响）
    func testOfficialLibraryURLUsesArtifactURL() async throws {
        let library = try makeLibrary(libraryJSON: """
        { "name": "net.md-5:jarsplitter:1.1.2",
          "downloads": { "artifact": {
              "path": "net/minecraftforge/jarsplitter/1.1.2/jarsplitter-1.1.2.jar",
              "url": "https://maven.minecraftforge.net/net/minecraftforge/jarsplitter/1.1.2/jarsplitter-1.1.2.jar",
              "sha1": "0000000000000000000000000000000000000000", "size": 1 } } }
        """)

        let url = try XCTUnwrap(OfficialDownloadSource.shared.getLibraryURL(library))
        XCTAssertEqual(url.absoluteString,
                       "https://maven.minecraftforge.net/net/minecraftforge/jarsplitter/1.1.2/jarsplitter-1.1.2.jar")
    }
}
