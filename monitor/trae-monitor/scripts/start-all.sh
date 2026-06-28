#!/usr/bin/env bash
# ============================================================
# start-all.sh - 一键启动 Prometheus + Grafana + Alertmanager
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[INFO] 启动所有监控服务..."
cd "${PROJECT_ROOT}"

# 确保脚本可执行
chmod +x scripts/*.sh

# 使用 docker compose 启动
if docker compose version >/dev/null 2>&1; then
    docker compose up -d
elif docker-compose --version >/dev/null 2>&1; then
    docker-compose up -d
else
    echo "[错误] 未安装 docker compose，请先安装"
    exit 1
fi

echo ""
echo "[完成] 服务已启动。"
echo "  Grafana      : http://localhost:3000  (admin / admin123)"
echo "  Prometheus   : http://localhost:9090"
echo "  Alertmanager : http://localhost:9093"
echo ""
echo "查看状态: docker compose ps"
echo "查看日志: docker compose logs -f [服务名]"
