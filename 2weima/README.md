# 代理协议链接转二维码工具

将各类代理协议链接（VLESS、VMess、Trojan、Shadowsocks、TUIC、Hysteria2 等）转换为二维码，支持终端直接打印和保存为 PNG 图片。

## 功能特性

- **终端直接打印二维码**：使用 Unicode 半块字符（▀▄█）紧凑渲染，一屏即可放下
- **自动识别协议类型**：支持 21 种代理协议，自动解析链接并标注协议名称
- **文件名带时间戳**：保存的图片文件名格式为 `{备注名或协议名}_{YYYYMMDD_HHMMSS}.png`
- **批量处理**：支持从文件读取多个链接，每行一个
- **中文备注支持**：自动 URL 解码 `#` 后的中文备注名

## 支持的协议

| 协议 | 识别方式 |
|------|----------|
| VLESS-REALITY | `vless://` + `security=reality` + `type=tcp` |
| VLESS-HTTP2-REALITY | `vless://` + `security=reality` + `type=h2/http` |
| VLESS-WS-TLS / VLESS-H2-TLS | `vless://` + `security=tls` + `type=ws/h2/...` |
| VMess-WS / VMess-TCP / VMess-HTTP / VMess-QUIC | 解码 `vmess://` 后的 base64 JSON，读取 `net` 字段 |
| VMess-WS-TLS / VMess-H2-TLS | base64 JSON 中 `net` + `tls=tls` |
| VMess-HTTPUpgrade-TLS | base64 JSON 中 `net=httpupgrade` + `tls=tls` |
| Trojan / Trojan-WS-TLS / Trojan-H2-TLS | `trojan://` + `security` + `type` 参数 |
| Shadowsocks | `ss://` 前缀 |
| TUIC | `tuic://` 前缀 |
| Hysteria2 | `hysteria2://` 或 `hy2://` 前缀 |
| AnyTLS | `anytls://` 前缀 |
| Socks | `socks://` 或 `socks5://` 前缀 |

## 安装依赖

```bash
pip3 install -r requirements.txt
```

依赖说明：
- `qrcode`：二维码生成核心库
- `Pillow`（即 `pil`）：将二维码渲染为 PNG 图片

## 使用方法

### 1. 单个链接（默认：终端打印 + 保存图片）

```bash
python3 vless_to_qrcode.py "vless://uuid@example.com:443?security=reality&...#备注名"
```

### 2. 从文件批量读取

```bash
python3 vless_to_qrcode.py -f links.txt
```

文件格式：每行一个链接，空行和以 `#` 开头的行会被忽略。

### 3. 指定输出目录

```bash
python3 vless_to_qrcode.py "vless://..." -o ./my_qrcodes
```

### 4. 只在终端打印，不保存图片

```bash
python3 vless_to_qrcode.py "vless://..." --no-save
```

### 5. 只保存图片，不在终端打印

```bash
python3 vless_to_qrcode.py -f links.txt --no-terminal
```

## 实现原理

### 二维码生成

使用 `qrcode` 库生成 QR 码矩阵：
- 纠错级别：M（中等，约可纠错 15%）
- 模块大小：10px（保存图片时）
- 边框：4 个模块

### 终端紧凑打印

通过 `qr.get_matrix()` 获取二维码的布尔矩阵（`True` = 黑块，`False` = 白块），然后利用 Unicode 半块字符将两行合并为一行：

| 上块 | 下块 | 字符 |
|------|------|------|
| 黑 | 黑 | `█` (U+2588) |
| 黑 | 白 | `▀` (U+2580) |
| 白 | 黑 | `▄` (U+2584) |
| 白 | 白 | ` ` (空格) |

这样二维码的**高度减半**，且每个模块只用一个字符（而非 qrcode 默认的两个字符），整体尺寸约为原始的 1/4，一屏即可完整显示。

### 协议识别

- **VLESS / Trojan**：用 `urllib.parse.urlsplit` 解析 URL，从 query 参数中读取 `security` 和 `type` 字段判断传输层和加密方式
- **VMess**：`vmess://` 后是 base64 编码的 JSON，解码后读取 `net`（网络类型）和 `tls`（是否启用 TLS）字段
- **其他协议**：直接根据 URL scheme（`ss://`、`tuic://`、`hysteria2://` 等）判断

### 文件命名

- 有备注名时：`{备注名}_{时间戳}.png`
- 无备注名时：`{协议名}_{时间戳}.png`
- 时间戳格式：`YYYYMMDD_HHMMSS`（如 `20261002_155520`）
- 同一秒内重复生成自动追加 `_1`、`_2` 序号，避免覆盖
