//
//  MinecraftLauncher+BridgeCompatibility.swift
//  兼容层：桥接旧 UI 代码到启动核心（MinecraftLauncher）的关联存储扩展。
//  2026-10-03 自 SLLaunchBridge.swift 拆出（纯物理搬移，逻辑零变更）。
//

import Foundation
import ObjectiveC

extension MinecraftLauncher {
    /// 用户主动终止标志：terminate() 时置 true，completion 回调据此判断不报异常
    public var isUserTerminated: Bool {
        get { _objCIsUserTerminated }
        set { _objCIsUserTerminated = newValue }
    }
    /// 终止游戏进程：标记为用户主动关闭
    /// 注意：使用 launcher 自己的 currentProcess，避免多游戏共用 instance 时终止错误进程
    public func terminate() {
        _objCIsUserTerminated = true
        currentProcess?.terminate()
    }
    /// 日志缓冲：logHandler 在 session 建立前到达时暂存于此，session 建立后 flush。
    /// ⚠️ 它只为「会话建立前」那一小段窗口服务 —— 是否还处在那个窗口由
    /// `hasEverHadSession` 判定，不是「当前有没有会话」。
    public var pendingLogs: [String] {
        get { _objCPendingLogs }
        set { _objCPendingLogs = newValue }
    }
    /// 该 launcher 是否**建过**会话（不管现在还在不在）。
    /// 用途：界定 `pendingLogs` 的合法生命周期。用户把日志卡关掉后，后续日志行已经
    /// 没有消费者，必须丢弃 —— 否则会一直往 `pendingLogs` 追加，而唯一的清理点只有
    /// `LaunchSessionManager.addSession`（只在建会话时执行一次），于是内存只涨不落：
    /// Forge/NeoForge 刷屏级的长会话下，关掉日志卡反而让内存无限增长。
    public var hasEverHadSession: Bool {
        get { _objCHasEverHadSession }
        set { _objCHasEverHadSession = newValue }
    }
}

private var _objCIsUserTerminatedKey: UInt8 = 0
private var _objCPendingLogsKey: UInt8 = 0
private var _objCHasEverHadSessionKey: UInt8 = 0
extension MinecraftLauncher {
    /// 用 objc 关联对象存储 isUserTerminated（不修改 MinecraftLauncher 核心类的存储）
    private var _objCIsUserTerminated: Bool {
        get { (objc_getAssociatedObject(self, &_objCIsUserTerminatedKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &_objCIsUserTerminatedKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    private var _objCPendingLogs: [String] {
        get { (objc_getAssociatedObject(self, &_objCPendingLogsKey) as? NSArray) as? [String] ?? [] }
        set { objc_setAssociatedObject(self, &_objCPendingLogsKey, newValue as NSArray, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    /// 同上：opaque 标志位，未设置时按 false（等价于「还没建过会话」）
    private var _objCHasEverHadSession: Bool {
        get { (objc_getAssociatedObject(self, &_objCHasEverHadSessionKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &_objCHasEverHadSessionKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}