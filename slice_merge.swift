// slice_merge.swift
// 分片合并链路验证：官方源 3 段 Range 片段 → 顺序拼接 → SHA1 对比完整下载
// 验证 NetDownloader.merge 的「按 start 排序流式拼接」核心假设
// 用法: swift slice_merge.swift

import Foundation
import CryptoKit

let url = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest.json")!
let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slice_merge_test")
try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

func sha1(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func download(range: Range<Int>?, to dest: URL, tag: String) throws {
    var request = URLRequest(url: url)
    request.setValue("PCL.Mac/slice_merge_test", forHTTPHeaderField: "User-Agent")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding") // 禁用 gzip，保证 Range 生效（与 NetManager 修复一致）
    if let range {
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
    }
    let sem = DispatchSemaphore(value: 0)
    var resultData: Data?
    var resultError: Error?
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { sem.signal() }
        if let error { resultError = error; return }
        guard let http = response as? HTTPURLResponse else { resultError = URLError(.badServerResponse); return }
        if let range, http.statusCode != 206 {
            print("[\(tag)] 预期 206 Partial Content，实际 \(http.statusCode) —— 源不支持 Range，验证无法进行")
            resultError = URLError(.badServerResponse)
            return
        }
        resultData = data
    }.resume()
    sem.wait()
    if let resultError { throw resultError }
    try resultData!.write(to: dest)
    print("[\(tag)] 下载 \(resultData!.count) B")
}

// 1) 完整下载，作为基准
do {
    try download(range: nil, to: tmpDir.appendingPathComponent("full.json"), tag: "full ")
} catch {
    print("FAIL: 完整下载失败: \(error.localizedDescription)")
    exit(1)
}
let fullData = try Data(contentsOf: tmpDir.appendingPathComponent("full.json"))
let fullSHA1 = sha1(fullData)
print("完整文件 \(fullData.count) B  SHA1=\(fullSHA1)")
guard fullData.count > 1024 else { print("FAIL: 文件太小，无法分片"); exit(1) }

// 2) 按 PCL2 分割语义取 3 段：0~end*0.4、end*0.4~end*0.8、end*0.8~end（对齐到边界）
let n = fullData.count
let cuts = [Int(Double(n) * 0.4), Int(Double(n) * 0.8)]
let ranges = [0..<cuts[0], cuts[0]..<cuts[1], cuts[1]..<n]
var parts: [(start: Int, data: Data)] = []
for (i, r) in ranges.enumerated() {
    let dest = tmpDir.appendingPathComponent("part\(i).json")
    do {
        try download(range: r, to: dest, tag: "part\(i)")
        parts.append((r.lowerBound, try Data(contentsOf: dest)))
    } catch {
        print("FAIL: 分片 \(i) 下载失败: \(error.localizedDescription)")
        exit(1)
    }
}

// 3) 按 start 顺序流式拼接（复刻 NetDownloader.merge 语义）
var merged = Data()
for part in parts.sorted(by: { $0.start < $1.start }) {
    merged.append(part.data)
}
let mergedSHA1 = sha1(merged)

// 4) 对比
print("拼接后 \(merged.count) B  SHA1=\(mergedSHA1)")
if merged.count == fullData.count && mergedSHA1 == fullSHA1 {
    print("PASS: 分片拼接与完整下载逐字节一致 (SHA1 匹配)")
} else {
    print("FAIL: 分片拼接结果不一致 (期望 \(fullData.count) B / \(fullSHA1))")
}

// 清理
try? FileManager.default.removeItem(at: tmpDir)
