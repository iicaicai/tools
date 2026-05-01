#!/usr/bin/env bash
#
# GitHub 大文件切割 / 还原工具
# 用途：将大文件切割为多个 90MB 的小文件，或将其还原
# 用法：
#   ./ghfile.sh split  <大文件路径>          # 切割
#   ./ghfile.sh merge <切割后的第一个分片>    # 还原
#

set -euo pipefail

# ======================== 配置 ========================
CHUNK_SIZE="90M"
SUFFIX_LEN=3          # 分片编号位数，如 001, 002
# =====================================================

# ---------- 颜色输出 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---------- 用法帮助 ----------
usage() {
    cat <<EOF
用法:
  $0 split  <文件路径>              将大文件切割为 ${CHUNK_SIZE} 的分片
  $0 merge  <第一个分片路径>        将分片还原为原始文件

示例:
  $0 split  bigfile.zip
  $0 merge  bigfile.zip.part_001

说明:
  - 切割后生成:  <原文件名>.part_001, <原文件名>.part_002, ...
  - 还原时只需指定第一个分片，脚本自动查找并合并后续分片
  - 还原后的文件保存在当前目录，文件名去掉 .part_XXX 后缀
EOF
    exit 0
}

# ---------- 切割功能 ----------
do_split() {
    local filepath="$1"
    local filename
    filename=$(basename -- "$filepath")

    [[ ! -f "$filepath" ]] && error "文件不存在: $filepath"

    local filesize
    filesize=$(stat -c%s "$filepath")
    local filesize_human
    filesize_human=$(numfmt --to=iec-i --suffix=B "$filesize")

    # 计算分片数量
    local chunk_bytes=$(( 90 * 1024 * 1024 ))
    local num_chunks=$(( (filesize + chunk_bytes - 1) / chunk_bytes ))

    info "原始文件: $filename ($filesize_human)"
    info "分片大小: ${CHUNK_SIZE}"
    info "预计分片: ${num_chunks} 个"

    # 输出目录（默认与源文件同目录）
    local outdir
    outdir=$(dirname -- "$filepath")

    local prefix="${outdir}/${filename}.part_"

    # 执行切割
    info "正在切割..."
    split -b "$CHUNK_SIZE" -d -a "$SUFFIX_LEN" --additional-suffix="" \
          "$filepath" "${prefix}"

    # 验证
    local count=0
    for f in "${prefix}"*; do
        [[ -f "$f" ]] && ((count++))
    done

    echo ""
    info "切割完成! 共生成 ${count} 个分片:"
    echo ""
    printf "  ${CYAN}%-40s %s${NC}\n" "文件名" "大小"
    printf "  %-40s %s\n" "----------------------------------------" "--------"
    for f in "${prefix}"*; do
        [[ -f "$f" ]] || continue
        local fsize
        fsize=$(numfmt --to=iec-i --suffix=B "$(stat -c%s "$f")")
        printf "  %-40s %s\n" "$(basename -- "$f")" "$fsize"
    done
    echo ""

    # 生成还原说明
    local first_part="${prefix}$(printf '%0*d' "$SUFFIX_LEN" 0)"
    info "还原命令:  $0 merge $(basename -- "$first_part")"
}

# ---------- 还原功能 ----------
do_merge() {
    local first_part="$1"
    local dir part_prefix base_name

    [[ ! -f "$first_part" ]] && error "分片文件不存在: $first_part"

    dir=$(dirname -- "$first_part")
    base_name=$(basename -- "$first_part")

    # 匹配模式: <name>.part_XXX
    # 找到最后一个下划线后的数字部分
    if [[ "$base_name" =~ ^(.+)\.part_[0-9]+$ ]]; then
        part_prefix="${dir}/${BASH_REMATCH[1]}.part_"
    else
        error "文件名格式不正确，应为: <文件名>.part_XXX"
    fi

    # 查找所有分片
    local -a parts=()
    for f in "${part_prefix}"*; do
        [[ -f "$f" ]] || continue
        # 确保是数字后缀
        local bname
        bname=$(basename -- "$f")
        if [[ "$bname" =~ \.part_[0-9]+$ ]]; then
            parts+=("$f")
        fi
    done

    if [[ ${#parts[@]} -eq 0 ]]; then
        error "未找到任何分片文件"
    fi

    # 按数字后缀排序
    IFS=$'\n' parts=($(sort -t_ -k"${SUFFIX_LEN}" -n <<<"${parts[*]}"))
    unset IFS

    # 还原后的文件名（去掉 .part_XXX）
    local output_name
    if [[ "$base_name" =~ ^(.+)\.part_[0-9]+$ ]]; then
        output_name="${BASH_REMATCH[1]}"
    else
        error "无法解析原始文件名"
    fi
    local output_path="${dir}/${output_name}"

    info "找到 ${#parts[@]} 个分片"
    info "还原文件: ${output_name}"
    info "正在合并..."

    # 合并
    cat "${parts[@]}" > "$output_path"

    local output_size
    output_size=$(numfmt --to=iec-i --suffix=B "$(stat -c%s "$output_path")")
    info "还原完成! 文件: ${output_path} ($output_size)"
}

# ---------- 入口 ----------
main() {
    [[ $# -lt 1 ]] && usage

    local cmd="$1"
    shift

    case "$cmd" in
        split)
            [[ $# -lt 1 ]] && error "请指定要切割的文件路径"
            do_split "$1"
            ;;
        merge)
            [[ $# -lt 1 ]] && error "请指定第一个分片文件路径"
            do_merge "$1"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            error "未知命令: $cmd\n运行 '$0 help' 查看用法"
            ;;
    esac
}

main "$@"

