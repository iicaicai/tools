#!/usr/bin/env bash
# ============================================================
# add-target.sh - 向 Prometheus 动态添加监控目标
#
# 用法:
#   ./scripts/add-target.sh <name> <job> <host:port> [labels...]
#
# 示例:
#   ./scripts/add-target.sh my-pg postgresql 192.168.1.50:9187
#   ./scripts/add-target.sh web-node node-exporter 10.0.0.11:9100 "dc=shanghai,env=prod"
#   ./scripts/add-target.sh my-redis redis redis-1:9121
#
# 常用 job 类型:
#   - node-exporter   : 主机 (端口 9100)
#   - postgresql      : PostgreSQL (端口 9187, 通过 postgres_exporter)
#   - mysql           : MySQL / MariaDB (端口 9104, 通过 mysqld_exporter)
#   - influxdb        : InfluxDB (端口 8086, /metrics 端点)
#   - redis           : Redis (端口 9121, 通过 redis_exporter)
# ============================================================

set -euo pipefail

# --- 目录定位 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGETS_DIR="${PROJECT_ROOT}/prometheus/targets.d"

# --- 参数校验 ---
if [ $# -lt 3 ]; then
    echo "用法: $0 <name> <job> <host:port> [labels (key=value,key=value)]"
    echo ""
    echo "示例:"
    echo "  $0 web-01 node-exporter 192.168.1.10:9100"
    echo "  $0 my-db postgresql pg-host:9187 \"dc=beijing,env=prod\""
    exit 1
fi

NAME="$1"
JOB="$2"
HOSTPORT="$3"
LABELS_RAW="${4:-}"

mkdir -p "${TARGETS_DIR}"

TARGET_FILE="${TARGETS_DIR}/${JOB}-${NAME}.yml"

# --- 防止重复 ---
if [ -f "${TARGET_FILE}" ]; then
    echo "[警告] 目标文件已存在: ${TARGET_FILE}"
    read -p "是否覆盖? (y/N): " -r CONFIRM
    if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
        echo "已取消。"
        exit 0
    fi
fi

# --- 解析 labels ---
LABELS_BLOCK="    instance: ${NAME}"
if [ -n "${LABELS_RAW}" ]; then
    IFS=',' read -ra KV_PAIRS <<< "${LABELS_RAW}"
    for kv in "${KV_PAIRS[@]}"; do
        KEY="$(echo "${kv}" | cut -d'=' -f1 | xargs)"
        VAL="$(echo "${kv}" | cut -d'=' -f2 | xargs)"
        if [ -n "${KEY}" ] && [ -n "${VAL}" ]; then
            LABELS_BLOCK="${LABELS_BLOCK}
    ${KEY}: ${VAL}"
        fi
    done
fi

# --- 生成 YAML ---
cat > "${TARGET_FILE}" <<EOF
# 由 scripts/add-target.sh 生成
# 创建时间: $(date '+%Y-%m-%d %H:%M:%S')
- targets:
    - ${HOSTPORT}
  labels:
    job: ${JOB}
${LABELS_BLOCK}
EOF

echo "[成功] 已写入监控目标: ${TARGET_FILE}"
cat "${TARGET_FILE}"
echo ""

# --- 自动重载 Prometheus ---
echo "[INFO] 触发 Prometheus 配置重载..."
if command -v docker >/dev/null 2>&1; then
    # 方式一: 发送 HTTP POST 到 prometheus
    HTTP_RELOAD=1
    # 尝试使用容器 exec curl (如果 prometheus 容器有 curl)
    if docker ps --format '{{.Names}}' | grep -q "^prometheus$"; then
        if docker exec prometheus which curl >/dev/null 2>&1; then
            docker exec prometheus sh -c "curl -s -X POST http://localhost:9090/-/reload" || true
            echo "[成功] 已通过容器内 curl 触发重载"
            HTTP_RELOAD=0
        fi
    fi
    # 方式二: 从宿主机 curl
    if [ "${HTTP_RELOAD}" -eq 1 ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -s -X POST http://localhost:9090/-/reload || true
            echo "[成功] 已通过宿主机 curl 触发重载"
        else
            echo "[提示] 未找到 curl，Prometheus 会在 30 秒内自动发现变更"
        fi
    fi
else
    echo "[提示] 未安装 docker，Prometheus 会在 30 秒内自动发现变更"
fi

echo ""
echo "[提示] 可在 http://localhost:9090/targets 查看目标状态"
