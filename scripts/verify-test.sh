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
# ⚠️ 不要用裸 `grep -c "error:"` 统计错误数：swiftc / xcodebuild 打印诊断时会附上**被引用处的源码原文**，
# 若那行本身含 `error:` 字样（本工程有 `var error: Error?`），它就会被算成一条「错误」。
# 真诊断的形态是 `path/file.swift:行:列: error: 消息` ⇒ 用带位置信息的精确模式。
# （同类坑在 `scripts/typecheck.sh` 头部已记录过一次，此处补齐。）
ERR_COUNT=$(grep -cE '\.swift:[0-9]+:[0-9]+: error:' "$LOG")
ERR_COUNT_LOOSE=$(grep -c "error:" "$LOG")
echo "编译错误数: $ERR_COUNT（裸 grep 'error:' 上界 $ERR_COUNT_LOOSE，含源码上下文行，不作判据）"
if [ "$ERR_COUNT" -gt 0 ]; then
  echo "错误明细（最多 20 条）:"
  grep -E '\.swift:[0-9]+:[0-9]+: error:' "$LOG" | head -20
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
echo "注意：用例必须一律写成 async（见 qwqTests/TESTING.md §五）。同步用例里创建并释放"
echo "      @MainActor 类实例会让宿主 abort（malloc: pointer being freed was not allocated），"
echo "      表现为「前几个测试类通过、之后无限重启」。工具链缺陷，与本工程逻辑无关。"
rm -rf "$RESULT"
# 显式指定 destination：本机 arm64 / x86_64 两个 destination 同名同 id，
# 不指定时 xcodebuild 会打印「Using the first of multiple matching destinations」后取第一个，
# 属于隐式选择；锁定 arch 后行为确定，也免得将来 Rosetta 环境被误选。
"${XCB[@]}" test-without-building \
  -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath "$RESULT" >> "$LOG" 2>&1
TEST_EXIT=$?

grep -E "Test Suite .* (passed|failed)|Executed [0-9]+ test|Testing failed|\*\* TEST" "$LOG" | tail -20

echo ""
# ⚠️ 必须把「断言失败」与「已知工具链 abort」分开报，否则 `** TEST EXECUTE FAILED **` 会被误读成
#    「用例没通过」。本工程有一条已登记的 Xcode 26.2 工具链缺陷（见 qwqTests/TESTING.md §五）：
#    套件约 1/4 概率在某用例处 abort（`pointer being freed was not allocated`），
#    进程重启后**所有断言仍然通过**，但 xcodebuild 仍报 `TEST EXECUTE FAILED`。
ASSERT_FAILS=$(grep -cE 'error: -\[qwqTests\.' "$LOG")
ABORTS=$(grep -c "Restarting after unexpected exit" "$LOG")
EXECUTED=$(grep -oE "Executed [0-9]+ tests, with [0-9]+ tests? skipped and [0-9]+ failures" "$LOG" | tail -1)

echo "断言失败 : $ASSERT_FAILS 条"
if [ "$ABORTS" -gt 0 ]; then
  echo "⚠️ 已知工具链 abort: $ABORTS 次（TESTING.md §五，非本次改动所致；断言仍可能全绿）"
fi
if [ -n "$EXECUTED" ]; then
  echo "末次汇总 : $EXECUTED"
fi
echo "（口径提醒：abort 会重启进程，故 `Executed N tests` 只是**最后一次 launch** 的汇总，"
echo "  不是全部用例数；要总数须逐 suite 求和。）"

if [ "$ASSERT_FAILS" -gt 0 ]; then
  echo ""
  echo "结果: 存在**断言失败**（这是代码问题）"
  echo "失败用例（最多 20 条）:"
  grep -E 'error: -\[qwqTests\.' "$LOG" | head -20
  exit 1
fi

if [ "$TEST_EXIT" -eq 0 ]; then
  echo ""
  echo "结果: 测试全部通过"
  exit 0
fi

echo ""
echo "结果: xcodebuild 报失败（退出码 $TEST_EXIT），但**没有任何断言失败** ——"
echo "      成因是上方的已知 abort 或环境问题（logarchive 收集失败等），不是用例没通过。"
echo "      处置：换全新 SL_DERIVED 重试（abort 后派生目录会退化）；退出码仍按 xcodebuild 返回，"
echo "      便于 CI 与调用方自行决定是否把这一项当门禁。"
exit "$TEST_EXIT"
