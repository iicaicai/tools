#!/usr/bin/env bash
# ============================================================
# deploy-exporter.sh - 一键部署 exporter 容器并注册到 Prometheus
#
# 用法:
#   ./scripts/deploy-exporter.sh <type> <name> <target-addr> [options]
#
# 支持的 type:
#   postgresql  : 部署 postgres_exporter
#   mysql       : 部署 mysqld_exporter
#   redis       : 部署 redis_exporter
#   node        : 部署 node_exporter (监控本机)
#   influxdb    : 直接注册 InfluxDB /metrics 端点 (无需额外 exporter)
#
# 示例:
#   # 监控 postgres 容器，主机: postgres, 端口: 5432, 用户: postgres, 密码: mypass
#   ./scripts/deploy-exporter.sh postgresql my-pg postgres:5432 \
#       --user postgres --password mypass --dbname postgres
#
#   # 监控 mysql 容器
#   ./scripts/deploy-exporter.sh mysql my-mysql mysql:3306 \
#       --user exporter --password secret
#
#   # 监控 redis 容器 (无密码)
#   ./scripts/deploy-exporter.sh redis my-redis redis:6379
#
#   # 监控本机 (作为 node-exporter 容器)
#   ./scripts/deploy-exporter.sh node local-host localhost:9100
#
#   # 直接注册 InfluxDB
#   ./scripts/deploy-exporter.sh influxdb my-influx influxdb:8086
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NETWORK="monitor-net"

# --- 参数解析 ---
if [ $# -lt 3 ]; then
    sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
fi

TYPE="$1"
NAME="$2"
TARGET_ADDR="$3"
shift 3

# 解析可选参数
DB_USER=""
DB_PASS=""
DB_NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --user)      DB_USER="$2";     shift 2 ;;
        --password)  DB_PASS="$2";     shift 2 ;;
        --dbname)    DB_NAME="$2";     shift 2 ;;
        *) echo "[警告] 忽略未知参数: $1"; shift ;;
    esac
done

# --- 检查 Docker ---
if ! command -v docker >/dev/null 2>&1; then
    echo "[错误] 未安装 docker，请先安装 docker 和 docker compose"
    exit 1
fi

# 确保网络存在
docker network inspect "${NETWORK}" >/dev/null 2>&1 || docker network create "${NETWORK}" >/dev/null

# --- 根据类型处理 ---
case "${TYPE}" in

    # ======== PostgreSQL ========
    postgresql)
        EXPORT_NAME="pg_exporter_${NAME}"
        DATA_SOURCE="postgresql://${DB_USER:-postgres_exporter}:${DB_PASS:-secret}@${TARGET_ADDR}/${DB_NAME:-postgres}?sslmode=disable"
        echo "[INFO] 部署 postgres_exporter: ${EXPORT_NAME}  监听 9187"
        docker rm -f "${EXPORT_NAME}" 2>/dev/null || true
        docker run -d --name "${EXPORT_NAME}" \
            --network "${NETWORK}" \
            -e DATA_SOURCE_NAME="${DATA_SOURCE}" \
            -p "9187:9187" \
            --restart unless-stopped \
            quay.io/prometheuscommunity/postgres-exporter:v0.15.0 >/dev/null
        echo "[INFO] 等待 exporter 就绪..."
        sleep 3
        "${SCRIPT_DIR}/add-target.sh" "${NAME}" postgresql "${EXPORT_NAME}:9187"
        ;;

    # ======== MySQL / MariaDB ========
    mysql)
        EXPORT_NAME="mysql_exporter_${NAME}"
        DATA_SOURCE="${DB_USER:-exporter}:${DB_PASS:-secret}@(${TARGET_ADDR})/"
        echo "[INFO] 部署 mysqld_exporter: ${EXPORT_NAME}  监听 9104"
        docker rm -f "${EXPORT_NAME}" 2>/dev/null || true
        docker run -d --name "${EXPORT_NAME}" \
            --network "${NETWORK}" \
            -e DATA_SOURCE_NAME="${DATA_SOURCE}" \
            -p "9104:9104" \
            --restart unless-stopped \
            prom/mysqld-exporter:v0.15.1 >/dev/null
        echo "[INFO] 等待 exporter 就绪..."
        sleep 3
        "${SCRIPT_DIR}/add-target.sh" "${NAME}" mysql "${EXPORT_NAME}:9104"
        ;;

    # ======== Redis ========
    redis)
        EXPORT_NAME="redis_exporter_${NAME}"
        echo "[INFO] 部署 redis_exporter: ${EXPORT_NAME}  监听 9121"
        docker rm -f "${EXPORT_NAME}" 2>/dev/null || true
        docker run -d --name "${EXPORT_NAME}" \
            --network "${NETWORK}" \
            -e REDIS_ADDR="${TARGET_ADDR}" \
            ${DB_PASS:+-e REDIS_PASSWORD="${DB_PASS}"} \
            -p "9121:9121" \
            --restart unless-stopped \
            oliver006/redis_exporter:v1.58.0 >/dev/null
        echo "[INFO] 等待 exporter 就绪..."
        sleep 3
        "${SCRIPT_DIR}/add-target.sh" "${NAME}" redis "${EXPORT_NAME}:9121"
        ;;

    # ======== Node Exporter (本机) ========
    node)
        EXPORT_NAME="node_exporter_${NAME}"
        echo "[INFO] 部署 node_exporter: ${EXPORT_NAME}  监听 9100"
        docker rm -f "${EXPORT_NAME}" 2>/dev/null || true
        docker run -d --name "${EXPORT_NAME}" \
            --network "${NETWORK}" \
            --pid="host" \
            -v "/:/host:ro,rslave" \
            -p "9100:9100" \
            --restart unless-stopped \
            prom/node-exporter:v1.8.2 \
            --path.rootfs=/host >/dev/null
        echo "[INFO] 等待 exporter 就绪..."
        sleep 3
        "${SCRIPT_DIR}/add-target.sh" "${NAME}" node-exporter "${EXPORT_NAME}:9100"
        ;;

    # ======== InfluxDB (直接注册 /metrics) ========
    influxdb)
        echo "[INFO] InfluxDB 自带 /metrics 端点，直接注册 (${TARGET_ADDR})"
        "${SCRIPT_DIR}/add-target.sh" "${NAME}" influxdb "${TARGET_ADDR}"
        ;;

    *)
        echo "[错误] 未知 type: ${TYPE}"
        echo "  支持: postgresql / mysql / redis / node / influxdb"
        exit 1
        ;;
esac

echo ""
echo "[完成] exporter 已部署并注册。请在 http://localhost:9090/targets 查看状态。"
