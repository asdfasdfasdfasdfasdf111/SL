import Foundation
import Vision
import AppKit

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: analyze_image <path> [path2 ...]")
    exit(1)
}

for path in args.dropFirst() {
    print("=== \(path) ===")
    guard let img = NSImage(contentsOfFile: path),
          let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("  [无法读取图片]")
        continue
    }

    let textReq = VNRecognizeTextRequest()
    textReq.recognitionLevel = .accurate
    textReq.recognitionLanguages = ["en-US", "zh-Hans"]
    textReq.usesLanguageCorrection = true

    let classifyReq = VNClassifyImageRequest()

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([textReq, classifyReq])
    } catch {
        print("  [识别失败: \(error)]")
    }

    if let results = textReq.results, !results.isEmpty {
        for obs in results {
            if let cand = obs.topCandidates(1).first {
                print("  文字: \(cand.string) (置信度: \(String(format: "%.2f", obs.confidence)))")
            }
        }
    } else {
        print("  文字: (未识别到文字)")
    }

    if let results = classifyReq.results {
        let top = results.prefix(5)
        for obs in top {
            print("  分类: \(obs.identifier) (置信度: \(String(format: "%.2f", obs.confidence)))")
        }
    }
}
