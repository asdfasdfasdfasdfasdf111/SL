//
//  LaunchBackground.swift
//  qwq
//
//  启动器主窗口的流动渐变背景（观感原型验收后落地）。
//
//  来源：BetterWeather（Aayush9029/BetterWeather，GPL-3.0）的 `BackgroundGradient`——
//  一组暖色 LinearGradient 叠超大半径模糊，起点/终点用长周期 repeatForever 交叉漂移，
//  静态看是氛围光、动起来是"活的"。本文件将其适配到启动器：
//  - 配色沿用（橙/粉/紫/橙/红），可整体替换为自定义色板；
//  - 挂载点：主窗口 BlurView（behindWindow 毛玻璃）之上、内容之下 ——
//    毛玻璃保底后渐变被压到很低亮度，文字可读性不受影响；
//  - Reduce Motion 开启时静止（macOS 辅助功能）；
//  - 周期 15s（原 60s 用户嫌太慢；25s 更舒展，注释留档）。
//
//  ⚠️ 移植边界：颜色数组与模糊手法为观感移植（PCL/BetterWeather 系），
//  见 docs/THIRD-PARTY-NOTICES.md 的登记。
//

import SwiftUI

/// 启动器主窗口的流动氛围光背景。
/// 用法：`ZStack { LaunchBackground(); 内容 }`。
/// 调色板收口在 `palette`（FloatingGlass 的浮层底垫也用它，保证两边同色）。
struct LaunchBackground: View {
    /// 渐变的起点 / 终点，动画实现"背景在缓慢流动"。
    @State private var start = UnitPoint(x: 0, y: -2)
    @State private var end = UnitPoint(x: 4, y: 0)

    /// Reduce Motion：背景静止（省 GPU + 可访问性）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 暖色系配色（日落 / 朝霞的调子）。只在这段里取色，天然和谐。
    static let palette: [Color] = [.orange, .pink, .purple, .orange, .red, .orange, .red]

    // MARK: - 与 FloatingGlass 共享的参数（浮层背景副本必须逐项一致）
    //
    // 这三组参数是「窗口背景」与「浮层底部背景副本」的唯一真源。改背景观感时只改这里，
    // 两处自动同步 —— 否则浮层底会出现和窗口不同源的色带（2026-10-12 实测踩过）。

    /// 高斯模糊半径：把渐变糊成氛围光，色带边界消失只剩颜色在场内的缓慢过渡。
    static let blurRadius: CGFloat = 220

    /// backdrop 的渐变起终点（静态定稿值，不随流动动画变）。
    /// 取动画中段的一组代表性方向，与真实背景的静态帧最接近。
    static let backdropStart = UnitPoint(x: 2, y: -1)
    static let backdropEnd = UnitPoint(x: -1, y: 1)

    var body: some View {
        LinearGradient(colors: Self.palette, startPoint: start, endPoint: end)
            // 超大模糊把渐变"糊"成氛围光：色带边界消失，只剩颜色在场内的缓慢过渡。
            .blur(radius: Self.blurRadius)
            .ignoresSafeArea()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 15).repeatForever(autoreverses: true)) {
                    start = UnitPoint(x: 4, y: 0)
                    end = UnitPoint(x: 0, y: 2)
                }
            }
    }
}