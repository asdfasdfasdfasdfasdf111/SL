//
//  DownloadMergerTests.swift
//  qwqTests
//
//  覆盖 `Core/Download/DownloadMerger.swift`。
//
//  现状：`DownloadMerger` 只有协议声明，工程内尚无默认实现（旧逻辑仍在 `NetManager.merge`），
//  因此无法直接测「真实实现」。本文件做两件事：
//  1. 用一份契约实现（OffsetOrderingMerger）验证「按 offset 升序拼接」这一契约本身
//     ——即后续落地真实实现时必须满足的行为；
//  2. 在文件末尾注明需要补齐的注入点与待测行为。
//
//  需要后续改造的建议（不改源码，仅记录）：
//  - 提供 `FileManagerDownloadMerger` 默认实现并支持单分片移动（协议注释中的约定）；
//  - 把分片缺失 / 区间不衔接定义为 `DownloadError` 的具体 case，便于调用方穷尽处理。
//

import XCTest
@testable import qwq

// MARK: - 契约实现（测试替身）

/// 按 offset 升序拼接分片的最小实现，仅用于验证 `DownloadMerger` 的契约。
///
/// 契约要点（与协议注释一致）：
/// - 无论入参顺序如何，一律按 offset 升序拼接；
/// - 目标文件所在目录由实现负责创建；
/// - 分片临时文件缺失时抛错，且不产出半成品目标文件。
struct OffsetOrderingMerger: DownloadMerger {

    enum Failure: Error, Equatable {
        /// 分片临时文件不存在
        case missingSliceFile(URL)
    }

    func merge(slices: [DownloadSlice], to destination: URL) throws {
        let ordered = slices.sorted { $0.offset < $1.offset }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var merged = Data()
        for slice in ordered {
            guard FileManager.default.fileExists(atPath: slice.tempFileURL.path) else {
                throw Failure.missingSliceFile(slice.tempFileURL)
            }
            merged.append(try Data(contentsOf: slice.tempFileURL))
        }
        try merged.write(to: destination)
    }
}

// MARK: - 测试用例

final class DownloadMergerTests: XCTestCase {

    private var temporaryDirectory: URL!
    private let merger = OffsetOrderingMerger()

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DownloadMergerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: - 辅助

    /// 把源数据切成等长分片，写入临时文件，返回分片描述
    private func writeSlices(of payload: Data, sliceCount: Int) throws -> [DownloadSlice] {
        let sliceSize = payload.count / sliceCount
        var slices: [DownloadSlice] = []
        for index in 0..<sliceCount {
            let start = index * sliceSize
            let end = (index == sliceCount - 1) ? payload.count : (start + sliceSize)
            let sliceURL = temporaryDirectory.appendingPathComponent("slice-\(index).part")
            try payload[start..<end].write(to: sliceURL)
            slices.append(
                DownloadSlice(
                    offset: Int64(start),
                    length: Int64(end - start),
                    tempFileURL: sliceURL,
                    state: .completed,
                    bytesWritten: Int64(end - start)
                )
            )
        }
        return slices
    }

    // MARK: - 按 offset 合并

    /// 乱序传入的分片必须按 offset 升序拼回与源文件一致的内容
    func testMergeOrdersSlicesByOffset() throws {
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        var slices = try writeSlices(of: payload, sliceCount: 4)
        slices.shuffle()

        let destination = temporaryDirectory.appendingPathComponent("merged.bin")
        try merger.merge(slices: slices, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    /// 完全倒序传入的分片同样按 offset 升序拼接
    func testMergeHandlesReverseOrderedSlices() throws {
        let payload = Data((0..<3072).map { UInt8($0 % 199) })
        let slices = try writeSlices(of: payload, sliceCount: 3).reversed()

        let destination = temporaryDirectory.appendingPathComponent("reversed.bin")
        try merger.merge(slices: Array(slices), to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    /// 单个分片时结果同样与源一致
    func testMergeSingleSlice() throws {
        let payload = Data("single-slice-payload".utf8)
        let slices = try writeSlices(of: payload, sliceCount: 1)

        let destination = temporaryDirectory.appendingPathComponent("single.bin")
        try merger.merge(slices: slices, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    /// 目标目录不存在时由实现负责创建
    func testMergeCreatesMissingDestinationDirectory() throws {
        let payload = Data((0..<1024).map { UInt8($0 % 97) })
        let slices = try writeSlices(of: payload, sliceCount: 2)

        let destination = temporaryDirectory
            .appendingPathComponent("nested/deeper", isDirectory: true)
            .appendingPathComponent("merged.bin")
        try merger.merge(slices: slices, to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    /// 已存在的目标文件被整体覆盖
    func testMergeOverwritesExistingDestination() throws {
        let payload = Data((0..<2048).map { UInt8($0 % 127) })
        let slices = try writeSlices(of: payload, sliceCount: 2)

        let destination = temporaryDirectory.appendingPathComponent("overwrite.bin")
        try Data("stale-content".utf8).write(to: destination)
        try merger.merge(slices: slices, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    /// 分片临时文件缺失时抛错，且不产出目标文件
    func testMergeThrowsWhenSliceFileIsMissing() throws {
        let slices = try writeSlices(of: Data((0..<512).map { UInt8($0 % 31) }), sliceCount: 2)
        let missingURL = temporaryDirectory.appendingPathComponent("slice-missing.part")
        var brokenSlices = slices
        brokenSlices.append(
            DownloadSlice(offset: 512, length: 512, tempFileURL: missingURL, state: .completed, bytesWritten: 512)
        )

        let destination = temporaryDirectory.appendingPathComponent("broken.bin")
        XCTAssertThrowsError(try merger.merge(slices: brokenSlices, to: destination)) { error in
            XCTAssertEqual(error as? OffsetOrderingMerger.Failure, .missingSliceFile(missingURL))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "分片缺失时不应留下半成品目标文件"
        )
    }

    /// 空分片列表：契约定义为产出空文件
    func testMergeEmptySliceListProducesEmptyFile() throws {
        let destination = temporaryDirectory.appendingPathComponent("empty.bin")
        try merger.merge(slices: [], to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data())
    }

    // MARK: - 分片台账的数据契约

    /// `DownloadSlice.undone` 反映断点续传时该分片剩余待下字节数
    func testSliceUndoneReflectsRemainingBytes() {
        let slice = DownloadSlice(
            offset: 0,
            length: 1024,
            tempFileURL: URL(fileURLWithPath: "/tmp/slice.part"),
            state: .downloading,
            bytesWritten: 256
        )
        XCTAssertEqual(slice.undone, 768)
        XCTAssertEqual(slice.state, .downloading)

        let unknownLength = DownloadSlice(
            offset: 0,
            length: -1,
            tempFileURL: URL(fileURLWithPath: "/tmp/slice.part"),
            bytesWritten: 256
        )
        XCTAssertEqual(unknownLength.undone, -1, "长度未知时 undone 为 -1")
    }
}
