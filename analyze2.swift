import Foundation
import AppKit

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: analyze2 <path> [path2 ...]")
    exit(1)
}

func dominantColors(from cgImage: CGImage, maxCount: Int = 5) -> [(r: Int, g: Int, b: Int, count: Int)] {
    let w = 40
    let h = 40
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.interpolationQuality = .medium
    ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    var freq: [String: Int] = [:]
    for i in 0..<(w * h) {
        let o = i * 4
        let r = Int(data[o]), g = Int(data[o+1]), b = Int(data[o+2])
        let qr = r / 32 * 32, qg = g / 32 * 32, qb = b / 32 * 32
        freq["\(qr),\(qg),\(qb)", default: 0] += 1
    }
    return freq.sorted { $0.value > $1.value }.prefix(maxCount).map { (key, count) in
        let parts = key.split(separator: ",").map { Int($0)! }
        return (parts[0], parts[1], parts[2], count)
    }
}

func asciiArt(from cgImage: CGImage, width: Int = 60) -> String {
    let aspect = Double(cgImage.height) / Double(cgImage.width)
    let h = Int(Double(width) * aspect * 0.5)
    guard h > 0 else { return "(太小)" }
    var data = [UInt8](repeating: 0, count: width * h * 4)
    let ctx = CGContext(data: &data, width: width, height: h, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.interpolationQuality = .medium
    ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: h))
    let chars = Array(" .:-=+*#%@")
    var lines: [String] = []
    for y in 0..<h {
        var line = ""
        for x in 0..<width {
            let o = (y * width + x) * 4
            let r = Int(data[o]), g = Int(data[o+1]), b = Int(data[o+2])
            let lum = (r + g + b) / 3
            let idx = min(lum * (chars.count - 1) / 255, chars.count - 1)
            line.append(chars[idx])
        }
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}

for path in args.dropFirst() {
    print("==================== \(URL(fileURLWithPath: path).lastPathComponent) ====================")
    guard let img = NSImage(contentsOfFile: path),
          let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("  [无法读取图片]")
        continue
    }
    print("尺寸: \(cgImage.width) x \(cgImage.height)")
    print("主要颜色:")
    for (r, g, b, c) in dominantColors(from: cgImage) {
        let hex = String(format: "#%02X%02X%02X", r, g, b)
        let pct = Double(c) / 1600.0 * 100
        print("   \(hex) RGB(\(r),\(g),\(b)) 约占 \(String(format: "%.1f", pct))%")
    }
    print("ASCII 预览:")
    print(asciiArt(from: cgImage))
    print()
}
