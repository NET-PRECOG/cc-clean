#!/bin/bash
# 依赖红线与安全静态检查（基线 5.2 依赖红线 + 13.6 静态检查）。
# 违规即非零退出，供 CI 与本地 pre-commit 使用。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0
# 只扫描自有源码；排除构建产物、git 与第三方 checkout
SCAN_ARGS=(-rln --include='*.swift' --exclude-dir=.build --exclude-dir=.git --exclude-dir=checkouts)
SCAN_PATHS="$ROOT/Packages $ROOT/Targets"

# Helper 侧白名单：HelperPathValidator/HelperDTO 的拦截逻辑与错误文案
# 属合法防御代码（基线 10.3/10.4），不构成"构造参数/绕过"
HELPER_ALLOW='| grep -v HelperPathValidator.swift | grep -v HelperDTO.swift'
# 写盘通道白名单：OperationJournal/TrashService（唯一写盘出口，基线 6.3）
# 与 DatabaseStore（损坏自愈隔离，基线 8.5，R14）
WRITE_ALLOW='| grep -v OperationJournal.swift | grep -v TrashService.swift | grep -v DatabaseStore.swift'

fail() {
    echo "REDLINE VIOLATION: $1"
    FAILED=1
}

# --- 1. 包依赖方向（Package.swift 声明层面） ---
grep -q '"CcCleanFS"\|"CcCleanOps"\|"CcCleanMetrics"\|"CcCleanPrivileged"' \
    "$ROOT/Packages/CcCleanCore/Package.swift" \
    && fail "CcCleanCore 不得依赖任何上层包"

grep -q '"CcCleanOps"\|"CcCleanMetrics"\|"CcCleanPrivileged"' \
    "$ROOT/Packages/CcCleanFS/Package.swift" \
    && fail "CcCleanFS 只允许依赖 Core"

grep -q '"CcCleanMetrics"\|"CcCleanPrivileged"' \
    "$ROOT/Packages/CcCleanOps/Package.swift" \
    && fail "CcCleanOps 只允许依赖 Core/FS"

grep -q '"CcCleanFS"\|"CcCleanOps"\|"CcCleanPrivileged"' \
    "$ROOT/Packages/CcCleanMetrics/Package.swift" \
    && fail "CcCleanMetrics 不得依赖 FS/Ops/Privileged（监控需独立工作）"

grep -q '"CcCleanFS"\|"CcCleanOps"\|"CcCleanMetrics"' \
    "$ROOT/Packages/CcCleanPrivileged/Package.swift" \
    && fail "CcCleanPrivileged 只允许依赖 Core"

# --- 2. Core 不 import SwiftUI / 上层模块 ---
if grep -rn 'import SwiftUI\|import CcCleanFS\|import CcCleanOps\|import CcCleanMetrics\|import CcCleanPrivileged' \
    "$ROOT/Packages/CcCleanCore/Sources" >/dev/null 2>&1; then
    fail "CcCleanCore 禁止 import SwiftUI 或上层模块"
fi

# --- 3. Process( 只允许出现在 ProcessRunner.swift（唯一命令出口） ---
PROCESS_HITS=$(grep "${SCAN_ARGS[@]}" '\bProcess(' "$ROOT/Packages" "$ROOT/Targets" 2>/dev/null \
    | grep -v 'ProcessRunner.swift' || true)
if [ -n "$PROCESS_HITS" ]; then
    for f in $PROCESS_HITS; do
        fail "直接使用 Process()（唯一出口为 CcCleanCore/ProcessRunner.swift）: $f"
    done
fi

# --- 4. 禁 sudo / 授权执行 / tccutil reset All ---
# Helper 侧白名单：HelperPathValidator/HelperDTO 的拦截逻辑与错误文案属合法防御代码
grep "${SCAN_ARGS[@]}" 'AuthorizationExecuteWithPrivileges' "$ROOT/Packages" "$ROOT/Targets" 2>/dev/null \
    | grep -v HelperPathValidator.swift | grep -v HelperDTO.swift >/dev/null 2>&1 \
    && fail "禁止 AuthorizationExecuteWithPrivileges（特权只允许 Helper XPC）"

grep "${SCAN_ARGS[@]}" '"reset All"\|reset All"' "$ROOT/Packages" "$ROOT/Targets" 2>/dev/null \
    | grep -v HelperPathValidator.swift | grep -v HelperDTO.swift >/dev/null 2>&1 \
    && fail "禁止构造 tccutil reset All 参数"

SUDO_HITS=$(grep "${SCAN_ARGS[@]}" '\bsudo\b' "$ROOT/Packages"/*/Sources "$ROOT/Targets" 2>/dev/null || true)
if [ -n "$SUDO_HITS" ]; then
    for f in $SUDO_HITS; do
        fail "禁止 sudo: $f"
    done
fi

# --- 5. L2/L3 直接写盘禁令（removeItem/trashItem/moveItem 只允许 OperationJournal/TrashService 内部） ---
# 白名单例外：DatabaseStore.swift 的 moveItem 仅用于损坏数据库隔离自愈（基线 8.5，R14）；
# HelperExecutor.swift 的 removeItem 是 Helper root 删除的功能本体（基线 10.3，不可撤销 removeSystem 语义），
# Helper 侧已有六道关校验（HelperPathValidator）前置拦截
WRITE_HITS=$(grep "${SCAN_ARGS[@]}" 'FileManager.*\.removeItem\|trashItem(at:\|\.moveItem(at:' \
    "$ROOT/Packages"/*/Sources 2>/dev/null \
    | grep -v 'OperationJournal.swift' | grep -v 'TrashService.swift' \
    | grep -v 'DatabaseStore.swift' | grep -v 'HelperExecutor.swift' || true)
if [ -n "$WRITE_HITS" ]; then
    for f in $WRITE_HITS; do
        fail "写盘操作必须经 OperationJournal/TrashService: $f"
    done
fi

if [ "$FAILED" -eq 0 ]; then
    echo "redline check: OK"
fi
exit $FAILED