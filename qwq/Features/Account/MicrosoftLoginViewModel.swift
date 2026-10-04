//
//  MicrosoftLoginViewModel.swift
//  微软账号登录（设备码流程）的 UI 状态机与副作用编排。
//
//  位置：启动页（CategoryContentView）的账号行 + 设备码覆盖层卡片共用的唯一持有者，
//  与同页的 LaunchEntryViewModel / LaunchAvatarSkinViewModel 同级设计
//  （Features/Account/，自己创建、绑在视图上）。
//
//  流程（一次 startLogin）：
//    1. `MicrosoftAuthService.startDeviceCode()` 拿到设备码 → 状态 `.waitingForCode`，
//       卡片展示 userCode 与 verificationURI，引导用户在浏览器打开 microsoft.com/link 输入；
//    2. 后台任务以服务端给的 interval 轮询 token 端点（`waitForAuthorization`），
//       期间用户随时可点「取消」——本类型置位取消令牌（task.cancel），轮询感知后抛出；
//    3. 授权完成 → `completeLogin` 补齐 XBL→XSTS→MC→档案 全链路 → 构造
//       `MicrosoftAccount` → `AccountManager.shared.upsert(.microsoft(account))` 持久化并设为已选；
//    4. 状态 `.signedIn`，启动页账号行显示「已登录：名字」+ 退出登录。
//
//  并发：`@MainActor`（与 `SkinPatchCoordinator` 同款）；网络在
//  `MicrosoftAuthService`（nonisolated）完成。轮询期间主线程只展示状态，
//  不阻塞（`waitForAuthorization` 内部是 async 睡眠轮询）。
//
//  UI 刷新契约：`AccountManager` 的 `@CodableAppStorage` 无 KVO（读 UserDefaults 才解码），
//  视图不依赖它做通知；本类型自己持 `@Published phase` 驱动卡片与账号行重绘。
//
//  注释引用约定：一律写「文件 + 符号/场景」，不写行号。
//

import Foundation
import Combine
import os

@MainActor
final class MicrosoftLoginViewModel: ObservableObject {

    /// 登录状态机。视图**只读**，改写一律经本类型的方法（状态迁移与副作用成对发生）。
    /// `Equatable` 为手写而非合成：`.signedIn` 的关联值 `MicrosoftAccount` 是 final class
    /// （协议 `Account` 不要求 Equatable），合成会直接编译失败；手写 `==` 只比
    /// id / 设备码 / 文案，不深入账号字段——动画与 `animation(_:value:)` 只需要
    /// 感知「相位变了」，不需要感知账号内部字段变化。
    enum Phase: Equatable {
        /// 未登录（初始态 / 取消 / 登出后）
        case idle
        /// 已拿到设备码，等用户在浏览器完成授权（卡片展示设备码 + 轮询进度）
        case waitingForCode(MicrosoftDeviceCode)
        /// 登录成功，账号已持久化（账号行显示档案名）
        case signedIn(MicrosoftAccount)
        /// 流程失败（网络 / 用户拒绝 / 无正版资格等），带用户可读文案
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.waitingForCode(let a), .waitingForCode(let b)): return a == b
            case (.signedIn(let a), .signedIn(let b)): return a.id == b.id
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    /// 在飞轮询任务的句柄：取消登录 / 重新登录时取消，防止旧结果回写覆盖新状态
    private var pollTask: Task<Void, Never>?

    /// 取消令牌：用户点「取消」时置位，轮询感知后以 `MicrosoftAuthError.cancelled` 中断。
    /// 单独持旗而非依赖 task 状态：`waitForAuthorization` 的 checkCancelled 闭包
    /// 从 nonisolated 上下文被调用，直接读 task 状态或 self 的隔离属性都会跨隔离域，
    /// 用加锁的值盒最干净（与 SLLaunchBridge 的 LaunchRunningState 同款手法）。
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    // MARK: - 查询

    /// 恢复已选账号：页面出现时若 AccountManager 里已有可用微软账号，直接显示已登录。
    /// 使用方：`CategoryContentView` 的 `onAppear`（启动页每次出现都恢复一次）。
    func loadStoredAccount() {
        guard case .idle = phase else { return }
        if let ms = AccountManager.shared.getAccount()?.microsoftAccount, ms.isUsable {
            phase = .signedIn(ms)
        }
    }

    // MARK: - 登录

    /// 发起设备码登录。仅在 `.idle` 态有意义（其余状态是空操作——
    /// 卡片只在该态渲染登录按钮，这里的守卫是防御性的）。
    func startLogin() {
        guard case .idle = phase else { return }
        cancelFlag.withLock { $0 = false }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            do {
                let code = try await MicrosoftAuthService.startDeviceCode()
                guard let self, !Task.isCancelled else { return }
                self.phase = .waitingForCode(code)

                let tokens = try await MicrosoftAuthService.waitForAuthorization(
                    deviceCode: code,
                    checkCancelled: { [cancelFlag = self.cancelFlag] in
                        cancelFlag.withLock { $0 }
                    },
                    cancellationError: MicrosoftAuthError.cancelled
                )
                // do 块内 `guard let self` 已在本块开头解包过（94 行），
                // 之后 self 是非可选强持有；这里只需复查任务是否被取消
                //（await 可能被 cancel 解除挂起，醒来后不再继续）。
                if Task.isCancelled { return }

                let chain = try await MicrosoftAuthService.completeLogin(
                    msaAccessToken: tokens.accessToken,
                    msaRefreshToken: tokens.refreshToken
                )
                if Task.isCancelled { return }

                let account = MicrosoftAccount(
                    uuid: MicrosoftAccount.uuid(fromProfileID: chain.profile.id),
                    name: chain.profile.name,
                    msaRefreshToken: tokens.refreshToken,
                    accessToken: chain.accessToken,
                    accessTokenExpiry: Date().addingTimeInterval(TimeInterval(chain.expiresIn))
                )
                AccountManager.shared.upsert(.microsoft(account))
                self.phase = .signedIn(account)
            } catch {
                guard let self, !Task.isCancelled else { return }
                if case .cancelled = error as? MicrosoftAuthError {
                    // 用户主动取消：回到初始态，不显示错误
                    self.phase = .idle
                } else {
                    // 其余失败（拒绝授权 / 无正版 / 网络）把文案交给卡片展示
                    self.phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }

    /// 用户点「取消」：置位取消令牌并取消轮询任务，回到初始态。
    func cancelLogin() {
        cancelFlag.withLock { $0 = true }
        pollTask?.cancel()
        pollTask = nil
        if case .waitingForCode = phase {
            phase = .idle
        }
    }

    // MARK: - 登出

    /// 退出登录：从 AccountManager 移除该账号并回到初始态。
    func signOut() {
        guard case .signedIn(let account) = phase else { return }
        AccountManager.shared.remove(accountID: account.id)
        phase = .idle
    }

    // MARK: - 设备码卡片辅助

    /// 是否处于「展示设备码」态（覆盖层卡片的显示条件）。
    var isWaitingForCode: Bool {
        if case .waitingForCode = phase { return true }
        return false
    }

    /// 当前设备码（仅 `.waitingForCode` 态非空）。
    var currentDeviceCode: MicrosoftDeviceCode? {
        if case .waitingForCode(let code) = phase { return code }
        return nil
    }
}