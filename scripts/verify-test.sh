#!/bin/bash
# 在受限沙箱环境中执行 qwqTests 单元测试的编译（build-for-testing）与运行（test-without-building）。
#
# 背景与 scripts/verify-build.sh 相同：调用方进程若已处于 macOS 沙箱内，xcodebuild 会因为
# 「沙箱不支持嵌套」而失败（sandbox-exec: sandbox_apply: Operation not permitted），
# 需关闭 xcodebuild 内部那层包依赖沙箱。
#
# 用法：
#   ./scripts/verify-test.sh              # 只编译测试（不启动 App，不弹窗）
#   ./scripts/verify-test.sh run          # 编译 + 运行测试（会启动 qwq.app 作为宿主）
#   ./scripts/verify-test.sh clean        # 先清理再用例编译

set -o pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

# 多个任务并行时，各自用 SL_DERIVED 指定独立派生目录，避免抢同一份派生数据
DERIVED=${SL_DERIVED:-/tmp/SL-DD-tt}
LOG=${SL_LOG:-/tmp/sl_test.log}
RESULT=${SL_RESULT:-/tmp/sl_test.xcresult}

export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

XCB=(/usr/bin/xcodebuild
  -project qwq.xcodeproj
  -scheme qwq
  -configuration Debug
  -derivedDataPath "$DERIVED"
  -IDEPackageSupportDisableManifestSandbox=1
  -IDEPackageSupportDisablePackageSandbox=1
  "OTHER_SWIFT_FLAGS=\$(inherited) -disable-sandbox")

echo "项目目录: $PROJECT_DIR"
echo "分支: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
echo "完整日志: $LOG"
echo ""

if [ "$1" = "clean" ]; then
  echo "--- 清理 ---"
  rm -rf "$DERIVED"
  shift
fi

echo "--- 编译测试 bundle ---"
"${XCB[@]}" build-for-testing > "$LOG" 2>&1
BUILD_EXIT=$?

grep -E "BUILD SUCCEEDED|BUILD FAILED|TEST BUILD SUCCEEDED" "$LOG" | head -2
ERR_COUNT=$(grep -c "error:" "$LOG")
echo "编译错误数: $ERR_COUNT"
if [ "$ERR_COUNT" -gt 0 ]; then
  echo "错误明细（最多 20 条）:"
  grep "error:" "$LOG" | head -20
fi

if [ "$BUILD_EXIT" -ne 0 ]; then
  echo "结果: 测试编译失败（退出码 $BUILD_EXIT）"
  exit "$BUILD_EXIT"
fi

if [ "$1" != "run" ]; then
  echo "结果: 测试编译成功（未运行）"
  exit 0
fi

echo ""
echo "--- 运行测试（会启动 qwq.app 作为宿主）---"
rm -rf "$RESULT"
"${XCB[@]}" test-without-building -resultBundlePath "$RESULT" >> "$LOG" 2>&1
TEST_EXIT=$?

grep -E "Test Suite .* (passed|failed)|Executed [0-9]+ test|Testing failed|\*\* TEST" "$LOG" | tail -20

echo ""
if [ "$TEST_EXIT" -eq 0 ]; then
  echo "结果: 测试全部通过"
else
  echo "结果: 存在失败用例（退出码 $TEST_EXIT）"
  echo "失败用例（最多 20 条）:"
  grep -E "error:.*XCTAssert|failed -|Test Case .* failed" "$LOG" | head -20
fi

exit "$TEST_EXIT"
