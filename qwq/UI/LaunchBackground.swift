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
struct LaunchBackground: View {
    /// 渐变的起点 / 终点，动画实现"背景在缓慢流动"。
    @State private var start = UnitPoint(x: 0, y: -2)
    @State private var end = UnitPoint(x: 4, y: 0)

    /// Reduce Motion：背景静止（省 GPU + 可访问性）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 暖色系配色（日落 / 朝霞的调子）。只在这段里取色，天然和谐。
    private let colors: [Color] = [.orange, .pink, .purple, .orange, .red, .orange, .red]

    var body: some View {
        LinearGradient(colors: colors, startPoint: start, endPoint: end)
            // 超大模糊把渐变"糊"成氛围光：色带边界消失，只剩颜色在场内的缓慢过渡。
            .blur(radius: 220)
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