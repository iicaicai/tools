#!/bin/bash

# 定义目标目录
TARGETS_DIR="./prometheus/targets"

# 检查依赖
if ! command -v jq &> /dev/null; then
    echo "错误: 未找到 jq，请先安装 jq (例如: apt install jq)"
    exit 1
fi

show_help() {
    echo "使用方法: $0 [操作] [类型] [IP:端口] [别名]"
    echo "操作: add | remove | list"
    echo "类型: nodes | containers | postgres | influxdb"
    echo "示例:"
    echo "  $0 add nodes 192.168.1.10:9100 web-server-1"
    echo "  $0 remove nodes 192.168.1.10:9100"
    echo "  $0 list nodes"
}

if [ $# -lt 2 ]; then
    show_help
    exit 1
fi

ACTION=$1
TYPE=$2
TARGET_FILE="${TARGETS_DIR}/${TYPE}.json"

if [ ! -f "$TARGET_FILE" ]; then
    echo "错误: 类型文件 $TARGET_FILE 不存在。"
    exit 1
fi

case $ACTION in
    add)
        if [ $# -lt 4 ]; then
            echo "错误: add 操作需要提供 IP:端口 和 别名。"
            show_help
            exit 1
        fi
        IP_PORT=$3
        ALIAS=$4
        
        # 检查是否已存在
        EXISTS=$(jq "[.[] | .targets[] | select(. == \"$IP_PORT\")] | length" "$TARGET_FILE")
        if [ "$EXISTS" -gt 0 ]; then
            echo "目标 $IP_PORT 已存在于 $TYPE 监控中。"
            exit 0
        fi

        # 追加新配置
        jq --arg ip "$IP_PORT" --arg alias "$ALIAS" \
           '. += [{"targets": [$ip], "labels": {"instance_alias": $alias}}]' \
           "$TARGET_FILE" > tmp.json && mv tmp.json "$TARGET_FILE"
        echo "✅ 成功添加: $IP_PORT ($ALIAS) 到 $TYPE 监控。"
        ;;
    
    remove)
        if [ $# -lt 3 ]; then
            echo "错误: remove 操作需要提供 IP:端口。"
            show_help
            exit 1
        fi
        IP_PORT=$3
        
        # 移除匹配的 target
        jq --arg ip "$IP_PORT" \
           'map(select(.targets[] != $ip))' \
           "$TARGET_FILE" > tmp.json && mv tmp.json "$TARGET_FILE"
        echo "🗑️ 成功移除: $IP_PORT 从 $TYPE 监控。"
        ;;
        
    list)
        echo "📊 当前 $TYPE 监控目标:"
        jq -r '.[] | "地址: \(.targets[0]) | 别名: \(.labels.instance_alias)"' "$TARGET_FILE"
        ;;
        
    *)
        show_help
        exit 1
        ;;
esac
