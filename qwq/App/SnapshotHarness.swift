//
//  SnapshotHarness.swift
//  开发期 UI「自拍」：让 App 抓**自己的窗口**存成 PNG。
//
//  为什么需要它：本机没有授予终端/DSH「屏幕录制」权限，`screencapture` 抓不到
//  其它 App 的窗口（这是 macOS 的行为，不是 App 没渲染）。而 App 抓自己的窗口
//  **不需要任何系统权限**，于是用它来做 UI 验收：布局是否自适应、材质/阴影是否符合预期。
//
//  触发方式（仅环境变量，产品运行时完全不参与，也不出现在任何 UI 上）：
//      SL_SNAPSHOT_DIR=/tmp/snaps SL_SNAPSHOT_SIZES=680x500,900x660,1280x800 \
//          ~/Desktop/qwq.app/Contents/MacOS/qwq
//  可选：SL_SNAPSHOT_EXIT=1 拍完即退出（便于脚本化）。
//
//  抓的是**已合成**的窗口图像（含 NSVisualEffectView 毛玻璃与阴影），
//  因此看到的和用户屏幕上看到的一致 —— 这是它相对于 ImageRenderer 的关键优势
//  （后者不渲染 NSViewRepresentable，毛玻璃会丢失）。
//

import Cocoa

enum SnapshotHarness {
    /// 在 `applicationDidFinishLaunching` 末尾调用；未设置环境变量时立即返回。
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SL_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let sizes = parseSizes(env["SL_SNAPSHOT_SIZES"])
        let shouldExit = env["SL_SNAPSHOT_EXIT"] != nil

        Task { @MainActor in
            // 等首帧与窗口入场动画完成。⚠️ 不能太短：窗口还在展开时抓到的会是
            // 缩小态的过渡画面（实测曾抓到 154×200 的「迷你窗口」误判为布局出错）。
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            // 可选：先切到指定分类页再拍（SL_SNAPSHOT_CATEGORY=分类下标，0=启动 1=游戏 …）。
            // 没有这个开关时，游戏/下载等页面的渲染结果根本无法被看到 —— 也就无法验收。
            if let raw = env["SL_SNAPSHOT_CATEGORY"], let index = Int(raw) {
                NavigationIntent.shared.requestCategory(at: index)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            for size in sizes {
                guard let window = targetWindow() else { break }
                // setContentSize 改的是**内容区**尺寸，正是我们关心的口径。
                window.setContentSize(size)
                // 等窗口真正达到目标尺寸（尺寸被最小约束/动画钳住时不要急着拍）。
                await waitUntilSettled(window: window, size: size)
                await capture(window: window, to: "\(dir)/snap-\(Int(size.width))x\(Int(size.height)).png")
            }

            if shouldExit { NSApp.terminate(nil) }
        }
    }

    /// 轮询等待窗口内容尺寸达到目标（最多 4s），再额外等布局/动画稳定 0.5s。
    @MainActor
    private static func waitUntilSettled(window: NSWindow, size: NSSize) async {
        for _ in 0..<40 {
            let current = window.contentLayoutRect.size
            if abs(current.width - size.width) <= 2, abs(current.height - size.height) <= 2 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// 取可见的主窗口；没有则退回第一个有内容视图的窗口。
    @MainActor
    private static func targetWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil }
            ?? NSApp.windows.first { $0.contentView != nil }
    }

    /// `"680x500,900x660"` → `[NSSize]`。空/非法输入时给一组默认尺寸。
    private static func parseSizes(_ raw: String?) -> [NSSize] {
        guard let raw, !raw.isEmpty else {
            return [NSSize(width: 680, height: 500),
                    NSSize(width: 900, height: 660),
                    NSSize(width: 1280, height: 800)]
        }
        let parsed: [NSSize] = raw.split(separator: ",").compactMap { item in
            let parts = item.lowercased().split(separator: "x")
            guard parts.count == 2,
                  let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
            return NSSize(width: w, height: h)
        }
        return parsed.isEmpty ? [NSSize(width: 900, height: 660)] : parsed
    }

    /// 抓窗口的**合成结果**（含毛玻璃/阴影）。
    ///
    /// ⚠️ 实测：`CGWindowListCreateImage` 在窗口未激活/合成缓存未刷新时，会返回一张
    /// 尺寸离谱的旧图（窗口 900×660 却只给 180×218），不能盲信。这里改为：
    /// 先把窗口激活并置前，再按「合成图 → 视图层绘制」多路径尝试，**取尺寸与窗口相符的那张**；
    /// 都不符时保留最大的那张并明确标注，避免把「抓取失败」误判成「布局错了」。
    @MainActor
    private static func capture(window: NSWindow, to path: String) async {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        // 让窗口成为最前且激活：抓取 API 对非激活窗口可能返回占位/旧图。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let screen = window.screen?.visibleFrame ?? .zero
        let expected = window.frame.size
        print("[snapshot] 窗口 frame=\(window.frame) 内容=\(window.contentLayoutRect.size) "
              + "屏幕可见区=\(screen) 窗口号=\(window.windowNumber)")

        var best: (image: CGImage, tag: String)?

        // 重试若干轮：抓取窗口合成图偶尔会返回「尺寸对但整张纯色」的占位图
        // （实测遇到过整张纯白），只靠尺寸判定会把空白图当成有效结果。
        for attempt in 1...3 {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 600_000_000)

            let windowID = CGWindowID(window.windowNumber)

            // 路径 ①：整窗合成（含毛玻璃）——首选。
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                                   [.boundsIgnoreFraming, .bestResolution]),
               isSizePlausible(image, expected: expected), !isBlank(image) {
                best = (image, "窗口合成")
                break
            }
            // 路径 ②：用窗口自身矩形作为抓取范围。
            if let image = CGWindowListCreateImage(window.frame, .optionIncludingWindow, windowID,
                                                   [.boundsIgnoreFraming, .bestResolution]),
               isSizePlausible(image, expected: expected), !isBlank(image) {
                best = (image, "窗口合成(指定矩形)")
                break
            }
            // 路径 ③：视图层绘制兜底（毛玻璃会丢，但布局一定真实）。
            if let view = window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let image = rep.cgImage, !isBlank(image) {
                    best = (image, attempt == 1 ? "视图层兜底(无毛玻璃)" : "视图层兜底(无毛玻璃,第\(attempt)轮)")
                    break
                }
            }
            print("[snapshot] 第 \(attempt) 轮未拿到有效图像，重试…")
        }

        guard let best else {
            print("[snapshot] 抓取失败（3 轮均为空白/尺寸不符）：\(path)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: best.image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("[snapshot] \(url.lastPathComponent)  \(best.image.width)x\(best.image.height)"
                  + "  \(best.tag)")
        }
    }

    /// 抓到的图是否与窗口尺寸相称（Retina 下为 2 倍；允许 1~2 倍区间与少量误差）。
    private static func isSizePlausible(_ image: CGImage, expected: CGSize) -> Bool {
        guard expected.width > 0, expected.height > 0 else { return false }
        let ratio = Double(image.width) / Double(expected.width)
        return ratio > 0.9 && ratio < 2.1
    }

    /// 图像是否「近纯色」（抓取失败时的占位图特征）。用 24×24 缩略图的亮度标准差判定。
    private static func isBlank(_ image: CGImage) -> Bool {
        let w = 24, h = 24
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        defer { buf.deallocate() }
        buf.initialize(repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return false
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lums: [Double] = []
        lums.reserveCapacity(w * h)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            lums.append(0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2]))
        }
        let mean = lums.reduce(0, +) / Double(lums.count)
        let variance = lums.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lums.count)
        return variance.squareRoot() < 4.0
    }
}
