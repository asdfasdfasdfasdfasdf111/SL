//
//  NetScheduling.swift
//  SL启动器
//
//  NetManager 的全局调度循环（对标上游 PCL2 的 StartManager 的 40ms tick）：
//  速度统计、触发条件判定、按 tick 逐文件开片/分片。
//  自 NetDownloader.swift 按职责物理拆出，原第 368-437 行，逻辑、常量与注释均未改动。
//  调度周期由 Config.tickIntervalNs（40ms）决定，分片预算由 Config.maxSlices 决定。
//

import Foundation

extension NetManager {
    // MARK: - 调度循环（对标上游 PCL2 的 StartManager，40ms tick）

    func startTickerIfNeeded() {
        guard tickTask == nil else { return }
        tickTask = Task.detached(priority: .utility) {
            let interval = await self.config.tickIntervalNs
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await self.tickOnce()
                let active = await self.hasActiveWork()
                if !active { break }
            }
            await self.tickerStopped()
        }
    }

    func tickerStopped() {
        tickTask = nil
        // ticker 判断无任务到真正清空引用之间，可能有新下载入队；此时入队方看到旧
        // tickTask 尚在会跳过启动。清空后在 actor 内原子重检，避免新任务永久停在 waiting。
        if hasActiveWork() {
            startTickerIfNeeded()
        }
    }

    func hasActiveWork() -> Bool {
        records.contains { $0.state == .waiting || $0.state == .loading || $0.state == .merging }
    }

    func tickOnce() async {
        tickCount += 1
        if tickCount % 5 == 0 { reportProgress() }

        // 速度统计
        let now = Date()
        let dt = now.timeIntervalSince(lastSpeedTime)
        if dt >= 1 {
            recentSpeed = Double(totalBytes - lastTotalBytes) / dt
            lastTotalBytes = totalBytes
            lastSpeedTime = now
        }

        // 触发条件：速度低于下限，或存在等待中的文件，或存在待续传的失败分片（参照上游 PCL2：Speed < NetTaskSpeedLimitLow OrElse FileRemain > NetTaskThreadLimit）
        let hasFailedSlice = records.contains { record in
            record.slices.contains { slice in
                // 已被续传新片接管的失败片不再计入，否则调度器会反复为同一片建新片
                // （未知大小时 undone 恒为 -1，无法靠 undone 归零，只能靠 superseded 标记）。
                guard slice.state == .failed, !slice.superseded else { return false }
                // 未知文件大小（fileSize == -1）时 undone 恒为 -1，需特判为「可重试」，
                // 否则调度器不会为断流的首线程补片（对应 NetSliceAllocation 的 fileSize <= 0 分支）。
                if record.fileSize == -1 { return true }
                return slice.undone(of: record) > 0
            }
        }
        let needMore = recentSpeed < Double(config.speedLimitLow)
            || records.contains { $0.state == .waiting }
            || hasFailedSlice
        guard needMore else { return }

        var budget = max(0, config.maxSlices - activeSlices)
        guard budget > 0 else { return }

        // 优先给等待中的文件开首线程，再给下载中的文件分割（参照上游 PCL2：FilesWaiting → FilesLoading）
        for record in records where record.state == .waiting {
            guard budget > 0 else { break }
            if tryBeginSlice(record) {
                budget -= 1
                try? await Task.sleep(nanoseconds: config.tickIntervalNs)
            }
        }
        for record in records where record.state == .loading {
            guard budget > 0 else { break }
            if tryBeginSlice(record) {
                budget -= 1
                try? await Task.sleep(nanoseconds: config.tickIntervalNs)
            }
        }
    }
}
