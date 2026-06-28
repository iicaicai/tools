#!/usr/bin/env bash
# ============================================================
# remove-exporter.sh - 移除 exporter 容器并删除对应的监控目标
#
# 用法:
#   ./scripts/remove-exporter.sh <type> <name>
#
# 示例:
#   ./scripts/remove-exporter.sh postgresql my-pg
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ $# -lt 2 ]; then
    echo "用法: $0 <type> <name>"
    echo "  type: postgresql / mysql / redis / node / influxdb"
    exit 1
fi

TYPE="$1"
NAME="$2"

case "${TYPE}" in
    postgresql)   CONTAINER="pg_exporter_${NAME}"    JOB="postgresql" ;;
    mysql)          CONTAINER="mysql_exporter_${NAME}"     JOB="mysql" ;;
    redis)          CONTAINER="redis_exporter_${NAME}"       JOB="redis" ;;
    node)           CONTAINER="node_exporter_${NAME}"         JOB="node-exporter" ;;
    influxdb)       CONTAINER=""                             JOB="influxdb" ;;
    *) echo "[错误] 未知 type: ${TYPE}"; exit 1 ;;
esac

# 删除 Prometheus 目标
"${SCRIPT_DIR}/remove-target.sh" "${JOB}" "${NAME}"

# 删除容器
if [ -n "${CONTAINER}" ]; then
    echo "[INFO] 删除容器: ${CONTAINER}"
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        docker stop "${CONTAINER}" >/dev/null
        docker rm -f "${CONTAINER}" >/dev/null
        echo "[成功] 容器已删除"
    else
        echo "[提示] 未找到容器 ${CONTAINER}"
    fi
fi

echo "[完成]"
