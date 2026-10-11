//
//  MicrosoftSkinUploader.swift
//  正版账号的皮肤上传流程：选图 → 尺寸校验 → 刷新令牌 → 上传 Mojang 档案接口
//  → 成功通知（头像即时刷新 + 用户提示）。
//
//  为什么独立于 OfflineSkinService：离线「选择皮肤」只是换本地皮肤文件；
//  正版模式的同名按钮语义是把皮肤**上传到微软档案**（POST /minecraft/profile/skins，
//  对官方服务器与所有游戏服务器生效），数据流完全不同，不混在一个入口里。
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum MicrosoftSkinUploader {

    /// 上传成功后广播本地 PNG：LaunchAvatarSkinViewModel 据此即时刷新头像
    ///（sessionserver 纹理缓存有分钟级延迟，重拉会闪回旧皮肤）。
    static let skinUploadedNotification = Notification.Name("microsoftSkinUploaded")

    /// 入口：面板选图（面板文案与 OfflineSkinService 同源，语义多了「上传到档案」）。
    static func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.title = "选择皮肤图片"
        panel.message = "将上传到正版账号的档案（64×64 或 64×32 PNG），对所有服务器生效"
        panel.allowedContentTypes = [.png]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await uploadPickedSkin(at: url) }
        }
    }

    private static func uploadPickedSkin(at url: URL) async {
        do {
            // 尺寸/格式校验（复用裁剪器的口径与文案：64×64 / 64×32）
            try SkinAvatarCropper.validateSkin(at: url)
            guard case .microsoft(let ms)? = AccountManager.shared.getAccount() else {
                throw MicrosoftAuthError.refreshTokenInvalid
            }
            try await ms.refreshIfNeeded()   // 令牌过期先刷新（刷新链含 completeLogin 并落库）
            let pngData = try Data(contentsOf: url)
            // 模型跟随档案当前值（slim / classic），查询不到按 classic 兜底
            let uuidNoDash = ms.uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let variant = await MicrosoftAuthService.profileTextureInfo(uuidNoDash: uuidNoDash)?.model ?? "classic"
            try await MicrosoftAuthService.uploadProfileSkin(accessToken: ms.accessToken,
                                                             pngData: pngData,
                                                             variant: variant)
            NotificationCenter.default.post(name: skinUploadedNotification, object: pngData)
            NoticeCenter.shared.post(Notice(level: .success, title: "皮肤已更新到正版账号",
                                            message: "新皮肤已上传到 \(ms.name) 的档案，启动游戏即生效"))
        } catch {
            NoticeCenter.shared.post(Notice(level: .error, title: "皮肤上传失败",
                                            message: "\(error.localizedDescription)。当前皮肤未受影响，可稍后重试。"))
        }
    }
}
