import Foundation
import os

// MARK: - macOS 12 兼容的 async 安全作用域锁
//
// 新版 SDK 把 os_unfair_lock_* / NSLock.lock() 等标注为 noasync：
// 在 async 函数里直接调用会产生并发警告（Swift 6 语言模式下升级为错误）。
// Apple 官方建议的 OSAllocatedUnfairLock / NSLock.withLock 需要 macOS 13，
// 这里把底层调用收进同步函数——noasync 诊断只针对 async 上下文中的直接调用，
// 经同步函数中转后加锁语义与原来的 lock/unlock 配对完全一致。

/// os_unfair_lock 的作用域加锁（macOS 12 可用的 OSAllocatedUnfairLock.performWhileLocked 等价物）。
@inline(__always)
@discardableResult
func withUnfairLock<T>(_ lock: UnsafeMutablePointer<os_unfair_lock>, _ body: () throws -> T) rethrows -> T {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    return try body()
}

extension NSLock {
    /// NSLock 的作用域加锁（等价于 macOS 13 的 NSLock.withLock，macOS 12 可用）。
    @inline(__always)
    @discardableResult
    func withLockCompat<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// DispatchSemaphore.wait 的同步中转：wait() 被标注 noasync，async 上下文直接调用会告警。
/// 行为与直接调用完全一致（阻塞当前线程直到拿到配额）。
@inline(__always)
func semaphoreWait(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}
