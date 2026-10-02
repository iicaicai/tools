#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
代理协议链接转二维码工具

支持的协议：
  TUIC, Trojan, Hysteria2, VMess-WS, VMess-TCP, VMess-HTTP, VMess-QUIC,
  Shadowsocks, VMess-H2-TLS, VMess-WS-TLS, VLESS-H2-TLS, VLESS-WS-TLS,
  Trojan-H2-TLS, Trojan-WS-TLS, VMess-HTTPUpgrade-TLS, VLESS-HTTPUpgrade-TLS,
  Trojan-HTTPUpgrade-TLS, VLESS-REALITY, VLESS-HTTP2-REALITY, AnyTLS, Socks

用法：
  1. 直接传入链接（默认终端打印 + 保存图片）：
     python3 vless_to_qrcode.py "vless://...#备注名"

  2. 从文件批量读取（每行一个链接）：
     python3 vless_to_qrcode.py -f links.txt

  3. 指定输出目录：
     python3 vless_to_qrcode.py "vless://..." -o ./qrcodes

  4. 只在终端打印，不保存图片：
     python3 vless_to_qrcode.py "vless://..." --no-save

  5. 只保存图片，不在终端打印：
     python3 vless_to_qrcode.py "vless://..." --no-terminal

依赖安装：
  pip3 install qrcode[pil]
"""

import argparse
import base64
import json
import os
import re
import sys
import urllib.parse
from datetime import datetime


# 协议前缀映射表
PROTOCOL_PREFIX_MAP = {
    'vless': 'VLESS',
    'vmess': 'VMess',
    'trojan': 'Trojan',
    'ss': 'Shadowsocks',
    'tuic': 'TUIC',
    'hysteria2': 'Hysteria2',
    'hy2': 'Hysteria2',
    'socks': 'Socks',
    'socks5': 'Socks',
    'anytls': 'AnyTLS',
}

# VMess 网络类型映射（从 base64 JSON 中解析）
VMESS_NET_MAP = {
    'ws': 'WS',
    'tcp': 'TCP',
    'http': 'HTTP',
    'quic': 'QUIC',
    'h2': 'H2',
    'grpc': 'H2',
    'httpupgrade': 'HTTPUpgrade',
}


def sanitize_filename(name: str) -> str:
    """将备注名转换为安全的文件名"""
    name = re.sub(r'[\\/:*?"<>|\s]+', '_', name)
    name = name.strip('._-')
    # 限制长度，避免文件名过长
    if len(name) > 80:
        name = name[:80]
    return name or 'qrcode'


def extract_remark(link: str) -> str:
    """从链接中提取 # 后面的备注名（支持 URL 编码的中文）"""
    if '#' in link:
        remark = link.rsplit('#', 1)[1]
        try:
            remark = urllib.parse.unquote(remark)
        except Exception:
            pass
        return remark
    return ''


def detect_protocol(link: str) -> str:
    """
    识别链接的协议类型，返回可读的协议名称。
    例如: VLESS-REALITY, VMess-WS-TLS, Shadowsocks 等
    """
    link = link.strip()
    # 提取 scheme
    match = re.match(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://', link)
    if not match:
        return 'Unknown'

    scheme = match.group(1).lower()
    base_protocol = PROTOCOL_PREFIX_MAP.get(scheme, scheme.upper())

    # ---- VMess：base64 编码的 JSON，需要解码判断 ----
    if scheme == 'vmess':
        try:
            # vmess:// 后面是 base64
            b64_part = link[len('vmess://'):].split('#')[0]
            # 补齐 padding
            padding = 4 - len(b64_part) % 4
            if padding != 4:
                b64_part += '=' * padding
            decoded = base64.b64decode(b64_part).decode('utf-8')
            obj = json.loads(decoded)
            net = obj.get('net', 'tcp').lower()
            tls = obj.get('tls', '').lower() == 'tls'
            net_type = VMESS_NET_MAP.get(net, net.upper())
            if tls:
                return f'VMess-{net_type}-TLS'
            else:
                return f'VMess-{net_type}'
        except Exception:
            return 'VMess'

    # ---- VLESS：从参数判断 ----
    if scheme == 'vless':
        try:
            parsed = urllib.parse.urlsplit(link)
            params = urllib.parse.parse_qs(parsed.query)
            security = params.get('security', [''])[0].lower()
            net_type = params.get('type', ['tcp'])[0].lower()
            if security == 'reality':
                if net_type == 'h2' or net_type == 'http':
                    return 'VLESS-HTTP2-REALITY'
                return 'VLESS-REALITY'
            elif security == 'tls':
                net_map = {'ws': 'WS', 'h2': 'H2', 'http': 'H2',
                           'grpc': 'H2', 'httpupgrade': 'HTTPUpgrade', 'tcp': 'TCP'}
                sub = net_map.get(net_type, net_type.upper())
                return f'VLESS-{sub}-TLS'
            else:
                net_map = {'ws': 'WS', 'tcp': 'TCP', 'http': 'HTTP', 'quic': 'QUIC'}
                sub = net_map.get(net_type, net_type.upper())
                return f'VLESS-{sub}'
        except Exception:
            return 'VLESS'

    # ---- Trojan：从参数判断 ----
    if scheme == 'trojan':
        try:
            parsed = urllib.parse.urlsplit(link)
            params = urllib.parse.parse_qs(parsed.query)
            security = params.get('security', [''])[0].lower()
            net_type = params.get('type', ['tcp'])[0].lower()
            if security == 'tls':
                net_map = {'ws': 'WS', 'h2': 'H2', 'http': 'H2',
                           'grpc': 'H2', 'httpupgrade': 'HTTPUpgrade', 'tcp': 'TCP'}
                sub = net_map.get(net_type, net_type.upper())
                return f'Trojan-{sub}-TLS'
            else:
                return 'Trojan'
        except Exception:
            return 'Trojan'

    # ---- 其他协议直接返回 ----
    return base_protocol


def get_timestamp() -> str:
    """返回 20261002_155520 格式的时间戳"""
    return datetime.now().strftime('%Y%m%d_%H%M%S')


def print_qr_compact(qr) -> None:
    """
    使用 Unicode 半块字符（▀▄）紧凑打印二维码。
    将两个垂直行合并为一行，高度减半，一屏即可放下。
    """
    matrix = qr.get_matrix()
    # 确保行数为偶数，不足则补一行空白
    if len(matrix) % 2 != 0:
        matrix = matrix + [[False] * len(matrix[0])]

    for i in range(0, len(matrix), 2):
        row_top = matrix[i]
        row_bottom = matrix[i + 1]
        line = []
        for top, bottom in zip(row_top, row_bottom):
            # True = 黑模块, False = 白模块
            if top and bottom:
                line.append('█')   # 全黑
            elif top and not bottom:
                line.append('▀')   # 上黑下白
            elif not top and bottom:
                line.append('▄')   # 上白下黑
            else:
                line.append(' ')   # 全白
        print(''.join(line))


def generate_qrcode(link: str, output_dir: str, show_terminal: bool, save_image: bool) -> str:
    """
    生成单个二维码。
    - show_terminal: 是否在终端打印
    - save_image: 是否保存图片
    返回保存的图片路径（若未保存则返回空字符串）
    """
    try:
        import qrcode
    except ImportError:
        print("错误：未安装 qrcode 库，请先执行：pip3 install qrcode[pil]", file=sys.stderr)
        sys.exit(1)

    remark = extract_remark(link)
    protocol = detect_protocol(link)
    timestamp = get_timestamp()

    # 终端打印
    if show_terminal:
        qr = qrcode.QRCode(border=1)
        qr.add_data(link)
        qr.make(fit=True)
        print(f"\n{'=' * 50}")
        print(f"  协议: {protocol}")
        print(f"  备注: {remark or '(无)'}")
        print(f"  时间: {timestamp}")
        print(f"{'=' * 50}")
        print_qr_compact(qr)
        print()

    if not save_image:
        return ''

    # 生成图片
    qr = qrcode.QRCode(
        version=None,
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=10,
        border=4,
    )
    qr.add_data(link)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")

    os.makedirs(output_dir, exist_ok=True)

    # 文件名：备注名_协议_时间戳.png 或 协议_时间戳.png
    name_part = sanitize_filename(remark) if remark else protocol
    filename = f"{name_part}_{timestamp}.png"

    filepath = os.path.join(output_dir, filename)
    # 防止重名（同一秒内多次生成）
    base, ext = os.path.splitext(filename)
    counter = 1
    while os.path.exists(filepath):
        filepath = os.path.join(output_dir, f"{base}_{counter}{ext}")
        counter += 1

    img.save(filepath)
    return filepath


def read_links_from_file(filepath: str) -> list:
    """从文件读取链接，每行一个，忽略空行和注释"""
    if not os.path.isfile(filepath):
        print(f"错误：文件不存在 - {filepath}", file=sys.stderr)
        sys.exit(1)
    links = []
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                links.append(line)
    return links


def main():
    parser = argparse.ArgumentParser(
        description='将代理协议链接转换为二维码（默认终端打印 + 保存图片）',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument('link', nargs='?', help='代理协议链接字符串')
    parser.add_argument('-f', '--file', help='包含链接的文件路径（每行一个）')
    parser.add_argument('-o', '--output', default='./qrcodes',
                        help='二维码图片输出目录（默认 ./qrcodes）')
    parser.add_argument('--no-terminal', action='store_true',
                        help='不在终端打印二维码（仅保存图片）')
    parser.add_argument('--no-save', action='store_true',
                        help='不保存图片文件（仅在终端打印）')

    args = parser.parse_args()

    # 收集链接
    links = []
    if args.link:
        links.append(args.link)
    if args.file:
        links.extend(read_links_from_file(args.file))

    if not links:
        parser.print_help()
        sys.exit(1)

    show_terminal = not args.no_terminal
    save_image = not args.no_save

    if not show_terminal and not save_image:
        print("错误：--no-terminal 和 --no-save 不能同时使用", file=sys.stderr)
        sys.exit(1)

    print(f"共处理 {len(links)} 个链接")
    print(f"终端打印: {'开启' if show_terminal else '关闭'}  |  保存图片: {'开启' if save_image else '关闭'}\n")

    success = 0
    for i, link in enumerate(links, 1):
        try:
            protocol = detect_protocol(link)
            result = generate_qrcode(link, args.output, show_terminal, save_image)
            if result:
                print(f"[{i}/{len(links)}] ✓ [{protocol}] 已保存: {result}")
            else:
                print(f"[{i}/{len(links)}] ✓ [{protocol}] 终端打印完成")
            success += 1
        except Exception as e:
            print(f"[{i}/{len(links)}] ✗ 失败: {e}", file=sys.stderr)

    print(f"\n完成：成功 {success} / 共 {len(links)}")
    if save_image and success > 0:
        abs_dir = os.path.abspath(args.output)
        print(f"图片保存在: {abs_dir}")


if __name__ == '__main__':
    main()
