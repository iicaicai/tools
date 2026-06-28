#!/usr/bin/env bash
# ============================================================
# download-dashboard.sh - 从 Grafana.com 下载社区 Dashboard
#
# 用法:
#   ./scripts/download-dashboard.sh <dashboard-id> <filename.json>
#
# 常用 Dashboard ID:
#   1860  : Node Exporter Full (最全面的主机监控)
#   9628  : PostgreSQL Overview
#   14053 : MySQL / MariaDB Overview
#   763   : Redis Overview
#   13994 : Prometheus 2.0 Overview
#   11074 : Docker Container Monitoring
#
# 示例:
#   ./scripts/download-dashboard.sh 1860 node-exporter-full.json
#
# 注意: 下载后 Grafana 会在 30 秒内自动识别并加载新的 dashboard
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DASH_DIR="${PROJECT_ROOT}/grafana/dashboard_files"

if [ $# -lt 2 ]; then
    echo "用法: $0 <dashboard-id> <filename.json>"
    echo ""
    echo "常用 Dashboard ID:"
    echo "  1860  - Node Exporter Full"
    echo "  9628  - PostgreSQL Overview"
    echo "  14053 - MySQL / MariaDB Overview"
    echo "  763   - Redis Overview"
    echo "  13994 - Prometheus 2.0 Overview"
    echo ""
    echo "示例:"
    echo "  $0 1860 node-exporter-full.json"
    exit 1
fi

DASH_ID="$1"
FILENAME="$2"

mkdir -p "${DASH_DIR}"

if ! command -v curl >/dev/null 2>&1; then
    echo "[错误] 未安装 curl"
    exit 1
fi

echo "[INFO] 正在下载 Dashboard ID=${DASH_ID} -> ${FILENAME}..."
RESPONSE=$(curl -sL "https://grafana.com/api/dashboards/${DASH_ID}/revisions/latest/download")

# 检查是否返回了合法 JSON
if echo "${RESPONSE}" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null; then
    echo "${RESPONSE}" > "${DASH_DIR}/${FILENAME}"
    echo "[成功] Dashboard 已保存到 ${DASH_DIR}/${FILENAME}"
    echo ""
    echo "[提示] Grafana 会在 30 秒内自动加载此 Dashboard"
    echo "       可在 http://localhost:3000 查看"
else
    echo "[错误] 下载失败或返回的不是合法 JSON。请检查 Dashboard ID 是否正确。"
    echo "       响应内容:"
    echo "${RESPONSE}" | head -c 500
    echo ""
    exit 1
fi
