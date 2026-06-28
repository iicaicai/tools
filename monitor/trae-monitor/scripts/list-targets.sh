#!/usr/bin/env bash
# ============================================================
# list-targets.sh - 列出当前 Prometheus 已配置的所有监控目标
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGETS_DIR="${PROJECT_ROOT}/prometheus/targets.d"

echo "=============================================="
echo " 当前已配置的监控目标"
echo "=============================================="
echo ""

FILES=$(ls "${TARGETS_DIR}"/*.yml 2>/dev/null || echo "")

if [ -z "${FILES}" ]; then
    echo "  (暂无已配置目标)"
    echo ""
    echo "示例: 使用 add-target.sh 添加目标"
    echo "  ./scripts/add-target.sh my-node node-exporter 192.168.1.10:9100"
    exit 0
fi

COUNT=0
for f in ${FILES}; do
    FILENAME=$(basename "${f}")
    echo "--- ${FILENAME} ---"
    cat "${f}"
    echo ""
    COUNT=$((COUNT + 1))
done

echo "=============================================="
echo "合计: ${COUNT} 个目标文件"
echo "=============================================="

# 尝试通过 API 查询 Prometheus 真实抓取状态
if command -v curl >/dev/null 2>&1; then
    echo ""
    echo "正在从 Prometheus API 查询实时状态..."
    RESULT=$(curl -s http://localhost:9090/api/v1/targets 2>/dev/null || echo "{}")
    ACTIVE=$(echo "${RESULT}" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    targets=d.get('data',{}).get('activeTargets',[])
    for t in targets:
        health=t.get('health','unknown')
        labels=t.get('labels',{})
        job=labels.get('job','')
        instance=labels.get('instance','')
        scrape_url=t.get('scrapeUrl','')
        last_error=t.get('lastError','')
        print(f'  [{health:>7}] {job:15} {instance:20} -> {scrape_url} {last_error}')
except Exception as e:
    print('  (无法解析或 Prometheus 未启动)')
" 2>/dev/null || echo "  (无法解析或 Prometheus 未启动)")
    echo "${ACTIVE}"
fi
