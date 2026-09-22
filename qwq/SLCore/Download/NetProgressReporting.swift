//
//  NetProgressReporting.swift
//  SL启动器
//
//  NetManager 的两条进度通道：
//  - reportProgress：单文件进度，每 5 个 tick（约 200ms）主动上报一次，0…1 比例；
//  - overallProgressValue：批量下载的整体进度与已完成文件数，由 downloadAll 的 200ms 采样轮询调用。
//  自 NetDownloader.swift 按职责物理拆出，原第 439-464 行，聚合口径与节流位置均未改动。
//  注意：批量口径的分母是「首片响应头已到达且尚未 done」的文件的 fileSize 之和，
//  该集合由引擎内部状态决定，不可在上层重算（详见 Core/Download/Adapters/MIGRATION.md）。
//

import Foundation

extension NetManager {
    func reportProgress() {
        for record in records where record.progressHandler != nil && !record.isTerminal {
            let p = record.progressValue
            let handler = record.progressHandler!
            Task { @MainActor in handler(p) }
        }
    }

    func overallProgressValue(for ids: [UUID]) -> (Double, Int) {
        var totalSize: Int64 = 0
        var doneSize: Int64 = 0
        var doneCount = 0
        for id in ids {
            guard let r = find(id) else { continue }
            if r.state == .done {
                doneCount += 1
                continue
            }
            if r.fileSize > 0 {
                totalSize += r.fileSize
                doneSize += r.slices.reduce(Int64(0)) { $0 + $1.done }
            }
        }
        let p = totalSize > 0 ? Double(doneSize) / Double(totalSize) : 0
        return (p, doneCount)
    }
}
