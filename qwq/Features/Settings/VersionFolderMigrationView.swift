//
//  VersionFolderMigrationView.swift
//  「版本目录规范化」设置页：迁移期入口。
//
//  背景（2026-10-02 收尾轮）：版本目录名规范化（把「纯版本号但装了加载器」的目录
//  重命名为「版本-加载器」，如 1.6.1 → 1.6.1-Forge）是一项**有写副作用**的操作。
//  老实现把它挂在读取路径上（读一次版本列表就偷偷改名），本页把它隔离成显式迁移：
//   - 「读取时自动规范化」开关 = 迁移期开关，默认关（默认不干跑）；
//   - 开着开关时，读取路径仍沿用老行为（自动改名）；
//   - 不开开关时，用户可在这里**手动扫描 → 查看计划 → 确认执行**，全程可见可控。
//
//  本页不自己持久化任何东西：开关唯一真值在 `MinecraftVersionManager.autoNormalizeOnRead`
//  （UserDefaults）；执行只调 `MinecraftVersionManager.applyVersionFolderRenames`。
//

import SwiftUI

/// 版本目录规范化迁移页。
struct VersionFolderMigrationView: View {
    @ObservedObject var settings = LauncherSettings.shared

    // 扫描得到的「旧名 → 新名」计划。nil = 还没扫过；空字典 = 扫过但无需规范化。
    @State private var plan: [String: String]?
    // 执行结果提示（上次 apply 实际改了多少个）。
    @State private var appliedCount: Int?
    // 是否正在扫描（扫描是纯同步磁盘读，量小，但仍给一个轻状态防止连点）。
    @State private var isScanning = false
    // 执行前的二次确认。
    @State private var confirmApply = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("版本目录规范化").font(.title2.bold())
            Text("把「纯版本号但装了加载器的版本目录」改名为「版本-加载器」（如 1.6.1 → 1.6.1-Forge），列表便能显示加载器后缀。此操作会重命名目录并同步改写其中的 version.json。")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("读取版本列表时自动规范化", isOn: Binding(
                get: { MinecraftVersionManager.autoNormalizeOnRead },
                set: { MinecraftVersionManager.autoNormalizeOnRead = $0 }
            ))
            .font(.callout)

            Divider()

            // 手动配置区
            VStack(alignment: .leading, spacing: 10) {
                Text("当前游戏根目录：\(settings.selectedGameRoot.isEmpty ? "（未设置）" : settings.selectedGameRoot)")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 10) {
                    Button(action: scan) {
                        Label("扫描待规范化目录", systemImage: "arrow.clockwise")
                    }
                    .disabled(settings.selectedGameRoot.isEmpty || isScanning)
                    .help("扫描当前游戏根目录，找出可重命名的版本目录（只读，不改动磁盘）")

                    if let p = plan, !p.isEmpty {
                        Button(action: { confirmApply = true }) {
                            Label("确认执行（\(p.count) 个）", systemImage: "checkmark.seal")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("按上面的计划重命名目录并改写 json —— 此步会写磁盘")
                    }
                }

                if let p = plan, !p.isEmpty {
                    // 计划明细
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(p.sorted(by: { $0.key < $1.key }), id: \.key) { old, new in
                                Text("\(old)  →  \(new)")
                                    .font(.system(.callout, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(maxHeight: 110)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                } else if plan != nil {
                    Text("未发现需要规范化的版本目录。").font(.callout).foregroundColor(.secondary)
                }

                if let n = appliedCount {
                    Text("已执行：\(n) 个目录重命名完成。")
                        .font(.callout)
                        .foregroundColor(.green)
                }

                // 回退说明（迁移期「回退文案」）
                Text("回退方法：自动规范化随时可在此关闭；已改名的目录，手动把文件夹名与其中的 version.json 名改回旧名即可恢复。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("确认执行版本目录重命名？", isPresented: $confirmApply, titleVisibility: .visible) {
            Button("执行（\(plan?.count ?? 0) 个）") { apply() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将按上面列出的计划重命名目录并改写 version.json。此操作会写磁盘，且不可自动撤销（回退需手动改回）。")
        }
    }

    /// 只读扫描：生成计划，不改磁盘。
    private func scan() {
        isScanning = true
        defer { isScanning = false }
        appliedCount = nil
        plan = MinecraftVersionManager.planVersionFolderRenames(gameRoot: settings.selectedGameRoot)
    }

    /// 按计划执行（唯一会写磁盘的动作，必须经过上面的二次确认）。
    private func apply() {
        guard let p = plan, !p.isEmpty else { return }
        let result = MinecraftVersionManager.applyVersionFolderRenames(gameRoot: settings.selectedGameRoot, plan: p)
        appliedCount = result.count
        // 执行完后重新扫描，展示剩余未处理的（正常应为空）
        plan = MinecraftVersionManager.planVersionFolderRenames(gameRoot: settings.selectedGameRoot)
    }
}