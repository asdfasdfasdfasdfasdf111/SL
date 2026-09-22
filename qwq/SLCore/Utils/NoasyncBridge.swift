import Foundation

// MARK: - `noasync` 诊断的同步中转
//
// 新版 SDK 把 `DispatchSemaphore.wait()` 标注为 `noasync`。Swift 书对 `noasync` 的原文：
// "The `noasync` argument indicates that the declared symbol can't be used directly in an
//  asynchronous context. Because Swift concurrency can resume on a different thread after a
//  potential suspension point, using elements like thread-local storage, locks, mutexes, or
//  semaphores across suspension points can lead to incorrect results."
//
// 官方同时给出了正规的规避方式，原文：
//   "If you can guarantee that your code uses a potentially unsafe symbol in a safe manner,
//    you can wrap it in a synchronous function and call that function from an asynchronous context."
// 本文件就是这一条的最小实现。
//
// **语义边界**：本中转不改变阻塞行为，只是让诊断无从下手，属「诊断规避」而非「安全化」。
// 调用方仍须自行保证该阻塞不构成官方点名的反模式（unstructured task + 跨 task 边界用信号量
// 建立依赖）。当前唯一调用点 `TranslationService.translateProject` 是全局并发上限，
// `signal()` 由 `defer` 保证成对，属安全用法。
//
// 历史与更名：本文件原名 `LockCompat.swift`，当时是「macOS 12 兼容的作用域锁」集合
// （`withUnfairLock` + `NSLock.withLockCompat`）。该前提经核实**不成立**——工程部署目标是
// macOS 13.0，且 `NSLock.withLock` 经 `@_alwaysEmitIntoClient` 回部署，在更低目标下也能编译
// （依据见 `docs/SWIFT_LANGUAGE_CHECKLIST.md` §5.6 与 F7 行）。两个符号已删除，
// 调用点分别改用原生 `NSLock.withLock` 与 `OSAllocatedUnfairLock`，
// 仅保留下面这一个确有官方依据的中转。

/// `DispatchSemaphore.wait()` 的同步中转：`wait()` 被标注 `noasync`，在 async 上下文直接调用会告警。
/// 行为与直接调用完全一致（阻塞当前线程直到拿到配额）。
@inline(__always)
func semaphoreWait(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}
