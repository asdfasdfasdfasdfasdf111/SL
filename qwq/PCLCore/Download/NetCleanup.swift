//
//  NetCleanup.swift
//  PCL.Mac
//
//  NetManager 的取消与临时文件清理：
//  - cancelRecords：取消仍在运行的分片任务并清理临时分片（失败/取消时避免孤儿任务）；
//  - cleanupTemps：删除文件记录下所有分片的 .tmp 临时文件（SharedConstants.temperatureURL 下）。
//  自 NetDownloader.swift 按职责物理拆出，原第 329-339、807-813 行，调用时机与清理范围均未改动。
//

import Foundation

extension NetManager {
    /// 取消仍在运行的分片任务并清理临时文件（失败/取消时避免孤儿任务）
    func cancelRecords(_ ids: [UUID]) {
        for id in ids {
            guard let record = find(id) else { continue }
            for (_, task) in record.sliceTasks {
                task.cancel()
            }
            record.sliceTasks.removeAll()
            cleanupTemps(record)
        }
    }

    func cleanupTemps(_ record: FileRecord) {
        for slice in record.slices {
            if let temp = slice.tempURL {
                try? FileManager.default.removeItem(at: temp)
            }
        }
    }
}
