#!/usr/bin/env bash
# ============================================================
# stop-all.sh - 停止所有监控服务
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

echo "[INFO] 停止所有监控服务 (保留数据卷)..."
if docker compose version >/dev/null 2>&1; then
    docker compose down
else
    docker-compose down
fi

echo "[完成] 所有服务已停止。数据卷未删除。"
echo "       要彻底删除数据，使用: docker compose down -v"
