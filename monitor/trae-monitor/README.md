# Prometheus + Grafana 监控平台

基于 Docker Compose 的一整套服务器/容器监控方案，支持动态添加和删除监控目标。

## 目录结构

```
.
├── docker-compose.yml              # 主配置文件
├── prometheus/
│   ├── prometheus.yml              # Prometheus 主配置
│   ├── rules/                      # 告警规则
│   │   └── general.rules.yml
│   └── targets.d/                  # 动态目标配置目录 (核心)
│       ├── node-exporter-local.yml
│       ├── node-exporter-remote.yml.example
│       ├── postgresql.yml.example
│       ├── mysql.yml.example
│       ├── influxdb.yml.example
│       └── redis.yml.example
├── alertmanager/
│   └── alertmanager.yml            # 告警分发配置
├── grafana/
│   ├── datasources/                # 自动配置数据源
│   │   └── prometheus.yml
│   ├── dashboards/                 # 自动加载 Dashboard 配置
│   │   └── dashboards.yml
│   └── dashboard_files/            # 预置 Dashboard JSON
│       ├── node-exporter.json
│       ├── postgresql.json
│       ├── mysql.json
│       ├── redis.json
│       └── prometheus-overview.json
└── scripts/                        # 管理脚本 (核心功能)
    ├── start-all.sh                # 一键启动
    ├── stop-all.sh                 # 停止服务
    ├── add-target.sh               # 添加监控目标
    ├── remove-target.sh            # 移除监控目标
    ├── list-targets.sh             # 查看所有目标
    ├── deploy-exporter.sh          # 一键部署 exporter + 注册目标
    ├── remove-exporter.sh          # 移除 exporter + 注销目标
    └── download-dashboard.sh       # 下载社区 Dashboard
```

## 快速开始

### 1. 启动监控服务

```bash
./scripts/start-all.sh
# 或手动执行
docker compose up -d
```

启动后访问：

| 服务         | 地址                         | 账号/说明           |
|-------------|------------------------------|--------------------|
| Grafana     | http://localhost:3000       | admin / admin123    |
| Prometheus  | http://localhost:9090       | /targets 看目标状态 |
| Alertmanager| http://localhost:9093       | 告警规则与分发     |

### 2. 添加一个远程主机监控

假设你要监控的物理机 IP 是 `192.168.1.100`：

**步骤 1：在目标物理机上安装 node-exporter**

```bash
# 在被监控物理机上执行（不是监控服务器上）
wget https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar xzf node_exporter-1.8.2.linux-amd64.tar.gz
cd node_exporter-1.8.2.linux-amd64
./node_exporter --web.listen-address=:9100 &

# 放行防火墙
ufw allow 9100/tcp || firewall-cmd --add-port=9100/tcp
```

**步骤 2：在监控服务器上注册目标**

```bash
./scripts/add-target.sh web-server-01 node-exporter 192.168.1.100:9100 "dc=shanghai,env=prod"
```

完成！Prometheus 会在 30 秒内自动发现并抓取该目标，Grafana 的 `Node Exporter` Dashboard 也会自动显示该主机的指标。

### 3. 监控 PostgreSQL 容器

```bash
# 方法一：一键部署（推荐）
./scripts/deploy-exporter.sh postgresql my-pg postgres:5432 \
    --user postgres --password mypass --dbname postgres

# 方法二：手动部署 exporter + 注册目标
# 1) 启动 postgres_exporter
docker run -d --name pg_exporter --network monitor-net \
    -e DATA_SOURCE_NAME="postgresql://postgres:mypass@postgres:5432/postgres?sslmode=disable" \
    -p 9187:9187 quay.io/prometheuscommunity/postgres-exporter:v0.15.0

# 2) 注册到 Prometheus
./scripts/add-target.sh my-pg postgresql pg_exporter:9187
```

### 4. 查看已配置的目标

```bash
./scripts/list-targets.sh
```

### 5. 移除一个监控目标

```bash
./scripts/remove-target.sh node-exporter web-server-01
# 或者如果是通过 deploy-exporter.sh 部署的：
./scripts/remove-exporter.sh postgresql my-pg
```

## 动态配置原理

Prometheus 支持 `file_sd_configs`（File-based Service Discovery），我们将所有监控目标放在 `prometheus/targets.d/` 目录下。核心配置在 `prometheus.yml` 中：

```yaml
scrape_configs:
  - job_name: 'dynamic-targets'
    file_sd_configs:
      - files:
          - '/etc/prometheus/targets.d/*.yml'
        refresh_interval: 30s
```

**工作流程：**

```
add-target.sh 写入 YAML 文件 
    └─> Prometheus 每 30 秒扫描一次 targets.d/
         └─> 自动识别新增/删除的目标
              └─> Grafana Dashboard 自动显示新指标
```

**立即触发重载**（不等待 30 秒）：

```bash
curl -X POST http://localhost:9090/-/reload
```

（`add-target.sh` 会自动执行此命令）

## 脚本详解

### add-target.sh

```bash
./scripts/add-target.sh <name> <job> <host:port> [labels]
```

- `name`: 给这个目标起的名字（也会作为 `instance` 标签值）
- `job`: 目标类型（决定使用哪个 Grafana Dashboard）
  - `node-exporter` - 物理机/虚拟机
  - `postgresql` - PostgreSQL 数据库
  - `mysql` - MySQL/MariaDB 数据库
  - `influxdb` - InfluxDB 时序数据库
  - `redis` - Redis 缓存
  - 你可以自定义任何值
- `host:port`: exporter 暴露的指标端点
- `labels`: 可选的自定义标签，格式 `key1=val1,key2=val2`

### remove-target.sh

```bash
./scripts/remove-target.sh <job> <name>
```

删除对应的 YAML 文件，触发 Prometheus 重载。

### deploy-exporter.sh

一键部署 exporter 容器，并注册到 Prometheus。适合监控**同网络内**的容器化服务。

```bash
./scripts/deploy-exporter.sh postgresql my-pg postgres:5432 \
    --user postgres --password mypass

./scripts/deploy-exporter.sh mysql my-mysql mysql:3306 \
    --user exporter --password secret

./scripts/deploy-exporter.sh redis my-redis redis:6379 \
    --password myredispassword

./scripts/deploy-exporter.sh node local-host localhost:9100

./scripts/deploy-exporter.sh influxdb my-influx influxdb:8086
```

### list-targets.sh

显示当前配置的目标，同时尝试从 Prometheus API 查询实时健康状态。

### download-dashboard.sh

从 Grafana.com 下载社区 Dashboard：

```bash
./scripts/download-dashboard.sh 1860 node-exporter-full.json
./scripts/download-dashboard.sh 9628 postgresql-full.json
./scripts/download-dashboard.sh 14053 mysql-full.json
./scripts/download-dashboard.sh 763  redis-full.json
./scripts/download-dashboard.sh 13994 prometheus-overview-full.json
```

下载后 Grafana 在 30 秒内自动加载。

## 告警规则

告警规则定义在 `prometheus/rules/general.rules.yml` 中，包含：

- **主机告警**：宕机、CPU > 85%、内存 > 90%、磁盘 > 85%
- **数据库告警**：PostgreSQL 连接池、MySQL 状态、Redis 不可达
- **自身健康**：Prometheus 配置重载失败

告警通过 `alertmanager/alertmanager.yml` 分发，你可以配置邮件、Webhook、钉钉、企业微信等。

## 手动编辑目标文件

你也可以直接手动创建 YAML 文件。格式要求：

```yaml
- targets:
    - 192.168.1.100:9100
    - 192.168.1.101:9100    # 支持同一文件内多个端点
  labels:
    job: node-exporter
    instance: web-cluster
    location: shanghai
    env: production
```

保存到 `prometheus/targets.d/<任意名称>.yml` 即可。

## 常用维护命令

```bash
# 启动/停止
./scripts/start-all.sh
./scripts/stop-all.sh

# 查看状态
docker compose ps
docker compose logs -f prometheus
docker compose logs -f grafana

# 查看 Prometheus 目标状态
curl http://localhost:9090/api/v1/targets

# 手动触发重载
curl -X POST http://localhost:9090/-/reload

# 进入容器调试
docker exec -it prometheus sh
docker exec -it grafana sh

# 清理全部（⚠️ 删除数据）
docker compose down -v
```

## 自定义与扩展

### 添加新的 exporter 类型

假设你要监控 MongoDB：

1. 部署 `mongodb_exporter` 容器
2. `./scripts/add-target.sh my-mongo mongodb mongo-host:9216`
3. 到 `prometheus/rules/` 添加 Mongodb 相关规则
4. 到 Grafana 导入 MongoDB Dashboard（`./scripts/download-dashboard.sh <id> mongo.json` 或从 grafana.com 导入）

### 修改数据保留策略

编辑 `docker-compose.yml` 中 prometheus 命令行参数：

```yaml
command:
  - '--storage.tsdb.retention.time=30d'  # 保留 30 天
  - '--storage.tsdb.retention.size=20GB' # 最大 20GB
```

### 自定义 Grafana 账号

编辑 `docker-compose.yml`：

```yaml
environment:
  - GF_SECURITY_ADMIN_USER=youruser
  - GF_SECURITY_ADMIN_PASSWORD=yourpassword
```

### 配置邮件告警

编辑 `alertmanager/alertmanager.yml`：

```yaml
global:
  smtp_smarthost: 'smtp.qq.com:465'
  smtp_from: 'monitor@example.com'
  smtp_auth_username: 'monitor@example.com'
  smtp_auth_password: 'your_auth_code'

receivers:
  - name: 'default-receiver'
    email_configs:
      - to: 'ops@example.com'
        send_resolved: true
```

## 安全建议

1. **不要暴露 9090 / 3000 / 9093 到公网**，使用 VPN 或反向代理加身份验证
2. **修改 Grafana 默认密码**，首次登录后立即修改
3. **为 exporter 配置 TLS + Basic Auth**，或放在内网 / VPC 内
4. **定期更新容器镜像**：`docker compose pull && docker compose up -d`
5. **使用环境变量存放敏感信息**（如数据库密码），不要硬编码在 YAML 中

## 故障排查

### Prometheus 目标显示 "Connection refused"

- 检查目标主机的 exporter 是否启动：`curl http://192.168.1.100:9100/metrics`
- 检查防火墙规则是否放行对应端口
- 检查容器网络是否可达

### Grafana 显示 "No data"

- 等待 1-2 分钟让 Prometheus 采集第一批数据
- 确认 Prometheus 的 `/targets` 页面中目标是 `UP` 状态
- Dashboard 的变量（如 `$job`、`$instance`）可能需要重新选择

### Prometheus 配置重载失败

```bash
# 检查 YAML 语法
python3 -c "import yaml; yaml.safe_load(open('prometheus/targets.d/your-file.yml'))"

# 查看 Prometheus 日志
docker compose logs prometheus --tail 50
```

### Docker 容器间网络不通

确保所有 exporter 容器加入 `monitor-net` 网络（`deploy-exporter.sh` 已自动处理）。如果是手动部署，请添加 `--network monitor-net` 参数。
