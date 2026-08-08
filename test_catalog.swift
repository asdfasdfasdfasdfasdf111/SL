import Foundation
import zlib

func inflateGzipData(_ input: Data) -> Data? {
    return input.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data? in
        let src = srcRaw.bindMemory(to: UInt8.self)
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer<UInt8>(mutating: src.baseAddress!)
        stream.avail_in = uInt(input.count)
        guard inflateInit2_(&stream, 16 + 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        let buffer = [UInt8](repeating: 0, count: 1 << 16)
        var lastStatus: Int32 = Z_OK
        while true {
            var localBuffer = buffer
            let produced = localBuffer.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
                stream.next_out = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = uInt(buffer.count)
                lastStatus = inflate(&stream, Z_NO_FLUSH)
                if lastStatus == Z_OK || lastStatus == Z_STREAM_END {
                    return buffer.count - Int(stream.avail_out)
                }
                return -1
            }
            if produced < 0 { return nil }
            if produced > 0 { output.append(localBuffer, count: produced) }
            if lastStatus == Z_STREAM_END { return output }
            if stream.avail_in == 0 && lastStatus == Z_OK { return nil }
        }
    }
}

let url = URL(fileURLWithPath: "/Users/apple/Downloads/Swim111Launcher_副本/qwq/modrinth_catalog.json.gz")
guard let compressed = try? Data(contentsOf: url) else { print("READ FAIL"); exit(1) }
let t0 = Date()
guard let data = inflateGzipData(compressed) else { print("INFLATE FAIL"); exit(1) }
let t1 = Date()
guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { print("JSON FAIL"); exit(1) }
let t2 = Date()
guard let entries = json["items"] as? [[String: Any]] else { print("NO ITEMS"); exit(1) }
print("inflate: \(Int((t1.timeIntervalSince(t0))*1000))ms, json: \(Int((t2.timeIntervalSince(t1))*1000))ms, total entries: \(entries.count)")
var counts: [String: Int] = [:]
for e in entries {
    let t = e["t"] as? String ?? "?"
    counts[t, default: 0] += 1
}
print(counts)
let sample = entries[0]
print("sample keys:", sample.keys.sorted())
