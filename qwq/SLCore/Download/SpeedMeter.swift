//
//  SpeedMeter.swift
//  SL启动器
//
//  下载速度计量：把下载过程中逐块累计的字节数，按 1 秒窗口换算成「字节/秒」发布给 UI。
//
//  分工：字节累加在子 Actor（`CounterActor`）里做 —— `addByte` 会被多个并发下载任务
//  高频调用，不能每次都回到主线程；1 秒循环则跑在 MainActor 上读取并清零。
//  读写分离，避免「每字节一次跨隔离域同步」的开销。
//
//  Created by YiZhiMCQiu on 2025/8/24.
//

import Foundation
import Combine

@MainActor
/// 全局单例（`shared`）。UI 只需订阅 `downloadSpeed`，不必关心计量细节。
/// 主体标了 `@MainActor`：`downloadSpeed` 是 `@Published`，从非主线程改动会触发
/// SwiftUI 的线程检查；把整个类型钉在主线程上比逐个属性标注更不容易漏。
final class SpeedMeter: ObservableObject {
    public static let shared: SpeedMeter = .init()
    
    /// 最近一个 1 秒窗口内新增的字节数，即「字节/秒」。
    /// 连续 3 个窗口没有新增时会被置 0（而不是停在上次的旧值上）。
    @Published public private(set) var downloadSpeed: Int64 = 0
    
    private let counter = CounterActor()
    /// 1 秒计量循环的句柄；nil 表示当前空闲、没有循环在跑（也用于「是否已在跑」的判重）。
    ///
    /// `nonisolated(unsafe)` 是**必需**的：`deinit` 不在 MainActor 上执行，
    /// 若照常隔离，deinit 里根本读不到这个属性（编译期即报错）。
    /// 这里标 unsafe 是安全的 —— 写它的只有 MainActor 上的 `ensureTicker` 与 `deinit`。
    private nonisolated(unsafe) var tickerTask: Task<Void, Never>?
    
    /// `nonisolated`：让 `static let shared` 能在任意隔离域里完成一次性初始化，
    /// 而不触发 MainActor 隔离检查（单例初始化本就只发生一次，无并发风险）。
    nonisolated private init() {}
    
    /// 惰性启动 1s 计量循环：仅在首次计数时开启；连续 3 个计量周期无字节则自动停止，
    /// 空闲时 App 保持零唤醒（此前 ticker 在 init 即启动且永不停止，App 全程每秒空转一次）
    private func ensureTicker() {
        guard tickerTask == nil else { return }
        tickerTask = Task { @MainActor [weak self] in
            var idleSeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }
                let intervalBytes = await self.counter.takeInterval()
                self.downloadSpeed = intervalBytes
                idleSeconds = intervalBytes == 0 ? idleSeconds + 1 : 0
                if idleSeconds >= 3 {
                    self.tickerTask = nil
                    break
                }
            }
        }
    }
    
    /// 记录 1 个字节（下载循环按块推进时调用）。属热路径，尽量别在这里加分配或日志。
    public func addByte() async {
        ensureTicker()
        await counter.add(1)
    }
    
    /// 批量记录 n 个字节。
    /// `n <= 0` 直接返回，且**不会启动计量循环** —— 否则一次「0 字节」的调用
    /// 会把 ticker 空转起来，再白等 3 个窗口才停。
    public func addBytes(_ n: Int) async {
        guard n > 0 else { return }
        ensureTicker()
        await counter.add(Int64(n))
    }
    
    /// 取消计量循环。单例实际不会被释放，这层保护是为「将来改成非单例」留的 ——
    /// 否则残留的 Task 会一直持有 self。
    deinit {
        tickerTask?.cancel()
        tickerTask = nil
    }
}

/// 字节累加器。用 `actor` 而不是锁：`add` 会被多个并发下载任务高频调用，
/// actor 的串行执行天然免锁；而 `takeInterval` 的「读取并清零」在 actor 里是
/// **不可分割的一步**，不会出现「读到一半被插进新的 add」导致漏计。
actor CounterActor {
    private var intervalBytes: Int64 = 0
    
    /// 累加。故意用溢出回绕加法 `&+=`：即便计数异常（例如调用方传了巨型值），
    /// 也只会得到一个奇怪的速度读数，而不会因整数溢出直接崩溃。
    func add(_ n: Int64) {
        intervalBytes &+= n
    }
    
    /// 取出本窗口累计值**并清零** —— 单次消费语义：连续调用两次，第二次必然得到 0。
    /// 计量循环每秒只应调用一次；多调会把速度读低（分母仍是 1 秒）。
    func takeInterval() -> Int64 {
        let v = intervalBytes
        intervalBytes = 0
        return v
    }
}
