#!/bin/bash
# 在受限沙箱环境中执行真实的 Xcode 工程编译
#
# 背景：若调用方进程本身已处于 macOS 沙箱内，直接运行 xcodebuild 会失败：
#   sandbox-exec: sandbox_apply: Operation not permitted
# 原因是 macOS 沙箱不支持嵌套——xcodebuild 解析 Swift Package 依赖时，
# 会用 sandbox-exec 包一层去编译依赖清单，而它自己已在沙箱内，于是被拒
# （系统日志表现为 deny(1) forbidden-sandbox-reinit）。
#
# 规避方式（参数组合参考开源项目 sandvault）：关闭 xcodebuild 内部的那层沙箱。
# Swift 自带 --disable-sandbox，xcodebuild 没有对应开关，只能靠下列参数与环境变量。
#
# 用法：
#   ./scripts/verify-build.sh            # 普通编译
#   ./scripts/verify-build.sh clean      # 先清理再编译

set -o pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

# 多个任务并行时，各自用 SL_DERIVED 指定独立派生目录，避免抢同一份派生数据
# （同一个 derivedDataPath 上并发跑 xcodebuild 会互相破坏中间产物）
DERIVED=${SL_DERIVED:-/tmp/SL-DD}
LOG=${SL_LOG:-/tmp/sl_build.log}

export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

echo "项目目录: $PROJECT_DIR"
echo "分支: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
echo "完整日志: $LOG"
echo ""

if [ "$1" = "clean" ]; then
  echo "--- 清理 ---"
  /usr/bin/xcodebuild -project qwq.xcodeproj -scheme qwq clean > /dev/null 2>&1
fi

echo "--- 编译中 ---"
/usr/bin/xcodebuild \
  -project qwq.xcodeproj \
  -scheme qwq \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  -IDEPackageSupportDisableManifestSandbox=1 \
  -IDEPackageSupportDisablePackageSandbox=1 \
  "OTHER_SWIFT_FLAGS=\$(inherited) -disable-sandbox" \
  build > "$LOG" 2>&1
BUILD_EXIT=$?

echo ""
if [ "$BUILD_EXIT" -eq 0 ]; then
  echo "结果: 编译成功"
else
  echo "结果: 编译失败（退出码 $BUILD_EXIT）"
fi

grep -E "BUILD SUCCEEDED|BUILD FAILED" "$LOG" | head -2

ERR_COUNT=$(grep -c "error:" "$LOG")
echo "错误数: $ERR_COUNT"
if [ "$ERR_COUNT" -gt 0 ]; then
  echo ""
  echo "错误明细（最多 30 条）:"
  grep "error:" "$LOG" | head -30
fi

exit $BUILD_EXIT
