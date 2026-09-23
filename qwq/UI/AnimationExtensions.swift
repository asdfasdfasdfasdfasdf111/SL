//
//  AnimationExtensions.swift
//  全局共享的弹簧动画曲线。三个具名弹簧按「弹的力度」分三档，界面各处一律引用它们，
//  不再就地写裸 spring 参数。
//
//  为什么集中定义：动画参数散落在各视图时，同一种交互在不同页面会得到不同手感
//  （本工程出现过同类「卡片弹入」在两处分别写 spring(response: 0.35) 与 0.6 的情况）。
//  收敛成三个具名常量后，「整体要不要更弹一点」变成一次全局决策，而不是几十处局部改动。
//
//  参数含义（`Animation.spring`）：
//  - response：弹簧完成一次振动的近似时长（秒）。越大越慢、越「松弛」。
//  - dampingFraction：阻尼比。1.0 为临界阻尼（不过冲）；越小过冲越明显、越「弹」。
//  - blendDuration：与前后相邻动画衔接的混合时长，避免两个动画叠加时速度突变。
//  官方链接 https://developer.apple.com/documentation/swiftui/animation/spring(response:dampingfraction:blendduration:)
//
//  维护提示：新增动画前先在这三档里挑；确实都不合适才新增常量，
//  并在下面的注释里写清它与其他三档的区别，否则很快会退化成「一堆看不出差别的 spring」。
//

import SwiftUI

extension Animation {
    /// 力度最大的一档：阻尼 0.5、过冲明显，用于**退场/切换**这类需要「干脆」的动作。
    /// 现有使用点：`TaskPill` 的退场（透明度归零 + 缩到 0.5）、
    /// `GameCategoryView` 切换所选中游戏版本时的内容切换。
    static let explosiveSpring = Animation.spring(response: 0.7, dampingFraction: 0.5, blendDuration: 0.2)

    /// 力度中等、时长最长的一档（response 0.9 / 阻尼 0.4）：过冲明显但节奏舒展，是使用面最广的一档。
    /// 现有使用点：`TaskPill` 的入场弹入、`NoticeOverlay` 的提示卡换卡、
    /// `ColorPickerView` 的色块放大、`CategoryContentView` 的会话日志展开与计数变化、
    /// `LaunchCoordinator` 的启动流程状态切换。
    static let exaggeratedSpring = Animation.spring(response: 0.9, dampingFraction: 0.4, blendDuration: 0.35)

    /// 力度最小、时长最短的一档（response 0.6 / 阻尼 0.5）：用于**短促反馈**，不喧宾夺主。
    /// 现有使用点：`VersionButton` 与 `ColorPickerView` 的按下回弹、
    /// `NoticeOverlay` 的提示卡自身弹入与「查看详情/收起详情」展开。
    static let punchySpring = Animation.spring(response: 0.6, dampingFraction: 0.5, blendDuration: 0.2)
}