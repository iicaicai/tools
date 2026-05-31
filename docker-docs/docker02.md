# Docker 深度培训文档

> **培训目标**：帮助基础技术人员深入了解容器运行时的底层原理，掌握网络、存储、Compose 排错以及容器故障排查的系统方法，具备独立分析和解决 Docker 相关问题的能力。
>
> **培训时长**：2 小时以上
>
> **前置知识**：了解 Docker 基本概念，会使用 `docker run`、`docker start`、`docker stop`、`docker logs`、`docker exec` 等基础命令。

---

## 目录

1. [Docker 网络深度解析](#1-docker-网络深度解析)
2. [Docker 存储卷深入理解](#2-docker-存储卷深入理解)
3. [overlay2 存储驱动详解](#3-overlay2-存储驱动详解)
4. [Docker Compose 调试方法](#4-docker-compose-调试方法)
5. [容器故障排查方法与分析过程](#5-容器故障排查方法与分析过程)

---

## 1. Docker 网络深度解析

### 1.1 网络模型架构总览

Docker 的网络子系统建立在 Linux 内核网络能力之上，整体架构分为四个层次：

```
┌─────────────────────────────────────────────────┐
│              Docker CLI / API                     │
├─────────────────────────────────────────────────┤
│          libnetwork (CNM 模型)                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │ Sandbox  │  │ Endpoint │  │ Network  │       │
│  └──────────┘  └──────────┘  └──────────┘       │
├─────────────────────────────────────────────────┤
│  网络驱动层 (bridge/host/overlay/macvlan/...)   │
├─────────────────────────────────────────────────┤
│  Linux 内核网络 (iptables/ipvs/veth/bridge/...) │
└─────────────────────────────────────────────────┘
```

**CNM (Container Network Model)** 定义了三个核心概念：

| 概念 | 说明 | 对应实体 |
|------|------|----------|
| **Sandbox** | 容器的网络栈隔离环境 | network namespace |
| **Endpoint** | 连接 Sandbox 到 Network 的接口 | veth pair |
| **Network** | 一组可以互相通信的 Endpoint 集合 | bridge/overlay 网络 |

### 1.2 五大网络驱动深入对比

#### 1.2.1 bridge（默认网络驱动）

这是默认的网络模式，也是实际生产中最常用的模式。

**工作原理**：

- Docker 守护进程在宿主机上创建一个名为 `docker0` 的 Linux bridge 设备。
- 每个使用 bridge 网络的容器都会创建一个 veth pair（虚拟以太网对），一端插入容器的 network namespace 作为 `eth0`，另一端连接到 `docker0` bridge。
- 容器之间的通信通过 `docker0` bridge 进行二层转发。
- 容器访问外网通过宿主机的 NAT（iptables SNAT/MASQUERADE）实现。
- 外网访问容器需要通过端口映射（iptables DNAT）实现。

**自定义 bridge 网络 vs 默认 bridge 网络**：

| 特性 | 默认 bridge | 自定义 bridge |
|------|-------------|---------------|
| DNS 自动解析 | 仅 IP 互通 | 自动 DNS 名称解析 |
| 容器隔离 | 需手动 `--link` | 自动服务发现 |
| 网络配置 | 无法修改 | 可配置子网、网关等 |
| 运行时连接/断开 | 不支持 | 支持 `docker network connect/disconnect` |
| 共享环境变量 | 仅 `--link` 方式 | 自动共享 |

**实操探究——查看 bridge 网络的底层实现**：

```bash
# 查看所有网络
docker network ls

# 查看 bridge 网络详细信息（包括已连接容器、子网、网关等）
docker network inspect bridge

# 在宿主机上查看 docker0 bridge
ip addr show docker0
brctl show docker0

# 查看 iptables NAT 规则（容器访问外网的 MASQUERADE 规则）
iptables -t nat -L POSTROUTING -n -v

# 查看端口映射的 DNAT 规则
iptables -t nat -L DOCKER -n -v

# 查看 FORWARD 链的过滤规则
iptables -t filter -L DOCKER-USER -n -v
iptables -t filter -L DOCKER -n -v
```

**关键理解——veth pair 与 network namespace**：

每对 veth pair 都是一个双向管道。在宿主机上的那个 veth 接口会在 Docker daemon 所在的主 network namespace 中可见，而它的对端在容器内的 network namespace 中被重命名为 `eth0`。

```bash
# 在容器内查看网络接口
docker exec <container> ip addr show

# 在宿主机找到对应关系
# 容器的 iflink 对应宿主机的 peer_ifindex
docker exec <container> cat /sys/class/net/eth0/iflink

# 然后在宿主机上搜索对应的 veth 接口
grep -l <iflink_value> /sys/class/net/veth*/ifindex
```

#### 1.2.2 host 网络模式

容器直接使用宿主机的网络栈，不做任何隔离。容器的网络配置与宿主机完全一致。

**使用场景**：
- 需要极高性能的网络吞吐（绕过 Docker 网络层的 NAT/转发开销）
- 容器需要绑定大量端口或端口范围不固定
- 需要访问宿主机所在局域网的服务

**注意事项**：
- 端口冲突：同一个端口在宿主机上只能被一个进程占用
- 安全风险：容器可以直接访问宿主机的所有网络资源
- `-p` 端口映射参数将失效

#### 1.2.3 overlay 网络（Swarm 模式）

用于跨宿主机的容器通信，是 Docker Swarm 的核心网络方案。

**架构要点**：

```
┌─────────────────────┐         ┌─────────────────────┐
│     Node A          │         │      Node B         │
│  ┌──────────────┐   │         │  ┌──────────────┐   │
│  │  Container   │   │         │  │  Container   │   │
│  │  10.0.0.2    │   │         │  │  10.0.0.3    │   │
│  └──────┬───────┘   │         │  └──────┬───────┘   │
│         │           │         │         │           │
│  ┌──────┴───────┐   │  VXLAN  │  ┌──────┴───────┐   │
│  │ docker_gwbridge│◄──Tunnel──►│  │ docker_gwbridge│ │
│  └──────────────┘   │         │  └──────────────┘   │
│         │           │         │         │           │
│  ┌──────┴───────┐   │         │  ┌──────┴───────┐   │
│  │   Overlay    │   │         │  │   Overlay    │   │
│  │  (ingress)   │   │         │  │  (ingress)   │   │
│  └──────────────┘   │         │  └──────────────┘   │
└─────────────────────┘         └─────────────────────┘
```

- **数据面**：基于 VXLAN 隧道协议，通过 `172.17.0.0/16` 之类的 overlay 子网通信。
- **控制面**：基于 Gossip 协议进行网络状态同步（Swarm manager 节点）。
- **加密**：通过 `--opt encrypted=true` 支持 IPSec 加密。

#### 1.2.4 macvlan / ipvlan 网络模式

容器直接获得与宿主机同网段的 IP 地址，使用独立的 MAC 地址。

**macvlan 模式**：

```bash
# 创建 macvlan 网络
docker network create -d macvlan \
  --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 \
  -o parent=eth0 \
  macvlan-net

# 启动容器时指定 IP
docker run -d --name myapp \
  --network macvlan-net \
  --ip 192.168.1.100 \
  nginx
```

**macvlan vs ipvlan 的区别**：
- macvlan：每个容器分配独立 MAC，需要在物理交换机上允许多个 MAC 绑定单个端口
- ipvlan：所有容器共享宿主机 MAC，但各自拥有独立 IP

**陷阱**：macvlan 模式下宿主机本身无法直接与子接口容器通信（这是一个常见问题），需要创建 macvlan 子接口让宿主机也能通过该网络通信。

### 1.3 iptables 与 Docker 网络深度关联

Docker 网络的核心能力严重依赖 iptables。理解 iptables 规则是排查网络问题的关键。

#### 1.3.1 出站流量（容器 → 外网）的数据流

```
容器 eth0 → veth → docker0 bridge → 宿主机路由 → iptables POSTROUTING(MASQUERADE) → eth0 → 外网
```

关键的 NAT 规则：

```bash
# MASQUERADE 规则：将容器的私有 IP 伪装为宿主机 IP
iptables -t nat -L POSTROUTING -n -v
# 输出示例：
# MASQUERADE  all  --  172.17.0.0/16  0.0.0.0/0
```

#### 1.3.2 入站流量（外网 → 容器端口映射）的数据流

```
外网 → eth0 → iptables PREROUTING(DNAT) → docker0 bridge → veth → 容器 eth0
```

```bash
# DNAT 规则：将宿主机端口映射到容器
iptables -t nat -L DOCKER -n -v
# 输出示例：
# tcp dpt:8080 to:172.17.0.2:80
```

#### 1.3.3 容器间通信的过滤规则

```bash
# 容器间的通信需要经过 FORWARD 链
iptables -L FORWARD -n -v

# Docker 创建的 DOCKER-USER 链（用户自定义规则的优先级位置）
iptables -L DOCKER-USER -n -v

# DOCKER-ISOLATION-STAGE 链（负责网络间的隔离）
iptables -L DOCKER-ISOLATION-STAGE-1 -n -v
iptables -L DOCKER-ISOLATION-STAGE-2 -n -v
```

#### 1.3.4 网络问题排查实战

**常见问题一：容器无法访问外网**

排查步骤：

```bash
# 1. 检查容器的 DNS 配置
docker exec <container> cat /etc/resolv.conf

# 2. 检查 docker0 bridge 是否正常
ip addr show docker0

# 3. 检查 IP 转发是否开启（必须为 1）
sysctl net.ipv4.ip_forward
cat /proc/sys/net/ipv4/ip_forward

# 4. 检查 iptables FORWARD 链默认策略
iptables -L FORWARD -n | head -5

# 5. 检查 MASQUERADE 规则
iptables -t nat -L POSTROUTING -n -v | grep MASQ

# 6. 检查是否存在防火墙干扰（如 firewalld）
systemctl status firewalld
firewall-cmd --list-all

# 7. 检查 docker 网桥的 icc (inter-container communication) 配置
docker network inspect bridge | grep -A5 "com.docker.network.bridge.enable_icc"
```

**常见问题二：端口映射不生效**

```bash
# 1. 确认端口映射规则是否正确加载
docker port <container>

# 2. 检查 DNAT 规则
iptables -t nat -L PREROUTING -n -v
iptables -t nat -L DOCKER -n -v

# 3. 检查是否有其他服务占用宿主机端口
ss -tlnp | grep <port>

# 4. 检查容器内应用是否监听 0.0.0.0（而非 127.0.0.1）
docker exec <container> ss -tlnp

# 5. 尝试重启 docker-proxy（userland proxy）
# 查看是否有 docker-proxy 进程
ps aux | grep docker-proxy

# 6. 确认 --userland-proxy=false 的影响（某些场景下可能绕过代理）
docker info | grep -i userland
```

**常见问题三：容器 DNS 解析失败**

```bash
# 1. 检查容器的 /etc/resolv.conf
docker exec <container> cat /etc/resolv.conf

# 2. 检查 dockerd 的 DNS 配置
cat /etc/docker/daemon.json
# 查看 dns 字段

# 3. 测试 DNS 服务器是否可达
docker exec <container> nslookup google.com
docker exec <container> ping <dns-server-ip>

# 4. 检查 docker 嵌入式 DNS（127.0.0.11）
# 对于自定义网络，docker 会为每个容器提供嵌入式 DNS
docker exec <container> cat /etc/resolv.conf
# 如果看到 nameserver 127.0.0.11，说明用的是 Docker 内置 DNS

# 5. 排查自定义网络 DNS 解析
docker network inspect <network_name>
# 查看容器的 IP 和名称
docker exec <container1> ping <container2_name>
```

### 1.4 Docker 嵌入式 DNS 解析原理

在自定义 bridge 网络中，Docker 为每个容器提供嵌入式 DNS 服务（监听 `127.0.0.11:53`），实现服务发现。

**工作原理**：

1. 容器的 `/etc/resolv.conf` 中 `nameserver` 被设置为 `127.0.0.11`。
2. Docker daemon 在容器内部拦截 DNS 请求（通过 iptables 规则重定向到 dockerd 的 DNS 模块）。
3. DNS 模块根据 network scope 内的容器名称和别名进行解析。
4. 在不同 network 之间，默认无法通过 DNS 解析另一个网络的容器名（除非用 `--link` 或使用服务别名）。

**验证命令**：

```bash
# 查看嵌入式 DNS 的 iptables 规则
docker exec <container> iptables -t nat -L OUTPUT -n -v
# 查看发送到 127.0.0.11:53 的流量如何被处理

# 观察 DNS 行为
docker run --rm --network=mynet busybox nslookup <other_container_name>
```

### 1.5 网络性能调优要点

- **禁用 userland proxy**：在 `/etc/docker/daemon.json` 中设置 `"userland-proxy": false`，使用纯 iptables 方式的端口映射（减少 proxy 进程开销）。
- **调整 MTU**：尤其在 overlay 网络中，VXLAN 头部会占用 50 字节，需适当调低容器网络的 MTU。
- **选择合适的网络驱动**：高吞吐场景用 `host` 模式，需要独立 IP 的场景用 `macvlan`。
- **内核参数优化**：增大 conntrack 表大小，避免 NAT 连接跟踪表满。

```bash
# conntrack 表容量排查
cat /proc/sys/net/netfilter/nf_conntrack_max
cat /proc/sys/net/netfilter/nf_conntrack_count

# 临时增大
sysctl -w net.netfilter.nf_conntrack_max=131072
```

---

## 2. Docker 存储卷深入理解

### 2.1 三种挂载类型对比

| 特性 | Volume | Bind Mount | tmpfs |
|------|--------|------------|-------|
| 存储位置 | `/var/lib/docker/volumes/` | 宿主机任意路径 | 内存 |
| 管理方式 | Docker 管理 | 用户管理 | Docker 管理 |
| 跨容器共享 | 是 | 是 | 否 |
| 跨主机迁移 | 支持（通过驱动） | 不直接支持 | 不支持 |
| 生命周期 | 独立于容器 | 依赖宿主机文件系统 | 随容器结束而删除 |
| 持久化 | 是 | 是 | 否（仅内存） |
| 性能 | 取决于底层文件系统 | 取决于底层文件系统 | 极高 |
| 适用场景 | 数据库数据、应用状态 | 开发环境代码热更新 | 敏感信息、临时缓存 |

### 2.2 Volume 深入探究

#### 2.2.1 Volume 的内部存储结构

```bash
# Volume 存储在 /var/lib/docker/volumes/ 下，每个 volume 一个目录
ls /var/lib/docker/volumes/
# 输出示例：myvolume/

ls /var/lib/docker/volumes/myvolume/
# 输出：_data/

# _data 目录是实际存储数据的地方
# 在容器内，这个 _data 目录被 bind mount 到容器内的目标路径
```

#### 2.2.2 Volume 的底层挂载实现

当你在容器中使用 volume 时，Docker 实际执行的操作是：

```
1. 创建或确认 /var/lib/docker/volumes/<volumename>/_data 存在
2. 在容器进程启动时，使用 mount bind 将该目录挂载到容器的目标位置
3. 通过 mount namespace 实现隔离
```

可以通过以下方式验证：

```bash
# 在宿主机查看挂载情况
mount | grep docker
# 或
findmnt | grep docker

# 查看特定容器的挂载点
docker inspect <container> | jq '.[0].Mounts'
```

输出示例：
```json
[
  {
    "Type": "volume",
    "Name": "myvolume",
    "Source": "/var/lib/docker/volumes/myvolume/_data",
    "Destination": "/app/data",
    "Driver": "local",
    "Mode": "rw",
    "RW": true,
    "Propagation": "rprivate"
  }
]
```

**Propagation（传播模式）的含义**：

| 模式 | 含义 | 使用场景 |
|------|------|----------|
| `rprivate` | 默认。mount 事件不向任何方向传播 | 大多数场景 |
| `rshared` | mount 事件向原挂载点和所有副本传播 | 需要在容器内访问宿主机挂载的 NFS |
| `rslave` | 仅单向传播：主挂载点变更会传播到副本 | 特定的 NFS 场景 |
| `private` | 等价于 rprivate 但不递归 | 特定需求 |

#### 2.2.3 Volume 驱动

Docker 支持通过 volume 插件为 volume 提供不同的后端存储：

```bash
# 查看已安装的 volume 插件
docker plugin ls

# 创建使用特定驱动的 volume
docker volume create --driver <driver_name> --opt <key>=<value> myvolume

# 常见第三方驱动
# - vieux/sshfs: 通过 SSHFS 挂载远程文件系统
# - rexray/s3fs: 挂载 AWS S3
# - nfs/nfs: 挂载 NFS
```

**NFS Volume 配置示例**：

```bash
# 使用 local 驱动的 NFS 选项创建 volume
docker volume create \
  --driver local \
  --opt type=nfs \
  --opt o=addr=192.168.1.100,rw,nfsvers=4 \
  --opt device=:/exports/data \
  nfs-volume

# 在容器中使用
docker run -d --name myapp \
  -v nfs-volume:/data \
  nginx
```

#### 2.2.4 Volume 数据备份与恢复

**备份一个 volume 的数据**：

```bash
# 方法：临时启动一个容器，将 volume 数据打包
docker run --rm \
  -v myvolume:/source \
  -v $(pwd):/backup \
  busybox \
  tar cvf /backup/myvolume_backup.tar -C /source .

# 或使用更安全的方法，先停止使用该 volume 的容器
docker stop myapp
docker run --rm \
  -v myvolume:/source:ro \
  -v $(pwd):/backup \
  alpine tar czf /backup/myvolume_backup_$(date +%Y%m%d).tar.gz -C /source .
```

**恢复 volume 数据**：

```bash
# 方法一：恢复到新的 volume
docker volume create myvolume_restored
docker run --rm \
  -v myvolume_restored:/target \
  -v $(pwd):/backup \
  busybox \
  tar xvf /backup/myvolume_backup.tar -C /target

# 方法二：原地恢复（注意：需先清空 volume）
docker run --rm \
  -v myvolume:/target \
  -v $(pwd):/backup \
  alpine sh -c "rm -rf /target/* && tar xzf /backup/myvolume_backup.tar.gz -C /target"
```

#### 2.2.5 Volume 存储问题排查

**问题一：Volume 占用空间过大**

```bash
# 查看所有 volume 的磁盘占用
docker system df -v

# 查看具体 volume 的大小
du -sh /var/lib/docker/volumes/*/_data/

# 清理无用 volume（未被任何容器使用的 volume）
docker volume prune

# 列出未被使用的 volume
docker volume ls -f dangling=true
```

**问题二：容器内 volume 权限问题**

```bash
# 这是最常见的 volume 问题：
# 容器内进程的用户 (UID) 对 volume 文件没有读写权限

# 1. 查看容器内运行进程的用户
docker exec <container> id
docker exec <container> whoami

# 2. 查看 volume 目录的权限和属主
ls -la /var/lib/docker/volumes/myvolume/_data/

# 3. 解决方案：
# 方案A：在 Dockerfile 中匹配用户
RUN addgroup --gid 1000 appgroup && adduser --uid 1000 --gid 1000 appuser
USER appuser

# 方案B：启动时使用 --user 参数
docker run -d --user 1000:1000 -v myvolume:/data myapp

# 方案C：修改宿主机目录权限（不推荐，但有时不可避免）
chown 1000:1000 /var/lib/docker/volumes/myvolume/_data/
```

**问题三：NFS volume 挂载失败**

```bash
# 1. 查看 dockerd 日志
journalctl -u docker -f -n 100

# 2. 手动测试 NFS 挂载
mount -t nfs -o rw,nfsvers=4 192.168.1.100:/exports/data /mnt/nfs_test

# 3. 检查 rpcbind 服务（NFS 依赖）
systemctl status rpcbind

# 4. 在容器内查看挂载状态
docker exec <container> mount | grep nfs
docker exec <container> df -h

# 5. 常见错误：
# "Permission denied" → 检查 NFS 服务端导出权限
# "Operation not permitted" → 确保容器以特权模式运行(--privileged) 或有 SYS_ADMIN 权限
```

### 2.3 Bind Mount 深入理解

#### 2.3.1 Bind Mount 的实现原理

Bind mount 本质上是 Linux 的 `mount --bind` 操作。Docker daemon 在启动容器时，会在容器的 mount namespace 内执行 `mount --bind` 将宿主机路径挂载到容器内的目标路径。

```bash
# 查看容器在宿主机侧的进程
docker inspect <container> | jq '.[0].State.Pid'

# 通过 /proc 查看该进程看到的挂载信息
cat /proc/<container_pid>/mounts | grep /your/bind/path
```

#### 2.3.2 Bind Mount 的相对路径陷阱

```bash
# 错误示例：使用相对路径
docker run -v ./data:/app/data myapp   # 相对路径在不同版本中行为不一致

# 正确做法：
docker run -v $(pwd)/data:/app/data myapp
# 或者在 Compose 中使用绝对路径
```

#### 2.3.3 Bind Mount 与 SELinux/AppArmor

在开启 SELinux 的系统中（如 CentOS/RHEL），bind mount 通常需要添加 `:z` 或 `:Z` 标签：

```bash
# :z 表示共享标签（多个容器可共享）
docker run -v /host/data:/container/data:z myapp

# :Z 表示私有标签（仅当前容器可用）
docker run -v /host/data:/container/data:Z myapp
```

### 2.4 tmpfs 临时文件系统

```bash
# 纯内存挂载，不写入磁盘
docker run -d --name myapp \
  --tmpfs /tmp:rw,size=128M,mode=1777 \
  nginx

# 查看 tmpfs 挂载
docker inspect myapp | jq '.[0].HostConfig.Tmpfs'
```

---

## 3. overlay2 存储驱动详解

### 3.1 什么是存储驱动（Storage Driver / GraphDriver）

Docker 的存储驱动负责管理容器镜像的分层结构。每一层包含镜像文件系统的变更信息。OverlayFS（overlay2）是 Docker 在 Linux 上默认且推荐的存储驱动。

### 3.2 OverlayFS 原理

OverlayFS 是 Linux 内核提供的联合文件系统。它将多个目录叠加成一个统一的视图。

**核心概念**：

```
            ┌──────────────┐
            │   Merged     │  ← 容器内看到的完整文件系统视图
            │  (统一视图)   │
            └──────┬───────┘
                   │
      ┌────────────┼────────────┐
      │            │            │
┌─────┴─────┐ ┌───┴────┐ ┌────┴─────┐
│  Upperdir │ │ Lower1 │ │  Lower2  │ ...
│ (可写层)   │ │(只读层1)│ │(只读层2) │
└───────────┘ └────────┘ └──────────┘
                    │
              ┌─────┴─────┐
              │   Work    │  ← overlayFS 内部工作目录
              │ (内部使用) │     (用于原子操作)
              └───────────┘
```

### 3.3 overlay2 的目录结构

overlay2 的数据存储在 `/var/lib/docker/overlay2/` 下：

```
/var/lib/docker/overlay2/
├── l/                          ← 缩短链接层目录（符号链接，解决挂载参数长度限制）
│   ├── ABC123... → ../abc123.../diff
│   ├── DEF456... → ../def456.../diff
│   └── ...
├── abc123...                   ← 镜像层或容器层目录
│   ├── diff/                   ← 该层的文件系统变更内容
│   ├── link                    ← 该层的短标识符
│   ├── lower                   ← 该层的下层引用（容器层才有）
│   ├── merged/                 ← 联合挂载点（容器层才有）
│   ├── work/                   ← OverlayFS 内部工作目录（容器层才有）
│   └── committed               ← 标记文件，表示该层已提交
└── backingFsBlockDev           ← 底层文件系统的块设备 UUID
```

### 3.4 各字段和目录的详细含义

#### 3.4.1 `diff/` 目录

这是每一层的核心目录。对于镜像层（image layer），它存储该层对文件系统的**增量变更**（新增、修改或删除的文件）。对于容器层，它存储容器运行后**对文件系统的所有写入操作**（也即容器停止后还能保留的变更）。

```bash
# 查看某个镜像层的 diff 内容
ls /var/lib/docker/overlay2/<layer_id>/diff/
```

如果该镜像层的 Dockerfile 指令是 `COPY app.jar /app/`，那么 `diff/` 目录下就会有 `app/` 目录和 `app.jar` 文件。

#### 3.4.2 `link` 文件

存放该层的短标识符（通常是 26 个字符）。

```bash
cat /var/lib/docker/overlay2/<layer_id>/link
# 输出: ABCDEFGHIJKLMNOPQRSTUVWXYZ  (26字符)
```

这个短标识符用于构造 overlay 挂载时引用该层。因为 overlay mount 的 lowerdir 参数有长度限制（通常是页面大小的 1/4，即 1024 字节），所以需要使用 `l/` 目录下的短符号链接来缩短路径。

#### 3.4.3 `l/` 目录（缩短链接层目录）

解决挂载参数长度限制的关键目录。

```bash
ls -la /var/lib/docker/overlay2/l/ABCDEFGHIJKLMNOPQRSTUVWXYZ
# → 符号链接指向 ../abc123.../diff
```

挂载时使用 `lowerdir=l/AAA:l/BBB:l/CCC` 而不是 `lowerdir=abc123.../diff:def456.../diff:...`，大幅缩短了参数长度。随着镜像层数的增加（一个复杂的镜像可能有 20-30 层），这个优化变得至关重要。

#### 3.4.4 `lower` 文件（仅容器层有）

记录了该容器所使用的所有**只读镜像层**的叠加顺序。

```bash
cat /var/lib/docker/overlay2/<container_layer_id>/lower
# 示例输出:
# l/UVWXYZ:l/RSTUVW:l/OPQRST:l/MNOPQR:l/KLMNOP
```

格式说明：
- 每个以 `l/` 前缀加短标识符的形式表示一个镜像层。
- 顺序是从**最顶层**到**最底层**排列，用 `:` 分隔。
- 最底层是基础镜像（如 `FROM scratch` 或 `FROM alpine`）。
- 每一层向后引用下一层，形成层叠关系。

**与 `docker inspect` 的对应关系**：

```bash
docker inspect <container> | jq '.[0].GraphDriver.Data'
```

输出示例：
```json
{
  "LowerDir": "/var/lib/docker/overlay2/abc123.../diff:/var/lib/docker/overlay2/def456.../diff",
  "MergedDir": "/var/lib/docker/overlay2/xyz789.../merged",
  "UpperDir": "/var/lib/docker/overlay2/xyz789.../diff",
  "WorkDir": "/var/lib/docker/overlay2/xyz789.../work"
}
```

#### 3.4.5 `merged/` 目录（仅容器层有）

这是 OverlayFS 挂载后容器内部看到的**完整文件系统视图**。它是 UpperDir 和所有 LowerDir 的联合视图。

```bash
# 查看容器看到的文件系统
ls /var/lib/docker/overlay2/<container_layer_id>/merged/
# 可以看到完整的操作系统目录结构: bin/ etc/ lib/ usr/ var/ 等

# 也可以直接在宿主机上查看（不建议修改）
cat /var/lib/docker/overlay2/<container_layer_id>/merged/etc/hostname
```

#### 3.4.6 `work/` 目录（仅容器层有）

OverlayFS 内核模块使用的内部工作目录，用于保证 copy-up 等操作的**原子性**。这是一个技术性很强的目录，用户不应直接操作。

用途：当 OverlayFS 需要将一个文件从 lowerdir 复制到 upperdir 时（即 copy-up 操作），它会先在 `work/` 目录中进行文件准备，然后以原子方式移动到 upperdir 的目标位置，保证操作的原子性。

#### 3.4.7 `committed` 文件

一个空的标记文件，表示该层已经完全提交到磁盘，不是处于写入中间状态。在 Docker daemon 启动时会检查此标记，确保数据完整性。

### 3.5 写时复制（CoW - Copy-on-Write）机制

OverlayFS 最核心的功能就是写时复制：

```
步骤1：容器要修改一个文件 /etc/config.conf
步骤2：该文件原存在于 lowerdir（镜像层）中
步骤3：OverlayFS 将该文件从 lowerdir 复制到 upperdir（容器层）
       这个过程称为 "copy-up"
步骤4：容器在 upperdir 中的副本上进行修改
步骤5：merged 视图中看到的是修改后的版本
步骤6：lowerdir 中的原文件保持不变
```

**copy-up 的性能影响**：
- 首次修改一个大文件（如数据库）时，copy-up 需要将整个文件复制到 upperdir，会产生一次性的 I/O 开销。
- 对小文件的修改几乎无感觉。
- **最佳实践**：对于需要频繁写入的目录（如数据库数据目录），应使用 volume 将其排除在 copy-up 机制之外。

**删除操作的白名单机制**：

当容器删除一个只存在于 lowerdir 中的文件时，OverlayFS 会在 upperdir 中创建一个 **whiteout 文件**（字符设备文件，主设备号 0，次设备号 0），表示该文件已被"删除"。在 merged 视图中，该文件将不再出现。

```bash
# 查看 whiteout 文件的特征
ls -la /var/lib/docker/overlay2/<container_layer_id>/diff/some_dir/
# whiteout 文件示例：
# c--------- 1 root root 0, 0 Jan 1 00:00 .wh.somefile
```

### 3.6 磁盘空间分析

#### 3.6.1 查看存储驱动占用

```bash
# 查看 Docker 整体磁盘使用
docker system df
# 输出示例：
# TYPE           TOTAL    ACTIVE    SIZE      RECLAIMABLE
# Images         12       5         2.145GB   1.014GB (47%)
# Containers     8        3         104.2MB   0B (0%)
# Local Volumes  6        4         1.234GB   567MB (45%)

# 详细查看每一层的占用
docker system df -v

# 查看 overlay2 的实际磁盘占用
du -sh /var/lib/docker/overlay2/
```

#### 3.6.2 分析单个容器的磁盘写入

```bash
# 查看容器的可写层大小
docker ps -s
# SIZE 列的第二个值是 writable layer 的大小

# 手动查看
du -sh /var/lib/docker/overlay2/<container_layer_id>/diff/

# 使用脚本分析哪些文件占用了写入层空间
find /var/lib/docker/overlay2/<container_layer_id>/diff/ \
  -type f -exec ls -lh {} \; | sort -k5 -h | tail -20
```

#### 3.6.3 overlay2 磁盘问题排查

**问题一：`/var/lib/docker/overlay2/` 占用过大**

排查思路：

```bash
# 1. 首先识别是镜像占用还是容器写入
docker system df -v

# 2. 如果镜像占用大
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
docker image prune -a  # 清理未使用的镜像

# 3. 如果容器写入占用大
docker ps -s --format "table {{.Names}}\t{{.Size}}"
# 识别写入最大的容器，进入容器分析
docker exec -it <container> du -sh /var/log /tmp /app/logs 2>/dev/null

# 4. 清理已停止的容器和悬空镜像
docker container prune
docker image prune
docker system prune -a --volumes
```

**问题二：overlay2 层数过多导致挂载参数超长**

```bash
# 使用 --max-depth 检查层数
docker history <image> | wc -l

# 解决方案：优化 Dockerfile，减少层数
# 1. 合并 RUN 指令
# RUN apt update && apt install -y pkg1 pkg2 pkg3 && rm -rf /var/lib/apt/lists/*
# 2. 使用多阶段构建（multi-stage build）
# 3. 清理不需要的中间层文件
```

### 3.7 从镜像到容器的完整层叠过程

以启动一个基于 `ubuntu:22.04` 镜像的容器为例：

```
原始镜像层结构:
Layer 5 (top): COPY app /app/        → /var/lib/docker/overlay2/aaaa.../diff/
Layer 4:       RUN apt install nginx → /var/lib/docker/overlay2/bbbb.../diff/
Layer 3:       RUN apt update        → /var/lib/docker/overlay2/cccc.../diff/
Layer 2:       ADD rootfs.tar        → /var/lib/docker/overlay2/dddd.../diff/
Layer 1 (base):FROM scratch           → /var/lib/docker/overlay2/eeee.../diff/  (实际上scratch无目录)

启动容器后新增:
Container Layer: (可写层)            → /var/lib/docker/overlay2/ffff.../diff/
                                     ├── lower: l/AAAA:l/BBBB:l/CCCC:l/DDDD:l/EEEE
                                     ├── merged/   (联合挂载点)
                                     └── work/     (OverlayFS 工作目录)

最终的 OverlayFS 挂载:
mount -t overlay overlay \
  -o lowerdir=l/EEEE:l/DDDD:l/CCCC:l/BBBB:l/AAAA, \
     upperdir=ffff.../diff,workdir=ffff.../work \
  ffff.../merged
```

注意 `lowerdir` 的顺序与 `lower` 文件中的顺序是**相反的**。`lower` 文件中列出的是从上到下的引用链，而挂载参数 `lowerdir` 的是从最底层到最顶层排列（OverlayFS 内核要求）。

---

## 4. Docker Compose 调试方法

### 4.1 Compose 项目的生命周期理解

一个 Compose 项目从定义到运行经历了以下阶段：

```
docker-compose.yml  → 配置解析 → 网络创建 → Volume 创建 → 
服务容器启动（按依赖顺序）→ 健康检查 → 服务可用
```

### 4.2 Compose 配置调试与验证

#### 4.2.1 配置预览与合并

当使用多个 Compose 文件时（通过 `-f` 参数或 `COMPOSE_FILE` 环境变量），Docker 会将多个文件合并。理解合并顺序对于调试至关重要。

```bash
# 预览最终合并后的完整配置（不执行任何操作）
docker compose config

# 只显示有变化的字段
docker compose config --no-normalize

# 查看服务列表
docker compose config --services

# 查看 volumes 列表
docker compose config --volumes

# 输出为 JSON 格式（便于程序解析）
docker compose config --format json
```

**常见配置合并问题**：

```yaml
# base.yml
services:
  web:
    image: nginx
    ports:
      - "80:80"

# override.yml
services:
  web:
    ports:
      - "443:443"
```

合并后 `ports` 会被**完全替换**而非追加，导致 `80:80` 丢失。需要确保在 override 文件中显式包含所有需要的端口。

#### 4.2.2 环境变量调试

Compose 支持多层环境变量来源，优先级从高到低：

1. Shell 环境变量
2. `.env` 文件中的变量
3. `environment` 字段中的硬编码值
4. `env_file` 指定的文件

```bash
# 调试环境变量解析
docker compose run --rm web env
# 这会在容器中执行 env 命令，显示所有容器实际看到的环境变量

# 检查 .env 文件是否被正确加载
docker compose config | grep -i env

# 使用 --dry-run 查看变量替换后的配置
docker compose -f compose.yml --env-file .env.prod config
```

**变量替换的坑**：

```yaml
# 在 compose 文件中使用变量
services:
  web:
    image: "${REGISTRY:-docker.io}/${IMAGE:-nginx}:${TAG:-latest}"

# 如果变量未定义且未设置默认值，docker compose 会报错
# "$REGISTRY/nginx:latest"  -- REGISTRY 未定义，报错停止
# "${REGISTRY:-}/nginx:latest" -- 安全，默认值为空
```

#### 4.2.3 验证 YAML 语法

YAML 的缩进和格式问题是最常见的配置错误来源：

```bash
# 使用 docker compose 内置验证
docker compose config 2>&1 | head -20

# 也可以使用在线 YAML 验证器或本地工具
python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))"
```

**注意**：YAML 中的布尔值陷阱，以下值都会被解析为布尔值而非字符串：

- `yes`, `no`, `true`, `false`, `on`, `off`

```yaml
# 错误：会被解析为布尔值
environment:
  - DEBUG_MODE=no       # 实际值是 False!

# 正确：使用引号
environment:
  - DEBUG_MODE="no"
```

### 4.3 服务启动调试

#### 4.3.1 分步启动策略

```bash
# 不要一次性启动所有服务，而是逐个启动
docker compose up -d service_a
docker compose logs service_a

# 确认 service_a 正常后，再启动下一个
docker compose up -d service_b
docker compose logs service_b
```

#### 4.3.2 依赖关系与健康检查

```yaml
services:
  db:
    image: postgres:15
    environment:
      POSTGRES_PASSWORD: secret
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
      start_period: 10s

  app:
    image: myapp:latest
    depends_on:
      db:
        condition: service_healthy    # 等待 db 健康后再启动
    # 注意：condition: service_healthy 仅在 compose v2.1+/v3+ 的
    # docker compose (v2) 中完全支持
```

**关键理解**：`depends_on` 只控制启动顺序，**不保证**依赖服务已经准备好接受请求。数据库可能需要额外的时间来完成初始化。这就是为什么需要使用 `healthcheck` 和 `condition: service_healthy`。

#### 4.3.3 调试启动失败

```bash
# 1. 查看启动失败的服务
docker compose ps
# STATUS 列显示 Exit 或 Restarting 的服务

# 2. 查看特定服务的退出日志
docker compose logs <service_name> --tail=100

# 3. 查看容器的退出码
docker compose ps -a
docker inspect $(docker compose ps -q <service_name>) | jq '.[0].State.ExitCode'

# 4. 强制重建并启动服务
docker compose up -d --force-recreate <service_name>
# or
docker compose up -d --build --force-recreate
```

### 4.4 网络调试

#### 4.4.1 理解 Compose 网络的默认行为

Compose 默认为每个项目创建一个独立的 bridge 网络。同一个项目中的服务可以通过**服务名**作为主机名互相访问。

```bash
# 查看 Compose 创建的网络
docker network ls
# 输出包含: <project_name>_default

# 查看网络中的容器
docker network inspect <project_name>_default

# 测试容器间的网络连通性
docker compose exec service_a ping service_b
docker compose exec service_a nc -zv service_b 3306
```

#### 4.4.2 多网络调试

```yaml
services:
  frontend:
    networks:
      - frontend_net
      - shared_net

  backend:
    networks:
      - backend_net
      - shared_net

  db:
    networks:
      - backend_net

networks:
  frontend_net:
  backend_net:
    internal: true    # 阻止出站连接
  shared_net:
```

```bash
# 查看每个服务连接的网络
docker compose exec frontend ip addr show
docker compose exec frontend ip route

# 验证网络隔离
docker compose exec backend ping frontend  # 应该失败（不在同一网络）
docker compose exec backend ping db        # 应该成功
```

### 4.5 运行时调试技巧

#### 4.5.1 覆盖启动命令进行调试

```bash
# 如果服务不断重启，可以用 sleep 代替原命令来稳定地调试
docker compose run --rm -p 8080:8080 app sleep 3600

# 或在另一个终端进入该容器
docker compose exec app /bin/bash

# 手动运行原服务命令观察输出
docker compose exec app python app.py
```

#### 4.5.2 使用临时容器进行网络诊断

```bash
# 启动一个临时诊断容器，加入到目标服务的网络
docker compose run --rm \
  --network <project_name>_default \
  alpine sh -c "apk add curl bind-tools netcat-openbsd && sh"

# 或直接使用现有的调试镜像
docker run --rm -it \
  --network <project_name>_default \
  nicolaka/netshoot
```

#### 4.5.3 监控文件变更

```bash
# 监控 Compose 项目的实时日志
docker compose logs -f --tail=50

# 只关注特定服务的日志
docker compose logs -f <service_name>

# 查看资源使用情况
docker compose ps --format "table {{.Name}}\t{{.Status}}"
docker stats $(docker compose ps -q)
```

### 4.6 Compose 常见问题排查清单

#### 问题：`port is already allocated`

```bash
# 1. 找出占用端口的进程
lsof -i :<port>
ss -tlnp | grep :<port>

# 2. 检查是否有残留的容器占用端口
docker ps -a --filter "publish=<port>"
docker compose ps -a

# 3. 检查是否有 docker-proxy 残留进程
ps aux | grep docker-proxy | grep <port>

# 4. 解决方案：清理残留
docker rm -f $(docker ps -aq --filter "publish=<port>")
# 或重启 docker daemon（最后手段）
```

#### 问题：Volume 数据权限导致服务无法启动

```bash
# 常见于数据库容器
docker compose logs db
# 错误: "Permission denied" on /var/lib/postgresql/data

# 1. 查看 volume 属主
docker compose exec db id
docker run --rm -v <volume_name>:/data alpine ls -la /data

# 2. 临时修复：以 root 启动修复权限
docker compose run --rm -u root db chown -R postgres:postgres /var/lib/postgresql/data
```

#### 问题：环境变量中的特殊字符

```bash
# 密码中的特殊字符可能导致问题
# 在 .env 文件中，值不需要引号
DB_PASSWORD=my#pass!word@2024   # 正确

# 在 docker-compose.yml 中
environment:
  - DB_PASSWORD="${DB_PASSWORD}"  # 正确推荐
  - DB_PASSWORD=${DB_PASSWORD}    # 可以但不是最佳实践
```

### 4.7 使用 `docker compose run` 进行交互调试

```bash
# 启动一个服务但覆盖命令
docker compose run --rm app /bin/bash

# 带环境变量和端口映射
docker compose run --rm \
  -e DEBUG=true \
  -p 5000:5000 \
  app python -m pdb app.py

# 不在原服务网络中的调试（完全隔离的临时环境）
docker compose run --rm --no-deps app /bin/sh
```

---

## 5. 容器故障排查方法与分析过程

### 5.1 容器重启策略深度解析

#### 5.1.1 四种重启策略对比

| 策略 | 行为 | 关键参数 | 使用场景 |
|------|------|----------|----------|
| `no` | 从不自动重启（默认） | - | 一次性任务、批处理 |
| `on-failure[:max-retries]` | 仅非零退出码时重启 | 可设置最大重试次数 | 可能因临时问题失败的服务 |
| `always` | 无论退出码，始终重启 | - | 长期运行的服务 |
| `unless-stopped` | 除非显式 `stop`，否则重启 | - | 生产环境服务首选 |

**`always` vs `unless-stopped` 的区别**：

```bash
# always: docker daemon 重启后，也会重启容器
# unless-stopped: docker daemon 重启后，如果之前是 stop 的，不重启

# 验证行为：
docker run -d --restart unless-stopped --name test nginx
docker stop test
systemctl restart docker   # 重启 daemon
docker ps -a | grep test   # test 不会自动启动

# 而用 --restart always：
docker run -d --restart always --name test2 nginx
docker stop test2
systemctl restart docker
docker ps -a | grep test2  # test2 会自动启动
```

#### 5.1.2 重启策略的底层实现

Docker daemon 使用指数退避算法来控制重启节奏：

```
第 1 次重启：间隔 100ms
第 2 次重启：间隔 200ms
第 3 次重启：间隔 400ms
第 n 次重启：间隔 min(100ms * 2^(n-1), 60s)
最大间隔：60 秒
重置：容器稳定运行超过 10 秒后重置计数器
```

#### 5.1.3 监控容器重启

```bash
# 查看容器的重启次数
docker inspect <container> | jq '.[0].RestartCount'

# 查看重启策略
docker inspect <container> | jq '.[0].HostConfig.RestartPolicy'
# 输出: {"Name": "always", "MaximumRetryCount": 0}

# 实时监控重启事件
docker events --filter type=container --filter event=restart --filter event=die

# 查看重启历史（通过状态字段）
docker ps -a --format "{{.Names}}\t{{.Status}}"
# Status 中包含类似: "Restarting (1) 2 minutes ago"
# 数字 (1) 表示以退出码 1 退出后重启
```

### 5.2 容器退出码分析

退出码是排查容器故障的第一线索：

| 退出码 | 含义 | 常见原因 |
|--------|------|----------|
| 0 | 正常退出 | 主进程正常结束、脚本执行完毕 |
| 1 | 通用错误 | 应用自身报错退出、配置错误 |
| 2 | 误用 shell 命令 | 语法错误、命令参数错误 |
| 125 | docker daemon 错误 | `docker run` 自身失败 |
| 126 | 命令无法执行 | 文件没有执行权限 |
| 127 | 命令未找到 | 镜像中缺少依赖程序 |
| 128+n | 被信号 n 终止 | 例如 137 (SIGKILL)、139 (SIGSEGV) |
| 137 | SIGKILL 终止 | OOM Killer 杀死、手动 `docker kill`、资源限制 |
| 139 | SIGSEGV 段错误 | 程序内存访问错误 |
| 143 | SIGTERM 终止 | `docker stop` 或应用接收到终止信号 |

#### 5.2.1 退出码 137 深度分析（最关键的退出码）

```bash
# 分析步骤：

# 1. 确认容器是否被 OOM Killer 杀死
dmesg | grep -i "out of memory" | grep <container_pid>
dmesg | grep -i oom

# 2. 检查容器的 OOM 状态
docker inspect <container> | jq '.[0].State.OOMKilled'
# 如果为 true，说明是被 OOM 杀死的

# 3. 查看容器当时的内存使用
journalctl -u docker -f --since "5 min ago" | grep -i oom

# 4. 使用 cgroup 事件监控
# Docker daemon 会在容器 OOM 时记录事件
docker events --filter type=container --filter container=<container_name> --filter event=oom
```

**OOM 问题的解决路径**：

```
发现 OOM → 分析内存使用模式 → 确定是内存泄漏还是资源不足 →
  如果是泄漏：修复应用代码 → 如果是资源不足：增加内存限制或优化应用
```

```bash
# 查看容器内存使用趋势
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"

# 查看容器的内存限制
docker inspect <container> | jq '.[0].HostConfig.Memory'
# 0 表示无限制（使用宿主机全部内存）

# 设置合理的内存限制
docker run -d --memory=512M --memory-swap=1G --name myapp myimage

# 设置 OOM 优先级（-1000~1000，越小越不容易被杀）
docker run -d --memory=512M --oom-score-adj=-500 --name myapp myimage

# 禁用 OOM Killer（危险，容器会挂起）
docker run -d --memory=512M --oom-kill-disable --name myapp myimage
```

### 5.3 容器资源限制与 cgroup 分析

#### 5.3.1 理解 cgroup v1/v2

```bash
# 检查系统使用的是 cgroup v1 还是 v2
stat -fc %T /sys/fs/cgroup
# cgroup2fs → v2, cgroup → v1 (tmpfs)

# 找到容器对应的 cgroup 路径
docker inspect <container> | jq '.[0].HostConfig.CgroupParent'

# cgroup v1 中容器的资源控制目录
# /sys/fs/cgroup/memory/docker/<container_id>/
# /sys/fs/cgroup/cpu/docker/<container_id>/
# /sys/fs/cgroup/blkio/docker/<container_id>/
```

#### 5.3.2 资源限制实战

```bash
# CPU 限制
docker run -d --cpus=1.5 --name myapp myimage
# 等价于 --cpu-period=100000 --cpu-quota=150000

# 查看容器实际使用的 CPU
cat /sys/fs/cgroup/cpu/docker/<container_id>/cpuacct.usage
docker stats --no-stream myapp

# 内存限制
docker run -d --memory=256M --memory-reservation=192M --name myapp myimage
# --memory: 硬限制
# --memory-reservation: 软限制（仅在宿主机内存紧张时生效）

# 查看内存的详细使用情况
cat /sys/fs/cgroup/memory/docker/<container_id>/memory.stat
cat /sys/fs/cgroup/memory/docker/<container_id>/memory.usage_in_bytes
cat /sys/fs/cgroup/memory/docker/<container_id>/memory.limit_in_bytes
```

### 5.4 容器无法启动的系统排查方法

#### 5.4.1 标准排查流程（SOP）

```
第一步：收集信息
  ├── docker ps -a（查看所有容器状态）
  ├── docker logs <container> --tail 100（查看退出前日志）
  ├── docker inspect <container>（查看完整配置和状态）
  └── journalctl -u docker -n 50（查看 dockerd 日志）

第二步：分类分析
  ├── 状态为 "Exited" → 分析退出码和应用日志
  ├── 状态为 "Created" → 分析为什么没启动（资源不足？）
  ├── 状态为 "Restarting" → 应用不断崩溃，分析循环重启原因
  └── 状态为 "Dead" → 容器被强制移除，重启策略判断

第三步：深入排查
  ├── 尝试重新启动并观察
  ├── 进入容器内部排查
  ├── 检查资源限制
  └── 检查依赖服务
```

#### 5.4.2 Exited(1) 排查实战

```bash
# 场景：容器启动后立即退出
docker ps -a
# STATUS: "Exited (1) 5 seconds ago"

# 1. 查看退出日志
docker logs <container> --tail 50
# 输出："Error: could not connect to database at db:5432"

# 2. 确认退出码含义
docker inspect <container> | jq '.[0].State.ExitCode'
# 1

# 3. 如果是依赖问题，手动测试依赖
docker run --rm --network <network> busybox nc -vz db 5432

# 4. 如果问题在于数据库启动慢，添加重试机制或 healthcheck 依赖：
# depends_on condition: service_healthy
```

#### 5.4.3 "Created" 状态排查

```bash
# 容器处于 Created 状态表示 docker create 成功但从未启动

# 1. 查看容器创建原因
docker inspect <container> | jq '.[0].Created'
docker inspect <container> | jq '.[0].State.StartedAt'

# 2. 尝试手动启动并观察
docker start -a <container>
# -a 表示附加到 stdout/stderr，可以看到输出

# 3. 常见原因：
#    - docker-compose 创建的容器，但 up 被中断
#    - 脚本中使用了 docker create 而非 docker run
#    - 资源不足导致无法启动
```

#### 5.4.4 "Restarting" 循环重启排查

这是最棘手的场景之一，容器处于 "不断崩溃→重启→再崩溃" 的循环中。

```bash
# 1. 停止重启循环
docker stop <container>

# 2. 保留环境但临时改变行为进行诊断
# 创建一个不可重启的副本进行分析
docker commit <container> debug-image
docker run --rm -it debug-image /bin/bash

# 3. 分析崩溃前的日志
docker logs <container> --tail 200 | less
# 关注最后的几行输出

# 4. 分析崩溃模式
docker inspect <container> | jq '.[0].State'
# 查看 FinishedAt 的时间戳模式，判断是以固定间隔还是随机崩溃

# 5. 检查是否有健康检查导致的重启
docker inspect <container> | jq '.[0].Config.Healthcheck'
# 如果健康检查失败，某些编排工具（如 swarm）会重启容器
```

### 5.5 容器内文件系统与进程问题排查

#### 5.5.1 PID 1 问题

容器中的主进程（PID 1）与普通 Linux 进程有显著不同：

- PID 1 负责接管孤儿进程（即需要处理 SIGCHLD 信号）。
- PID 1 不会被默认的信号（如 SIGTERM）杀死（需要显式处理）。
- 如果主进程不处理或转发信号，`docker stop` 会等待超时后发送 SIGKILL。

```bash
# 检查容器的主进程
docker top <container>
docker exec <container> ps aux

# 常见的 PID 1 问题：
# 1. Shell 脚本作为 PID 1（不转发信号，导致优雅关闭失效）
# 2. init 系统缺失（孤儿进程不会被回收，导致僵尸进程）
# 3. 信号处理缺失（docker stop 超时后被 SIGKILL）

# 解决方案：
# 使用 tini 作为 init（--init 参数）
docker run --init --name myapp myimage

# 或在 Dockerfile 中使用 tini/dumb-init
# ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/myapp"]

# 或在 Dockerfile 中使用 exec 形式确保信号转发
# CMD ["exec", "myapp"]  # 错误，exec 不是单独的命令
# CMD ["myapp"]          # 正确，exec 形式确保 myapp 成为 PID 1
# 不要用: CMD myapp      # shell 形式，sh 是 PID 1
```

#### 5.5.2 僵尸进程问题排查

```bash
# 检测僵尸进程
docker exec <container> ps aux | grep -w Z
docker exec <container> cat /proc/loadavg

# 僵尸进程产生的原因：
# 父进程未回收子进程的退出状态（没有调用 waitpid）

# 解决方案：
# 1. 使用 --init 启动容器（tini 会自动回收孤儿/僵尸进程）
# 2. 在应用中正确处理子进程退出信号
# 3. 如果是多进程应用，考虑使用 supervisor/s6 等进程管理
```

### 5.6 信号处理与优雅关闭

#### 5.6.1 Docker stop 的执行流程

```
docker stop <container>
  → 1. 发送 SIGTERM 给容器内 PID 1
  → 2. 等待默认 10 秒 (可配置 --time/-t)
  → 3. 如果容器未退出，发送 SIGKILL 强制终止
```

```bash
# 自定义优雅关闭超时
docker stop -t 30 <container>   # 等待 30 秒

# 在 Compose 中配置
# stop_grace_period: 30s

# 验证应用是否正确处理 SIGTERM
docker exec <container> kill -TERM 1
# 如果容器退出，说明 PID 1 正确处理了信号
docker exec <container> kill -TERM $(docker exec <container> pgrep myapp)
# 如果主进程不是 PID 1，检查实际进程的信号处理
```

#### 5.6.2 应用层面的信号处理要求

应用需要做好的事情：
1. 捕获 SIGTERM 信号
2. 停止接收新请求
3. 完成进行中的请求
4. 关闭数据库连接和文件句柄
5. 释放资源后退出

```bash
# 排查应用是否因信号问题被 SIGKILL 强杀
docker logs <container>
# 如果日志突然中断，没有 "shutting down" 之类的信息
# 很可能是被 SIGKILL 强杀

# 查看容器被 kill 的时间线
docker events --since 10m --filter container=<container> --filter event=kill
docker events --since 10m --filter container=<container> --filter event=die

# 调整优雅关闭时间
docker inspect <container> | jq '.[0].Config.StopTimeout'
```

### 5.7 生产环境故障排查综合案例

#### 5.7.1 案例一：应用响应超时，容器频繁重启

**现象**：
- `docker ps` 显示容器 STATUS 是 "Restarting (1) 10 seconds ago"
- 重启计数不断增加
- 服务不可用

**排查过程**：

```bash
# Step 1: 收集基础信息
docker ps -a --filter "status=restarting"
docker inspect <container> | jq '.State'

# Step 2: 查看日志，分析退出模式
docker logs --tail 200 <container>
# 发现日志在某个数据库查询后中断

# Step 3: 检查资源限制
docker stats --no-stream <container>
# 发现内存使用接近限制值（--memory 设置）

# Step 4: 检查是否有 OOM 事件
dmesg | grep -i oom | tail -10
docker inspect <container> | jq '.State.OOMKilled'
# 确认为 false → 不是 OOM 导致的

# Step 5: 深入应用日志
docker logs <container> 2>&1 | grep -i "error\|timeout\|exception"
# 发现: "read tcp 192.168.1.10:5432: i/o timeout"

# Step 6: 网络连通性排查
docker exec <container> nc -vz db 5432   # 如果容器允许 exec
# 在防火墙上找到问题：安全组规则阻止了此端口

# 总结：网络不可达 → 应用连接超时 → 应用退出(1) → restart策略触发 → 循环重启
```

#### 5.7.2 案例二：磁盘写满导致容器异常

**现象**：
- 所有容器突然出现各种异常
- `docker logs` 报 "no space left on device"
- 部分容器退出或无法正常写入

**排查过程**：

```bash
# Step 1: 确认磁盘空间
df -h
# 发现 /var/lib/docker 所在分区使用率 100%

# Step 2: 定位是哪个目录占满了
du -sh /var/lib/docker/*
# 发现 /var/lib/docker/overlay2/ 占用最大

# Step 3: 查看 Docker 空间占用分布
docker system df -v
# 找到占用最多的镜像和容器

# Step 4: 定位哪个容器的写入层过大
docker ps -s --format "table {{.Names}}\t{{.Size}}"
# 发现某个容器的 writable layer 异常大

# Step 5: 进入容器层目录查看
CONTAINER_LAYER_ID=$(docker inspect <container> | jq -r '.[0].GraphDriver.Data.UpperDir')
du -sh ${CONTAINER_LAYER_ID}/*
# 发现 /app/logs 下存在巨量日志文件

# Step 6: 根本原因分析
# 应用日志未配置轮转，日志文件无限增长
# 配置 logrotate 或将 /app/logs 映射到 volume 并配置定期清理

# Step 7: 应急清理
# 删除悬空的镜像和未使用的资源
docker system prune -a --volumes --force

# 清理不需要的日志
echo "" > ${CONTAINER_LAYER_ID}/app/logs/app.log
```

#### 5.7.3 案例三：网络延迟导致应用间通信问题

**现象**：
- 微服务间偶发超时
- 监控显示 P99 延迟异常升高
- 部分请求返回 502/504

**排查过程**：

```bash
# Step 1: 确认网络模式
docker network inspect <network_name>
# 确认是 bridge 模式

# Step 2: 检查 conntrack 表使用情况
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max
# 发现 count 接近 max，conntrack 表即将满

# Step 3: 分析 conntrack 表内容
conntrack -L | wc -l
conntrack -L -p tcp --state TIME_WAIT | wc -l

# Step 4: 查看 docker-proxy 进程
ps aux | grep docker-proxy | wc -l
# 如果有大量端口映射，docker-proxy 可能成为瓶颈

# Step 5: 调整 docker daemon 配置
# /etc/docker/daemon.json
{
  "userland-proxy": false,      # 禁用 userland proxy，使用纯 iptables
  "dns": ["8.8.8.8", "1.1.1.1"],
  "dns-opts": ["ndots:1"]
}

# Step 6: 放大 conntrack 表
echo "net.netfilter.nf_conntrack_max=262144" >> /etc/sysctl.conf
sysctl -p

# Step 7: 调整 TCP 超时参数减少 TIME_WAIT 连接
echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait=30" >> /etc/sysctl.conf
```

### 5.8 故障排查工具箱汇总

#### 5.8.1 宿主机侧工具

| 工具 | 用途 | 常用命令 |
|------|------|----------|
| `dmesg` | 内核日志 | `dmesg \| grep -i oom` |
| `strace` | 系统调用追踪 | `strace -p <pid> -f -e trace=network` |
| `lsof` | 打开文件/端口 | `lsof -i :80` |
| `ss` | Socket 统计 | `ss -tlnp` |
| `tcpdump` | 网络抓包 | `tcpdump -i docker0 -nn port 80` |
| `iptables` | 防火墙规则 | `iptables -t nat -L -n -v` |
| `nsenter` | 进入 namespace | `nsenter -t <pid> -n ip addr` |
| `perf` | 性能分析 | `perf top -p <pid>` |

#### 5.8.2 容器内工具镜像

```bash
# nicolaka/netshoot: 全功能网络诊断工具
docker run --rm -it --network container:<target_container> nicolaka/netshoot

# 包含的工具：
# iperf, iperf3   - 网络带宽测试
# tcpdump         - 抓包
# nmap            - 端口扫描
# curl, wget      - HTTP 测试
# dig, nslookup   - DNS 测试
# mtr             - 路由追踪
# iftop           - 实时流量监控
# ngrep           - 网络内容过滤
# socat           - 网络管道工具
```

#### 5.8.3 排查流程图

```
容器异常
  │
  ├─ 退出/重启 → docker logs → 查看退出信息
  │    ├─ Exit(0)    → 正常退出，检查业务逻辑
  │    ├─ Exit(1-255)→ 应用错误，分析日志
  │    ├─ Exit(137)  → OOM/SIGKILL，检查内存
  │    └─ Exit(139)  → SIGSEGV，检查代码 bug
  │
  ├─ 无法访问 → 网络排查路径
  │    ├─ 端口映射 → iptables 规则检查
  │    ├─ 容器间通信 → network 模式检查
  │    └─ DNS 解析 → resolv.conf 和嵌入式 DNS 检查
  │
  ├─ 响应慢 → 资源排查路径
  │    ├─ CPU 受限 → cgroup CPU 限制检查 + docker stats
  │    ├─ 内存不足 → OOM 事件 + 内存使用趋势
  │    ├─ 磁盘 I/O → blkio cgroup + iostat
  │    └─ 网络延迟 → conntrack + tcpdump + iperf
  │
  └─ 数据异常 → 存储排查路径
       ├─ Volume 权限 → ls -la + chown
       ├─ Volume 数据丢失 → 备份恢复
       └─ 磁盘写满 → overlay2 分析 + system prune
```

### 5.9 Docker daemon 故障排查

#### 5.9.1 Docker daemon 无法启动

```bash
# 1. 查看 daemon 日志
journalctl -u docker -n 100 --no-pager
systemctl status docker

# 2. 手动启动 daemon 查看详细错误
dockerd --debug

# 3. 常见原因：
# a) /etc/docker/daemon.json 语法错误
python3 -c "import json; json.load(open('/etc/docker/daemon.json'))"

# b) 存储驱动问题
ls -la /var/lib/docker/
# 检查 overlay2 是否可用
grep overlay /proc/filesystems

# c) 端口冲突（dockerd 默认监听 2375/2376）
ss -tlnp | grep 237[56]

# d) containerd 子进程问题
systemctl status containerd
journalctl -u containerd -n 50

# 4. 重置方案（注意：会丢失所有容器和镜像数据）
# systemctl stop docker
# rm -rf /var/lib/docker
# systemctl start docker
```

#### 5.9.2 Docker daemon 配置最佳实践

```json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  },
  "live-restore": true,
  "userland-proxy": false,
  "dns": ["8.8.8.8", "1.1.1.1"],
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5,
  "registry-mirrors": ["https://mirror.example.com"]
}
```

**关键配置项说明**：

| 配置项 | 含义 | 建议值 |
|--------|------|--------|
| `cgroupdriver` | cgroup 管理器 | `systemd`（与 kubelet 保持一致） |
| `log-opts.max-size` | 单个容器日志文件最大大小 | `10m` ~ `100m` |
| `log-opts.max-file` | 最多保留的日志文件数 | `3` |
| `live-restore` | daemon 重启时保持容器运行 | `true`（生产环境关键） |
| `userland-proxy` | 是否使用 docker-proxy 进程 | `false`（纯 iptables 更高效） |

### 5.10 总结：容器排错思维模型

排错不仅仅是执行命令，更重要的是建立**系统化的思维模型**：

#### 5.10.1 分层排查模型（从外到内）

```
第 0 层：宿主机层
  → 磁盘空间、内存、CPU、内核参数、iptables 规则

第 1 层：Docker Daemon 层
  → daemon 日志、配置、containerd 状态、graphdriver

第 2 层：容器运行时层
  → 容器状态、重启策略、退出码、资源限制(cgroup)

第 3 层：容器内应用层
  → 应用日志、进程状态、端口监听、配置环境变量

第 4 层：应用业务层
  → 业务逻辑、数据库连接、外部依赖、API 调用
```

#### 5.10.2 变更关联分析

**黄金法则**：大部分故障都是在某次变更后出现的。

常见的变更触发点：
- 镜像更新（新版本）
- 配置变更（环境变量、Compose 文件）
- 基础设施变更（网络、存储、安全组）
- 依赖服务变更（数据库升级、API 接口变更）
- 流量变化（突发高并发）

```bash
# 快速确认最晚变更时间
docker images --format "{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}" | sort -r | head -5
docker ps -a --format "{{.CreatedAt}}\t{{.Names}}\t{{.Status}}" | sort -r | head -10
```

#### 5.10.3 最小化复现原则

当无法在生产环境直接调试时，尽量在隔离环境中复现问题：

```bash
# 1. 使用相同的镜像和配置
docker inspect <problem_container> | jq '.[0].Config' > config.json
docker inspect <problem_container> | jq '.[0].HostConfig' > hostconfig.json

# 2. 创建隔离的环境
docker compose -f docker-compose.debug.yml up

# 3. 逐步添加组件，定位故障点
# 先只启动核心服务 → 再加入依赖 → 最后添加外围服务
```

---

## 附录 A：常用排查命令速查表

### 容器状态速查

```bash
# 所有容器状态概览
docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

# 按状态过滤
docker ps -a --filter "status=running"
docker ps -a --filter "status=exited"
docker ps -a --filter "status=restarting"
docker ps -a --filter "status=created"
docker ps -a --filter "status=paused"

# 按退出码过滤
docker ps -a --filter "exited=137"
docker ps -a --filter "exited=1"

# 按名称过滤
docker ps -a --filter "name=myapp"
```

### 资源使用速查

```bash
# 实时监控所有容器资源
docker stats

# 单次快照
docker stats --no-stream

# 格式化输出重点
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"

# 容器写入层大小排行
docker ps -s --format "table {{.Names}}\t{{.Size}}" | sort -k2 -h -r
```

### 事件监控速查

```bash
# 实时监控所有事件
docker events

# 按类型过滤
docker events --filter type=container
docker events --filter type=network
docker events --filter type=volume

# 按事件过滤
docker events --filter event=start
docker events --filter event=die
docker events --filter event=stop
docker events --filter event=kill
docker events --filter event=oom
docker events --filter event=restart
docker events --filter event=health_status

# 按容器过滤
docker events --filter container=<container_name>

# 组合过滤
docker events --filter type=container --filter event=die --filter event=oom
```

## 附录 B：Docker 关键目录速查

| 路径 | 用途 | 关键信息 |
|------|------|----------|
| `/var/lib/docker/` | Docker 数据根目录 | 可通过 `daemon.json` 的 `data-root` 修改 |
| `/var/lib/docker/containers/` | 容器元数据 | 每个容器一个目录，包含 config.v2.json、hostconfig.json |
| `/var/lib/docker/overlay2/` | overlay2 存储驱动 | 镜像层和容器层的文件系统 |
| `/var/lib/docker/volumes/` | Volume 数据 | 每个 volume 一个目录，数据在 `_data/` 下 |
| `/var/lib/docker/image/` | 镜像元数据 | 包含镜像的 layers 信息 |
| `/var/lib/docker/network/` | 网络状态 | 网络配置的持久化文件 |
| `/var/run/docker.sock` | Docker API Socket | 所有 Docker 操作的入口 |
| `/etc/docker/daemon.json` | Docker daemon 配置 | 重启 daemon 后生效 |
| `/etc/docker/key.json` | TLS 密钥 | 用于 Docker Registry 认证 |

## 附录 C：培训建议时间分配

| 章节 | 建议时长 | 重点内容 |
|------|----------|----------|
| Docker 网络深度解析 | 35 分钟 | 网络模型、iptables 关联、DNS 原理、排查案例 |
| Docker 存储卷 | 25 分钟 | Volume 类型对比、权限问题、备份恢复 |
| overlay2 存储驱动 | 30 分钟 | 目录结构、字段含义、CoW 机制、磁盘分析 |
| Compose 调试方法 | 25 分钟 | 配置调试、健康检查、网络调试、常见问题 |
| 容器故障排查 | 35 分钟 | 重启策略、退出码分析、OOM、综合案例 |
| **合计** | **约 150 分钟** | 建议穿插实操演示和互动讨论 |

---

> **结语**：容器排错不是靠记住某几个命令，而是建立对容器运行时的深入理解。网络层要知道 iptables 规则流，存储层要知道 OverlayFS 的 CoW 机制，应用层要知道信号处理和 PID 1 的特殊性。当你把这三层融会贯通时，任何容器问题都能用系统化的方法快速定位和解决。