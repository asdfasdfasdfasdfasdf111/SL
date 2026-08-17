//
//  SpeedMeter.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/8/24.
//

import Foundation
import Combine

@MainActor
final class SpeedMeter: ObservableObject {
    public nonisolated(unsafe) static let shared: SpeedMeter = .init()
    
    @Published public private(set) var downloadSpeed: Int64 = 0
    
    private let counter = CounterActor()
    private nonisolated(unsafe) var tickerTask: Task<Void, Never>?
    
    nonisolated private init() {}
    
    /// 惰性启动 1s 计量循环：仅在首次计数时开启；连续 3 个计量周期无字节则自动停止，
    /// 空闲时 App 保持零唤醒（此前 ticker 在 init 即启动且永不停止，App 全程每秒空转一次）
    private func ensureTicker() {
        guard tickerTask == nil else { return }
        tickerTask = Task { @MainActor [weak self] in
            var idleSeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
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
    
    public func addByte() async {
        ensureTicker()
        await counter.add(1)
    }
    
    public func addBytes(_ n: Int) async {
        guard n > 0 else { return }
        ensureTicker()
        await counter.add(Int64(n))
    }
    
    deinit {
        tickerTask?.cancel()
        tickerTask = nil
    }
}

actor CounterActor {
    private var intervalBytes: Int64 = 0
    
    func add(_ n: Int64) {
        intervalBytes &+= n
    }
    
    func takeInterval() -> Int64 {
        let v = intervalBytes
        intervalBytes = 0
        return v
    }
}
