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
# 告警数超出基线即为本次改动引入，需逐条核对。
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
