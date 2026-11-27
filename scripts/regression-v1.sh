#!/bin/bash
# CcClean V1.0 真机回归脚本（基线 13.3 R1/R4/R5/R9/R10 自动化部分）
# 真机判定项（向日葵复现/检出率等）按基线 13.3 人工清单执行，
# 本脚本覆盖可在 CI/开发机自动验证的回归项。
set -uo pipefail

FAILED=0
PASS() { echo "✅ $1"; }
FAIL() { echo "❌ $1"; FAILED=1; }

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "=== R9 撤销回归：trash → undo 恢复原路径 ==="
swift test --package-path Packages/CcCleanOps --filter "trashCommitAndUndo|undoWithOccupiedPath" >/dev/null 2>&1 \
    && PASS "R9 trash 撤销（含占用场景）" || FAIL "R9 trash 撤销"

echo "=== R5 GB 级体积回归：索引/SizeCache du 等价性 ==="
swift test --package-path Packages/CcCleanFS --filter "allocatedSize|POC-T10" >/dev/null 2>&1 \
    && PASS "R5 体积统计（du 等价 + 大卷稳定性）" || FAIL "R5 体积统计"

echo "=== R10 残留检出回归：C1 扫描器正反例 ==="
swift test --package-path Packages/CcCleanFS --filter "fullScan|conflictExclusion|protectedSkipped" >/dev/null 2>&1 \
    && PASS "R10 残留检出（模板/双向/保护名单）" || FAIL "R10 残留检出"

echo "=== R4 腾讯套件零误伤：C12 词边界 ==="
swift test --package-path Packages/CcCleanFS --filter "wordBoundary|wholeWord|belongsToOther|conflictExclusion" >/dev/null 2>&1 \
    && PASS "R4 套件零误伤（词边界 + C12 剔除）" || FAIL "R4 套件零误伤"

echo "=== R1 前置：保护名单硬拦截 ==="
swift test --package-path Packages/CcCleanFS --filter "protectedSkipped|forbiddenRoots" >/dev/null 2>&1 \
    && PASS "R1 保护名单（硬拦截路径 + com.apple.*）" || FAIL "R1 保护名单"

echo "=== V1.0 全量测试（基线 RG-2：回归 100%）==="
for p in CcCleanCore CcCleanFS CcCleanOps; do
    swift test --package-path "Packages/$p" >/dev/null 2>&1 \
        && PASS "$p 全量" || FAIL "$p 全量"
done

echo "=== RG-3：规则文件三校验 ==="
swift test --package-path Packages/CcCleanFS --filter "bundledRulesValid|perRuleFixtures" >/dev/null 2>&1 \
    && PASS "RG-3 规则校验（8 条 + 24 条正反例）" || FAIL "RG-3 规则校验"

echo "=== RG 静态红线 ==="
./scripts/check-redlines.sh >/dev/null 2>&1 && PASS "RG 红线（sudo/Process/写盘通道）" || FAIL "RG 红线"

echo "=== 人工清单（基线 13.3，不可自动化）==="
cat <<'EOF'
□ R1 向日葵完整复现（本体 + 4 Daemon + HAL 驱动 + 2 receipt + 6 用户级残留）
□ R1 误删判定：任何「其他应用路径」命中即回归失败
□ R10 5 款应用检出率 ≥ 90%
□ 公证流水线：release.sh 全程跑通 + 干净机器安装
□ Helper 未注册灰显 + 引导可见（POC-T1/T2 收口在 S9）
EOF

if [ "$FAILED" -eq 0 ]; then
    echo "✅ V1.0 自动化回归全部通过（人工清单见上）"
else
    echo "❌ 存在回归失败，禁止发布"
fi
exit $FAILED