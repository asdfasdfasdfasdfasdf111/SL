> 🗄️ **本文已归档（2026-10-05）**：内容为 ARCHAEOLOGY-NOTES.md 撰写时点的历史快照/审计记录，
> 其中的行号、计数、现状描述**可能已失效**，勿据此判断当前代码。现状请以
> `ARCHITECTURE.md` / `HANDOVER.md` / `README.md` 及代码本身为准。

# 考古注释归档

> 用途：存放从源码注释里**剥离出来的考古内容**（某个值的来龙去脉、某个提交改了什么、
> 某个实现为什么被删除）。按 ARCHITECTURE.md §九纪律：源码注释只写「约束与理由」，
> 考古过程一律放这里。源码里只保留指向本文件的简短引用。

## 约定

- 每个条目记录：来源文件 / 归档日期 / 考古内容 / 剥离后源码保留的约束。
- 防误删类注释（⚠️ 必须保留、判据一致等）**不进本文件**，留在源码。

---

## GameProcessController.swift（2026-10-02 归档）

**考古内容**：`waitForTermination()`（会话层等待进程退出）已删除 —— 其唯一实现路径
依赖未接线的 `InMemoryGameSessionStore`，全库（含测试）无引用、从未执行。

**源码保留的约束**（不可重犯的竞态结论，接线会话观察时必须遵守）：
挂 `process.terminationHandler` 与检查 `process.isRunning` 之间存在竞态窗口 ——
进程恰好在两步之间退出时 handler 永不回调、continuation 永不 resume（调用方永久挂起）。
正确形态：**先挂 handler、再补检状态**，两条路径共用一次性门控，保证恰好 resume 一次。

---

## PopupCardScaffold.swift（2026-10-02 归档）

**考古内容**（合并沿革）：`ModInstallSelectionView` 与 `ModpackFolderPickerView` 同源
自 `ModInstallViews.swift`，脚手架逐段复制（审计判据 B #4），收为 PopupCardScaffold 一份时：
- header 底部 padding 原为 12 / 14，合并统一为 14（视觉差异 2pt，无行为影响）。

**源码保留的约束**（当前必须遵守）：
- 入场动画的 `onAppear` 由骨架统一 dispatch 到主队列下一 tick 再动画；调用方若有额外
  onAppear 逻辑（如单实例自动选中）挂在自己的视图上即可。