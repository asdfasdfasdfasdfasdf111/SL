//
//  NetSliceAllocation.swift
//  SL启动器
//
//  NetManager 的分片分配决策（对标上游 PCL2 的 TryBeginThread）：
//  首线程、首线程失败重建、失败分片断点续传、禁多线程源、最大碎片尾部 40% 处分割。
//  自 NetDownloader.swift 按职责物理拆出，原第 466-523 行，判定顺序、阈值（>4MB 才分片、
//  1MB 最小分割粒度、尾部 40%）与注释均未改动。分配只负责「造分片 + 交任务」，不做 IO。
//

import Foundation

extension NetManager {
    // MARK: - 分片分配（对标上游 PCL2 的 TryBeginThread）

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

        // 未获取 / 未知文件大小（fileSize == -2 尚未取得大小，或 -1 未知大小）：首线程可能失败。
        // -1 且失败分片已下到数据 → 按 failed.start + failed.done 断点续传；
        // 首线程零进度（含 -2 未取得大小）则从 0 重建首线程（重取大小或重下整文件）。
        // 保留原 -2 分支「零进度重建首线程」行为，不回退。
        if record.fileSize <= 0 {
            // `!superseded` 不可省：未知大小时 `undone` 恒为 -1，无法像已知大小那样靠 undone 归零
            // 来表达「这片已被接管」，只能靠标记。否则每个 tick 都会为同一失败片再建一条续传片。
            if let failed = record.slices.first(where: { $0.state == .failed && !$0.superseded && $0.done > 0 }) {
                let slice = Slice(start: failed.start + failed.done, sourceIndex: sourceIndex)
                slice.state = .resumed
                // 先标记接管、再建片：本片保留已下数据供合并时拼接，但不再参与后续「待续传」判定
                failed.superseded = true
                record.slices.append(slice)
                record.slices.sort { $0.start < $1.start }
                startSliceTask(record, slice)
                return true
            }
            record.slices.removeAll { $0.state == .failed && $0.done == 0 }
            if record.slices.isEmpty {
                let slice = Slice(start: 0, sourceIndex: sourceIndex)
                record.slices.append(slice)
                startSliceTask(record, slice)
                return true
            }
        }

        // ② 失败分片断点续传（参照上游 PCL2：从 DownloadStart + DownloadDone 继续）
        if let failed = record.slices.first(where: { $0.state == .failed && !$0.superseded && $0.undone(of: record) > 0 }) {
            let slice = Slice(start: failed.start + failed.done, sourceIndex: sourceIndex)
            slice.state = .resumed
            // 旧失败分片保留其已下数据（merge 时拼接）；此处同样显式标记接管，
            // 与 undone 归零形成双重保险（并让「已接管」这一语义在两种大小口径下一致）
            failed.superseded = true
            record.slices.append(slice)
            record.slices.sort { $0.start < $1.start }
            startSliceTask(record, slice)
            return true
        }

        // ③ 禁多线程源（参照上游 PCL2：pcl2-server / gitcode / github 仅单线程）
        let target = record.file.urls[sourceIndex].absoluteString
        if target.contains("pcl2-server") || target.contains("gitcode.net") || target.contains("github.com") {
            return false
        }

        // ④ 分割最大碎片：尾部 40% 处切开（参照上游 PCL2：End - Undone * 0.4）
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
