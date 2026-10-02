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
# 2026-09-25 新增 LaunchCancellationTests.swift（测试文件 19 → 20 个）后，口径一 42 / 口径二 24（同为 +2，非回归）。
# 2026-09-25 新增 DownloadSliceBudgetTests.swift（测试文件 20 → 21 个）后，口径一 44 / 口径二 24（同为 +2，非回归）。
# 2026-09-25 新增 MemoryPressureTests.swift（测试文件 21 → 22 个）后，口径一 46 / 口径二 24（同为 +2，非回归）。
# 2026-09-25 新增 AccountPersistenceCompatTests.swift（测试文件 22 → 23 个）后，口径一 48 / 口径二 24。
#
# ⚠️ 本脚本的「告警数」是**行数**，不是告警条数 —— 每条告警会打印 2 行匹配 `warning:`：
# 主行（`文件:行:列: warning: …`）与其插入符行（以 `|` 开头也含 `warning:`）。
# 所以上面那些数字 ≈ **唯一告警数 × 2**。2026-09-25 实测的构成：
#   口径一 48 行 = 24 条唯一告警 × 2（其中 23 条是本脚本把 qwqTests 编进同一模块产生的
#                 `ignoring import` 产物，只有 1 条是真实告警：NoticeCenterTests 的 Sendable 捕获）
#   口径二 24 行 = 12 条唯一告警 × 2（口径二不编 qwqTests，故全部是真实告警）
# 判定一律用「告警集合逐条 diff」，**不要只看行数**（新增测试文件会让口径一每文件 +2 行）。
# 导出唯一告警集合（去掉插入符行）：
#   grep 'warning:' <日志> | grep -E '^[^ ]' | sort > set.txt
# 再与基线 `comm -3` 比对；结果应是「0 新增 / 0 消除」，唯一允许的差异是同文件内的行号平移。
# 判定仍以「逐条 diff 告警集合」为准；若口径一多了 2 的整数倍，先确认是不是测试文件数变了，
# 再去查真实回归。
#
# ⚠️ 本脚本依赖 `-I /tmp/deps` 里的第三方 .swiftmodule。`/tmp` 被清理后（例如收尾 `rm -rf /tmp/SL-*`）
# 会报 `no such module 'SwiftyJSON'` —— 那不是代码问题，而是依赖没了。回填方法：
#   ./scripts/verify-build.sh                                    # 先编一次，产出 /tmp/SL-DD/Build/Products/Debug
#   mkdir -p /tmp/deps
#   cp -R /tmp/SL-DD/Build/Products/Debug/{SwiftyJSON,ZIPFoundation}.swiftmodule /tmp/deps/
# 判别口诀：错误里出现 `no such module` 且**告警数为 0**（编译在解析 import 时就中止了）→ 先查 /tmp/deps，
# 不要去改代码。
#
# ⚠️ 关键：本脚本额外开启 MemberImportVisibility。
# 工程（Xcode 26 默认）启用了 SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY，
# 而**裸 swiftc -typecheck 默认不开该特性**，于是会漏掉「成员来自未 import 的模块」这类错误
# （真实案例：拆分时丢了 `import SwiftyJSON`，快速检查报 0 错误，真实编译报 5 个错误）。
#
# ⚠️ 2026-09-25 起本脚本带 `-D DEBUG`。
# 理由：工程真实构建是 Debug（verify-build.sh 用 `-configuration Debug`，测试也是 Debug），
# 而裸 swiftc **默认不定义 DEBUG** —— 于是 `#if DEBUG` 里的代码（如 App/DebugAutoLaunch.swift）
# 从来没被这一层检查过，且任何 `#if DEBUG` 新增 API 都会在本脚本里「不存在」（实测：
# 加了 `MemoryCacheReclaimer.resetForTesting()` 后，脚本报 4 处 `has no member`、真实编译 0 错误）。
# 加标志后两个口径的实测：口径一 0 错误 / 46 告警，口径二 0 错误 / 24 告警
# —— 口径二与加标志前**逐条一致**（它只编 qwq，DEBUG 只放行 DebugAutoLaunch.swift，无新增告警）。
#
# ⚠️ 另一条实测（2026-09-25）：**编译一旦报错，后续文件的告警会被吞掉**。
# 同一份源码，有 4 处错误时口径一报 32 告警；把这 4 处修掉后报 46 告警。
# 所以「告警数变少」未必是变好，可能是提前报错短路了；跨轮次更不能只比数字，
# 一律用上面的「告警集合逐条 diff」。
# 加上 -enable-upcoming-feature MemberImportVisibility 后，本脚本与真实编译对该类错误口径一致。
#
# 用法：
#   ./scripts/typecheck.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DEV=$(xcode-select -p)
FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"
LIB="$DEV/Platforms/MacOSX.platform/Developer/usr/lib"
COMMON=(-typecheck -target arm64-apple-macosx13.0 -I /tmp/deps -F "$FW" -I "$LIB"
        -enable-upcoming-feature MemberImportVisibility -D DEBUG)

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

# ─────────────────────────────────────────────────────────────
# 防回潮红线（2026-10-02 添加，依据审计闭环轮）：
#   已修掉的问题必须被"钉死"，防止下一个功能开发时被重新引入——
#   任何人（或未来的我们）顺手写回 `category.name == "启动"`
#   / 裸 `Task.sleep` / `contains("中文文案")`，这里立刻亮红。
# 每条红线当前都必须是零命中；命中即 exit 1 禁止提交。
# ─────────────────────────────────────────────────────────────

fail=0
redline() { # redline <名称> <描述>; 输出命中则 fail
  echo "红线「$1」命中（$2）："
  echo "$3"
  fail=1
}

# 红线 1：分类分派字符串回潮。已结构化到 `CategoryKind`（Category.swift），
# 生产代码一旦再出现 `category.name == "中文"` 即违规。
# 只查**活代码**：注释里引用旧模式作历史说明不算（`///`/`//` 行排除）。
HIT1=$(grep -rn 'category\.name == "[^"]*"' qwq --include='*.swift' | grep -vE ':[0-9]+:[[:space:]]*(//|/\*)' || true)
if [ -n "$HIT1" ]; then
  redline "category.name == 字符串分派" "改用 CategoryKind 枚举" "$HIT1"
fi

# 红线 2：裸 `Task.sleep` 回潮（生产代码任意位置、不带论证注释）。
# 规则：`qwq/` 下每个 `Task.sleep(` 的**上方 ≤5 行内**必须有论证注释
# （原因/时长依据）。实现：Python 逐文件扫描，命中「同一行无注释且上方
# 5 行内无注释」的裸睡即失败。窗口取值 5 行的依据：
#   - 太小（≤3）会把「紧贴的多行论证注释块」误伤（如 VersionButton 的 7 行
#     论证块紧贴 sleep，注释第 1 行距 sleep 达 7 行）；
#   - 太大（>5）会出现「远处无关注释护身」盲区（探针实测 8 行窗口下
#     与 sleep 无关的头部注释也能豁免）。
# 5 行是「误伤与盲区的务实平衡」；新代码请把论证注释放在 sleep 紧邻上方。
HIT2=$(python3 - "$PWD" <<'PYEOF'
import pathlib, sys
root = sys.argv[1]
bad = []
for f in sorted(pathlib.Path(root, 'qwq').rglob('*.swift')):
    lines = f.read_text(encoding='utf-8').splitlines()
    for i, ln in enumerate(lines):
        if 'Task.sleep(' in ln and '//' not in ln:
            # 上方 ≤5 行的注释才视为对该 sleep 的论证
            has_above = any(
                lines[j].strip().startswith(('//', '///', '/*', '*'))
                for j in range(max(0, i - 5), i)
            )
            if not has_above:
                bad.append(f"{f}:{i+1}: {ln.strip()[:90]}")
print('\n'.join(bad))
PYEOF
)
if [ -n "$HIT2" ]; then
  redline "裸 Task.sleep 无论证" "上方 ≤5 行需有论证注释（原因 + 时长依据）" "$HIT2"
fi

# 红线 3：错误分类靠 `contains("中文文案")` 回潮。已结构化到
# `NetDownloadError` / `LaunchError` 精确 case（桥接层抛点直接抛 case，适配层
# switch / 透传直达）。生产代码再出现 `contains("中文")` 即违规；
# 只查活代码（注释引用历史模式不算）。
HIT3=$(grep -rn 'contains("[^"]*[^ -~][^"]*")' qwq --include='*.swift' | grep -vE ':[0-9]+:[[:space:]]*(//|/\*)' || true)
if [ -n "$HIT3" ]; then
  redline "contains(\"中文\") 错误分类" "改用 NetDownloadError 结构化 case" "$HIT3"
fi

# 告警上限：防"告警数静默回涨"。基线（2026-10-02）：
#   口径一 57 条唯一 = 56 条 ignoring-import 产物（= 测试文件数，每文件 +1）
#                    + 1 条真实告警（NoticeCenterTests:108 Sendable 捕获）
#   口径二 12 条唯一 = 12 条真实告警（配置文件见脚本头注释的逐文件列举）
# 上限口径：
#   - 口径一：57 + max(0, 测试文件数 - 56)（新增测试文件允许 +1，其余 +1 即失败）
#   - 口径二：12（全真实告警，任何新增即失败）
UNIQ2=$(printf '%s\n' "$OUT2" | grep 'warning:' | grep -E '^[^ |]' | sort -u | wc -l | tr -d ' ')
TESTFILES=$(ls qwqTests/*.swift | wc -l | tr -d ' ')
UNIQ1=$(printf '%s\n' "$OUT1" | grep 'warning:' | grep -E '^[^ |]' | sort -u | wc -l | tr -d ' ')
CAP1=$((57 + (TESTFILES - 56)))
CAP2=12
if [ "$UNIQ1" -gt "$CAP1" ]; then
  redline "口径一告警超上限（$UNIQ1 > $CAP1）" "基线 57 + 新增测试文件数；多出即真实告警回潮" "见上方口径一告警清单，逐一核对新增原因"
fi
if [ "$UNIQ2" -gt "$CAP2" ]; then
  redline "口径二告警超上限（$UNIQ2 > $CAP2）" "基线 12 条真实告警，新增即失败" "见上方口径二告警清单，逐一核对新增原因"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "结果: 三条防回潮红线 + 告警上限全部通过（测试文件数 $TESTFILES，口径一 $UNIQ1/$CAP1，口径二 $UNIQ2/$CAP2）"
else
  echo "结果: 防回潮红线失败，禁止提交"
  exit 1
fi
