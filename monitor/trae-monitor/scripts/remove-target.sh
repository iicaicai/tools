#!/usr/bin/env bash
# ============================================================
# remove-target.sh - 从 Prometheus 动态移除监控目标
#
# 用法:
#   ./scripts/remove-target.sh <job> <name>
#   ./scripts/remove-target.sh postgresql my-pg
#
# 也可以通过文件名直接删除 (支持模糊匹配):
#   ./scripts/remove-target.sh postgresql-*
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGETS_DIR="${PROJECT_ROOT}/prometheus/targets.d"

if [ $# -lt 2 ]; then
    echo "用法: $0 <job> <name>"
    echo ""
    echo "示例:"
    echo "  $0 node-exporter web-01"
    echo "  $0 postgresql my-pg"
    echo ""
    echo "当前已有的目标文件:"
    ls -la "${TARGETS_DIR}"/*.yml 2>/dev/null || echo "  (无)"
    exit 1
fi

JOB="$1"
NAME="$2"

TARGET_FILE="${TARGETS_DIR}/${JOB}-${NAME}.yml"

if [ ! -f "${TARGET_FILE}" ]; then
    echo "[错误] 未找到目标文件: ${TARGET_FILE}"
    echo ""
    echo "当前已有的目标文件:"
    ls -la "${TARGETS_DIR}"/*.yml 2>/dev/null || echo "  (无)"
    exit 1
fi

echo "以下文件将被删除:"
echo "  ${TARGET_FILE}"
echo ""
cat "${TARGET_FILE}"
echo ""
read -p "确认删除? (y/N): " -r CONFIRM
if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
    echo "已取消。"
    exit 0
fi

rm -f "${TARGET_FILE}"
echo "[成功] 已删除 ${TARGET_FILE}"

# --- 重载 Prometheus ---
echo "[INFO] 触发 Prometheus 配置重载..."
if command -v curl >/dev/null 2>&1; then
    curl -s -X POST http://localhost:9090/-/reload || true
    echo "[成功] 已触发重载"
else
    echo "[提示] 未找到 curl，Prometheus 会在 30 秒内自动发现变更"
fi

echo ""
echo "[提示] 可在 http://localhost:9090/targets 查看目标状态"
