#!/bin/bash
# 快速类型检查（两种口径）
#
# 用途：改动后的即时反馈，比真实 xcodebuild 快一个数量级。
# 但它**不是**最终判定 —— 真实编译才是，见 scripts/verify-build.sh。
#
# 口径一：默认隔离（对应工程里未开 default-isolation 的编译单元）
# 口径二：-default-isolation MainActor（对应 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）
#
# 基线（拆分重构完成时）：口径一 44 告警 / 口径二 58 告警，0 错误。
#
# ⚠️ 2026-09-24 实测重记：HEAD（b8c9d39）实际为**口径一 34 / 口径二 24**。
# 复核方式：`git archive HEAD | tar -x -C /tmp/sl-head-base` 导出后单独跑一遍（只读操作），
# 与工作区结果对比 **同为 34 / 24** —— 即当前工作区改动零新增告警。
# 相比上面记的 46 / 56 整体下降，疑似 Xcode/SDK 更新后部分告警不再产生；
# 此后以 34 / 24 为准，判定标准仍是「告警集合与基线一致」而不是仅数量相等。
# 提示：git archive 是只读操作；不要用 git stash 复核，沙箱内 stash 会留下 .git/index.lock。
#
# ⚠️ 口径一有个必须知道的**统计口径**：本脚本把 qwq 与 qwqTests 编进**同一个模块**，
# 于是每个测试文件里的 `@testable import qwq` 都会产生一条
#   `file 'XxxTests.swift' is part of module 'qwq'; ignoring import`
# 这是**本脚本的产物，不是工程告警**（真实 xcodebuild 里 qwqTests 是独立 target，不存在该问题）。
# 该告警每文件一条，且 swiftc 会把它打印成两行（第二行以 `|` 开头也含 "warning:"），
# 所以 `grep -c 'warning:'` 的口径一下**每新增一个测试文件就 +2**。
# 2026-09-24 新增 SkinPatchSupportTests.swift（第 16 个测试文件）后，口径一 36 / 口径二 24。
# 2026-09-24 新增 GameScanGenerationTests.swift（测试文件 17 → 18 个）后，口径一 38 / 口径二 24（同为 +2，非回归）。
# 2026-09-24 新增 GameLogRetentionTests.swift（测试文件 18 → 19 个）后，口径一 40 / 口径二 24（同为 +2，非回归）。
# 判定仍以「逐条 diff 告警集合」为准；若口径一多了 2 的整数倍，先确认是不是测试文件数变了，
# 再去查真实回归。
#
# ⚠️ 关键：本脚本额外开启 MemberImportVisibility。
# 工程（Xcode 26 默认）启用了 SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY，
# 而**裸 swiftc -typecheck 默认不开该特性**，于是会漏掉「成员来自未 import 的模块」这类错误
# （真实案例：拆分时丢了 `import SwiftyJSON`，快速检查报 0 错误，真实编译报 5 个错误）。
# 加上 -enable-upcoming-feature MemberImportVisibility 后，本脚本与真实编译对该类错误口径一致。
#
# 用法：
#   ./scripts/typecheck.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DEV=$(xcode-select -p)
FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"
LIB="$DEV/Platforms/MacOSX.platform/Developer/usr/lib"
COMMON=(-typecheck -target arm64-apple-macosx13.0 -I /tmp/deps -F "$FW" -I "$LIB"
        -enable-upcoming-feature MemberImportVisibility)

SOURCES=$(find qwq -name "*.swift")

echo "=== 口径一（默认隔离，含 qwqTests）==="
OUT1=$(xcrun swiftc "${COMMON[@]}" -module-name qwq $SOURCES qwqTests/*.swift 2>&1)
echo "  错误: $(printf '%s\n' "$OUT1" | grep -c 'error:')   告警: $(printf '%s\n' "$OUT1" | grep -c 'warning:')"
printf '%s\n' "$OUT1" | grep 'error:' | head -20

echo "=== 口径二（default-isolation MainActor）==="
OUT2=$(xcrun swiftc "${COMMON[@]}" -module-name qwq -default-isolation MainActor $SOURCES 2>&1)
echo "  错误: $(printf '%s\n' "$OUT2" | grep -c 'error:')   告警: $(printf '%s\n' "$OUT2" | grep -c 'warning:')"
printf '%s\n' "$OUT2" | grep 'error:' | head -20

E1=$(printf '%s\n' "$OUT1" | grep -c 'error:')
E2=$(printf '%s\n' "$OUT2" | grep -c 'error:')
echo
if [ "$E1" -eq 0 ] && [ "$E2" -eq 0 ]; then
  echo "结果: 两口径 0 错误（仍须以真实编译为准）"
else
  echo "结果: 存在类型错误，禁止提交"
  exit 1
fi
