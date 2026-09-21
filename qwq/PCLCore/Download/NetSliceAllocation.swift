//
//  NetSliceAllocation.swift
//  PCL.Mac
//
//  NetManager 的分片分配决策（对标 PCL2 TryBeginThread）：
//  首线程、首线程失败重建、失败分片断点续传、禁多线程源、最大碎片尾部 40% 处分割。
//  自 NetDownloader.swift 按职责物理拆出，原第 466-523 行，判定顺序、阈值（>4MB 才分片、
//  1MB 最小分割粒度、尾部 40%）与注释均未改动。分配只负责「造分片 + 交任务」，不做 IO。
//

import Foundation

extension NetManager {
    // MARK: - 分片分配（PCL2 TryBeginThread）

    func tryBeginSlice(_ record: FileRecord) -> Bool {
        guard activeSlices < config.maxSlices else { return false }
        guard let sourceIndex = pickSource(record) else { return false }

        // ① 首线程（起点 0）
        if record.slices.isEmpty {
            record.state = .loading
            let slice = Slice(start: 0, sourceIndex: sourceIndex)
            record.slices.append(slice)
            startSliceTask(record, slice)
            return true
        }

        // 首线程失败且未取到文件大小（无有效数据）→ 重建首线程
        if record.fileSize == -2 {
            record.slices.removeAll { $0.state == .failed && $0.done == 0 }
            if record.slices.isEmpty {
                let slice = Slice(start: 0, sourceIndex: sourceIndex)
                record.slices.append(slice)
                startSliceTask(record, slice)
                return true
            }
        }

        // ② 失败分片断点续传（PCL2：从 DownloadStart + DownloadDone 继续）
        if let failed = record.slices.first(where: { $0.state == .failed && $0.undone(of: record) > 0 }) {
            let slice = Slice(start: failed.start + failed.done, sourceIndex: sourceIndex)
            slice.state = .resumed
            // 旧失败分片保留其已下数据（merge 时拼接），其 undone 因新分片插入自动归零
            record.slices.append(slice)
            record.slices.sort { $0.start < $1.start }
            startSliceTask(record, slice)
            return true
        }

        // ③ 禁多线程源（PCL2：pcl2-server / gitcode / github 仅单线程）
        let target = record.file.urls[sourceIndex].absoluteString
        if target.contains("pcl2-server") || target.contains("gitcode.net") || target.contains("github.com") {
            return false
        }

        // ④ 分割最大碎片：尾部 40% 处切开（PCL2：End - Undone * 0.4）
        //    仅对 >4MB 的大文件分割：MC 版本的库文件数以千计且普遍偏小，
        //    小文件多分片只会加剧连接池争抢，把分片让给真正的大文件收益更高。
        guard record.fileSize >= config.minMultiSliceSize else { return false }
        let candidates = record.slices.filter { $0.state == .downloading || $0.state == .resumed }
        guard let maxSlice = candidates.max(by: { $0.undone(of: record) < $1.undone(of: record) }),
              maxSlice.undone(of: record) >= config.pieceLimit else { return false }
        let cut = maxSlice.end(of: record) - Int64(Double(maxSlice.undone(of: record)) * 0.4)
        if cut <= maxSlice.start { return false }
        let slice = Slice(start: cut, sourceIndex: sourceIndex)
        record.slices.append(slice)
        record.slices.sort { $0.start < $1.start }
        startSliceTask(record, slice)
        return true
    }
}
