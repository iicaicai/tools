# Docker 高级技术培训文档

> **培训目标**：帮助基础技术人员深入理解 Docker 底层原理，掌握容器网络、存储、故障排查等高级技能
> 
> **培训时长**：约 2-2.5 小时
> 
> **前置要求**：已掌握 Docker 基础命令（run、start、stop、logs、exec 等）

---

## 目录

1. [Docker 网络深度解析](#1-docker-网络深度解析)
2. [Docker 存储卷详解](#2-docker-存储卷详解)
3. [Overlay2 存储驱动原理](#3-overlay2-存储驱动原理)
4. [Docker Compose 调试方法](#4-docker-compose-调试方法)
5. [容器故障排查与分析方法](#5-容器故障排查与分析方法)

---

## 1. Docker 网络深度解析

### 1.1 Docker 网络架构概览

Docker 网络基于 Linux 内核的网络命名空间（Network Namespace）和虚拟网络设备（veth pair、bridge 等）实现。理解这些底层概念是排查网络问题的基础。

```
┌─────────────────────────────────────────────────────────────┐
│                      Host Network Stack                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Docker0 (Bridge)                        │   │
│  │         172.17.0.1/16                               │   │
│  └───────────────┬─────────────────────────────────────┘   │
│                  │                                          │
│    ┌─────────────┼─────────────┐                           │
│    │             │             │                           │
│  veth0        veth1        veth2                           │
│    │             │             │                           │
│  ┌─┴─┐        ┌─┴─┐        ┌─┴─┐                          │
│  │NS1│        │NS2│        │NS3│  ← Network Namespaces    │
│  │eth│        │eth│        │eth│                          │
│  └─┬─┘        └─┬─┘        └─┬─┘                          │
│  Container1   Container2  Container3                       │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 网络模式详解

#### 1.2.1 Bridge 模式（默认）

**工作原理**：
- Docker 守护进程启动时创建 `docker0` 网桥（默认 172.17.0.1/16）
- 每个容器创建时，Docker 创建一对 veth 设备（虚拟以太网对）
- veth 一端在容器内作为 eth0，另一端连接到 docker0 网桥
- 容器通过网桥进行通信，外部访问通过 NAT 转换

**关键配置查看**：
```bash
# 查看 docker0 网桥详情
ip addr show docker0

# 查看网桥上的连接
brctl show docker0

# 查看 NAT 规则
iptables -t nat -L -n -v | grep DOCKER

# 查看容器的网络命名空间
ls /var/run/docker/netns/

# 进入容器的网络命名空间
nsenter --net=/var/run/docker/netns/<namespace-id> ip addr
```

**容器间通信流程**：
1. Container A (172.17.0.2) 发送数据到 Container B (172.17.0.3)
2. 数据包从容器的 eth0 发出，通过 veth pair 到达 docker0 网桥
3. 网桥根据 MAC 地址表转发到目标容器的 veth 设备
4. 数据包通过 veth pair 进入 Container B 的 eth0

**自定义 Bridge 网络**：
```bash
# 创建自定义桥接网络
docker network create \
  --driver bridge \
  --subnet 192.168.10.0/24 \
  --gateway 192.168.10.1 \
  --opt "com.docker.network.bridge.name"="br-custom" \
  my-bridge-network

# 查看网络详情
docker network inspect my-bridge-network

# 使用自定义网络运行容器
docker run -d --name web --network my-bridge-network nginx
```

**自定义网络的优势**：
- 容器间可通过容器名直接通信（内置 DNS 解析）
- 更好的网络隔离
- 支持网络范围的配置（MTU、IP 范围等）

#### 1.2.2 Host 模式

**工作原理**：
- 容器直接使用宿主机的网络命名空间
- 容器没有独立的 IP 地址，使用宿主机的网络接口
- 端口映射不生效（-p 参数无效）

**使用场景**：
- 需要高性能网络（避免 NAT 开销）
- 需要访问宿主机特殊网络接口
- 网络调试和监控工具

```bash
# 使用 host 模式运行
docker run -d --network host nginx

# 查看容器网络配置（与宿主机一致）
docker exec <container> ip addr
```

**注意事项**：
- 端口冲突风险：多个 host 模式容器不能监听同一端口
- 安全性降低：容器可直接访问宿主机网络

#### 1.2.3 Overlay 模式

**工作原理**：
- 基于 VXLAN（Virtual Extensible LAN）技术实现跨主机通信
- 在底层物理网络之上构建虚拟的二层网络
- 使用 UDP 4789 端口封装二层以太网帧

**VXLAN 数据包结构**：
```
┌─────────────────────────────────────────────────────────────┐
│  Outer Ethernet Header (14 bytes)                           │
│  Outer IP Header (20 bytes) - Src/Dest Host IP              │
│  Outer UDP Header (8 bytes) - Port 4789                     │
│  VXLAN Header (8 bytes) - VNI (VXLAN Network Identifier)    │
│  Inner Ethernet Header (14 bytes)                           │
│  Inner IP Header (20 bytes) - Container IP                  │
│  Payload                                                      │
└─────────────────────────────────────────────────────────────┘
```

**Overlay 网络创建**（Swarm 模式）：
```bash
# 初始化 Swarm
docker swarm init --advertise-addr <manager-ip>

# 创建 Overlay 网络
docker network create \
  --driver overlay \
  --subnet 10.0.9.0/24 \
  --attachable \
  my-overlay-network

# 查看网络详情
docker network inspect my-overlay-network
```

**关键概念**：
- **VNI (VXLAN Network Identifier)**：24 位标识符，区分不同虚拟网络
- **Overlay 网络需要 KV 存储**：用于节点间状态同步（Swarm 使用 Raft）
- **加密选项**：`--opt encrypted` 启用 IPsec 加密

**故障排查命令**：
```bash
# 查看 VXLAN 接口
ip -d link show vxlan-

# 查看邻居表（ARP/NDP 缓存）
docker run --net my-overlay-network alpine ip neigh

# 查看 Overlay 网络的沙盒信息
docker network inspect -v my-overlay-network
```

#### 1.2.4 Macvlan 模式

**工作原理**：
- 为容器分配独立的 MAC 地址
- 容器直接连接到物理网络，像物理设备一样
- 绕过 Linux 网桥，性能更高

**使用场景**：
- 遗留应用需要直接连接到物理网络
- 需要容器有独立 IP 和 MAC 地址
- 监控设备、网络设备等特殊场景

**Macvlan 模式类型**：

| 模式 | 说明 |
|------|------|
| bridge | 默认模式，容器间可以通信 |
| 802.1q | 支持 VLAN 标签，可创建多个子接口 |
| private | 容器间不能通信，只能与外部通信 |
| vepa | 需要外部交换机支持 VEPA 模式 |
| passthru | 直通模式，容器独占物理网卡 |

```bash
# 创建 Macvlan 网络
docker network create -d macvlan \
  --subnet 192.168.1.0/24 \
  --gateway 192.168.1.1 \
  -o parent=eth0 \
  my-macvlan-net

# 创建 802.1q Macvlan（VLAN 10）
docker network create -d macvlan \
  --subnet 192.168.10.0/24 \
  --gateway 192.168.10.1 \
  -o parent=eth0.10 \
  my-vlan10-net
```

**注意事项**：
- 宿主机通常无法直接与 Macvlan 容器通信（需要特殊配置）
- 需要物理交换机支持混杂模式或端口安全策略调整

#### 1.2.5 IPvlan 模式

**与 Macvlan 的区别**：
- Macvlan：每个容器有独立 MAC 地址
- IPvlan：所有容器共享宿主机 MAC 地址，只有 IP 不同

**优势**：
- 避免 MAC 地址表膨胀（交换机限制）
- 更适合大规模部署

```bash
# 创建 IPvlan L2 模式
docker network create -d ipvlan \
  --subnet 192.168.1.0/24 \
  --gateway 192.168.1.1 \
  -o parent=eth0 \
  -o ipvlan_mode=l2 \
  my-ipvlan-net

# 创建 IPvlan L3 模式（路由模式）
docker network create -d ipvlan \
  --subnet 192.168.30.0/24 \
  -o parent=eth0 \
  -o ipvlan_mode=l3 \
  my-ipvlan-l3
```

### 1.3 网络故障排查实战

#### 1.3.1 容器无法访问外部网络

**排查步骤**：

```bash
# 1. 检查容器网络配置
docker exec <container> ip addr
docker exec <container> ip route

# 2. 检查 DNS 解析
docker exec <container> cat /etc/resolv.conf
docker exec <container> nslookup baidu.com

# 3. 检查宿主机转发设置
sysctl net.ipv4.ip_forward

# 4. 检查 iptables NAT 规则
iptables -t nat -L POSTROUTING -v -n

# 5. 检查 docker0 网桥状态
ip addr show docker0
brctl show docker0

# 6. 抓包分析
docker exec <container> ping -c 3 8.8.8.8
tcpdump -i docker0 -n icmp
```

**常见问题**：
- `net.ipv4.ip_forward = 0`：启用 IP 转发
- iptables 规则被清空：重启 Docker 或手动添加规则
- DNS 配置错误：检查 `/etc/docker/daemon.json` 的 dns 配置

#### 1.3.2 容器间无法通信

**排查步骤**：

```bash
# 1. 确认容器在同一网络
docker inspect <container1> --format='{{range $key, $value := .NetworkSettings.Networks}}{{$key}} {{end}}'
docker inspect <container2> --format='{{range $key, $value := .NetworkSettings.Networks}}{{$key}} {{end}}'

# 2. 检查容器 IP 地址
docker inspect <container1> --format='{{.NetworkSettings.IPAddress}}'
docker inspect <container2> --format='{{.NetworkSettings.IPAddress}}'

# 3. 测试连通性
docker exec <container1> ping <container2-ip>

# 4. 检查防火墙规则
iptables -L FORWARD -v -n

# 5. 检查 ICC（Inter-Container Communication）设置
cat /etc/docker/daemon.json | grep icc
```

#### 1.3.3 端口映射不生效

**排查步骤**：

```bash
# 1. 检查端口映射配置
docker port <container>
docker inspect <container> --format='{{json .NetworkSettings.Ports}}'

# 2. 检查服务是否在监听 0.0.0.0
docker exec <container> netstat -tlnp
# 或
docker exec <container> ss -tlnp

# 3. 检查 iptables NAT 规则
iptables -t nat -L DOCKER -v -n

# 4. 检查服务是否正常运行
docker exec <container> curl localhost:<port>

# 5. 从宿主机测试
curl localhost:<mapped-port>
```

**常见问题**：
- 应用只监听 127.0.0.1：修改应用配置监听 0.0.0.0
- 防火墙阻止：检查 `iptables -L INPUT`

### 1.4 网络命名空间操作

```bash
# 查看所有网络命名空间
ls /var/run/docker/netns/

# 使用 nsenter 进入网络命名空间
nsenter --net=/var/run/docker/netns/<id> ip addr

# 使用 ip netns（需要创建符号链接）
ln -s /var/run/docker/netns/<id> /var/run/netns/<name>
ip netns exec <name> ip addr

# 在网络命名空间中抓包
nsenter --net=/var/run/docker/netns/<id> tcpdump -i any -w /tmp/capture.pcap
```

---

## 2. Docker 存储卷详解

### 2.1 容器存储原理

Docker 容器使用联合文件系统（UnionFS）实现分层存储。理解存储机制对于数据持久化和性能优化至关重要。

```
┌─────────────────────────────────────────────────────────────┐
│                    Container Layer (RW)                     │
│              容器可写层 - 写入时复制(CoW)                      │
├─────────────────────────────────────────────────────────────┤
│                    Image Layer N (RO)                       │
│                    Image Layer 2 (RO)                       │
│                    Image Layer 1 (RO)                       │
│                    Base Layer (RO)                          │
├─────────────────────────────────────────────────────────────┤
│              所有镜像层都是只读的，通过联合挂载呈现统一视图       │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 数据持久化方式对比

| 特性 | Volume | Bind Mount | tmpfs |
|------|--------|------------|-------|
| 存储位置 | `/var/lib/docker/volumes/` | 宿主机任意路径 | 宿主机内存 |
| 管理 | Docker 管理 | 用户管理 | Docker 管理 |
| 跨容器共享 | 支持 | 支持 | 不支持 |
| 性能 | 好 | 依赖宿主机文件系统 | 最好（内存） |
| 数据持久化 | 是 | 是 | 否（容器停止即丢失） |
| 适用场景 | 数据库、应用数据 | 配置、源代码 | 敏感数据、临时缓存 |

### 2.3 Volume 详解

#### 2.3.1 Volume 类型

**Named Volume（命名卷）**：
```bash
# 创建命名卷
docker volume create my-data

# 查看卷详情
docker volume inspect my-data

# 使用命名卷
docker run -d -v my-data:/app/data nginx
# 或新语法
docker run -d --mount source=my-data,target=/app/data nginx
```

**Anonymous Volume（匿名卷）**：
```bash
# 匿名卷（只指定容器内路径）
docker run -d -v /app/data nginx

# 查看匿名卷
docker volume ls -f dangling=true
```

#### 2.3.2 Volume 驱动

Docker 支持多种存储驱动：

| 驱动 | 说明 |
|------|------|
| local | 默认驱动，存储在宿主机本地 |
| nfs | NFS 网络存储 |
| cifs | CIFS/SMB 网络存储 |
| vieux/sshfs | SSHFS 远程文件系统 |
| 云存储驱动 | AWS EBS、Azure Disk、GCP PD 等 |

```bash
# 使用 NFS 驱动创建卷
docker volume create --driver local \
  --opt type=nfs \
  --opt o=addr=192.168.1.100,rw \
  --opt device=:/exports/data \
  nfs-volume

# 使用 SSHFS
docker plugin install vieux/sshfs
docker volume create --driver vieux/sshfs \
  -o sshcmd=user@host:/path \
  -o password=secret \
  sshvolume
```

#### 2.3.3 Volume 数据管理

```bash
# 备份卷数据
docker run --rm -v my-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/my-data-backup.tar.gz -C /data .

# 恢复卷数据
docker run --rm -v my-data:/data -v $(pwd):/backup alpine \
  tar xzf /backup/my-data-backup.tar.gz -C /data

# 复制卷数据到新卷
docker run --rm -v old-volume:/from -v new-volume:/to alpine \
  sh -c "cd /from && cp -a . /to"

# 查看卷实际占用空间
docker system df -v

# 清理未使用的卷
docker volume prune
```

### 2.4 Bind Mount 详解

#### 2.4.1 基本用法

```bash
# 基本绑定挂载
docker run -d -v /host/path:/container/path nginx

# 新语法（推荐）
docker run -d --mount type=bind,source=/host/path,target=/container/path nginx

# 只读挂载
docker run -d --mount type=bind,source=/host/config,target=/etc/nginx,readonly nginx

# 绑定挂载文件（而非目录）
docker run -d -v /host/nginx.conf:/etc/nginx/nginx.conf:ro nginx
```

#### 2.4.2 挂载传播模式

```bash
# 私有挂载（默认）- 容器内的挂载不会传播到主机
docker run -d --mount type=bind,source=/host,target=/container,bind-propagation=private nginx

# 共享挂载 - 双向传播
docker run -d --mount type=bind,source=/host,target=/container,bind-propagation=shared nginx

# 从属挂载 - 主机到容器单向传播
docker run -d --mount type=bind,source=/host,target=/container,bind-propagation=slave nginx
```

### 2.5 tmpfs 挂载

```bash
# 使用 tmpfs（内存存储）
docker run -d --tmpfs /app/cache:rw,noexec,nosuid,size=100m nginx

# 新语法
docker run -d --mount type=tmpfs,target=/app/cache,tmpfs-size=100m nginx
```

**适用场景**：
- 敏感数据（访问令牌、密钥）
- 临时缓存数据
- 需要高性能读写但不需要持久化的数据

### 2.6 存储故障排查

#### 2.6.1 磁盘空间不足

```bash
# 查看 Docker 磁盘使用情况
docker system df

# 详细查看
docker system df -v

# 清理未使用的数据
docker system prune          # 清理未使用的容器、网络、镜像
docker system prune -a       # 清理所有未使用的镜像
docker volume prune          # 清理未使用的卷

# 查看卷实际占用
du -sh /var/lib/docker/volumes/*

# 查看 overlay2 占用
du -sh /var/lib/docker/overlay2/*
```

#### 2.6.2 卷权限问题

```bash
# 查看卷的权限
docker volume inspect my-volume
ls -la /var/lib/docker/volumes/my-volume/_data

# 使用用户命名空间映射权限
docker run -d -v my-volume:/data --user $(id -u):$(id -g) nginx

# 在 Dockerfile 中设置正确的用户
RUN chown -R appuser:appgroup /app/data
USER appuser
```

#### 2.6.3 性能问题诊断

```bash
# 测试卷 IO 性能
docker run --rm -v my-volume:/data alpine \
  sh -c "dd if=/dev/zero of=/data/test bs=1M count=100 oflag=direct"

# 对比 bind mount 和 volume 性能
docker run --rm -v /tmp:/data alpine \
  sh -c "dd if=/dev/zero of=/data/test bs=1M count=100 oflag=direct"

# 使用 iostat 监控
docker run --rm --pid=host alpine sh -c "apk add sysstat && iostat -x 1"
```

---

## 3. Overlay2 存储驱动原理

### 3.1 OverlayFS 基础

Overlay2 是 Docker 默认的存储驱动，基于 Linux 内核的 OverlayFS 实现。

#### 3.1.1 OverlayFS 核心概念

```
┌─────────────────────────────────────────────────────────────┐
│                      Merged View                            │
│              联合挂载后的统一视图（容器看到的文件系统）           │
├─────────────────────────────────────────────────────────────┤
│                    Upperdir (RW)                            │
│              容器可写层 - 存放所有修改                         │
├─────────────────────────────────────────────────────────────┤
│                    Lowerdir (RO)                            │
│              镜像只读层 - 可以有多个 lowerdir                  │
│              lowerdir1:lowerdir2:lowerdir3                    │
├─────────────────────────────────────────────────────────────┤
│                    Workdir                                  │
│              工作目录 - 用于存储临时文件和准备操作               │
└─────────────────────────────────────────────────────────────┘
```

**关键概念**：
- **Lowerdir**：只读层，对应镜像层，可以有多个，用 `:` 分隔
- **Upperdir**：可写层，对应容器层
- **Merged**：联合挂载后的统一视图
- **Workdir**：工作目录，用于存储临时文件

#### 3.1.2 写入时复制（CoW）机制

当容器修改文件时：
1. 如果文件在 Upperdir 存在，直接修改
2. 如果文件只在 Lowerdir 存在，先复制到 Upperdir，再修改
3. 删除文件时，在 Upperdir 创建 whiteout 文件标记删除

```bash
# 查看 OverlayFS 挂载详情
mount | grep overlay

# 示例输出：
# overlay on /var/lib/docker/overlay2/<id>/merged type overlay 
#   (rw,relatime,lowerdir=<lowerdirs>,upperdir=<upperdir>,workdir=<workdir>)
```

### 3.2 Overlay2 目录结构

#### 3.2.1 存储路径

```
/var/lib/docker/
├── overlay2/                          # 存储驱动数据目录
│   ├── <layer-id>/                    # 镜像层目录
│   │   ├── diff/                      # 层的内容
│   │   └── link                       # 短链接名
│   ├── <layer-id>-init/               # 容器 init 层
│   │   ├── diff/
│   │   └── link
│   ├── <container-id>/                # 容器可写层
│   │   ├── diff/                      # 容器修改的内容
│   │   ├── link
│   │   ├── lower                      # 指向 lower layer
│   │   ├── merged/                    # 联合挂载点
│   │   └── work/                      # 工作目录
│   └── l/                             # 短链接目录
│       └── <short-id> -> ../<layer-id>/diff
│
├── image/overlay2/
│   ├── imagedb/
│   │   ├── content/
│   │   │   └── sha256/
│   │   │       └── <image-id>         # 镜像配置 JSON
│   │   └── metadata/
│   │       └── sha256/
│   ├── layerdb/
│   │   ├── mounts/
│   │   │   └── <container-id>/        # 容器挂载信息
│   │   │       ├── init-id            # init 层 ID
│   │   │       ├── mount-id           # 挂载层 ID
│   │   │       └── parent             # 父层引用
│   │   ├── sha256/
│   │   │   └── <layer-chain-id>/      # 层元数据
│   │   │       ├── cache-id           # 指向 overlay2 目录
│   │   │       ├── diff               # DiffID
│   │   │       ├── parent             # 父层 ChainID
│   │   │       └── size               # 层大小
│   │   └── tmp/
│   └── distribution/
│       ├── diffid-by-digest/
│       │   └── sha256/
│       │       └── <digest>           # 存储 digest -> diffID 映射
│       └── v2metadata-by-diffid/
│           └── sha256/
│               └── <diffid>           # 存储 diffID -> digest 映射
```

#### 3.2.2 关键文件解析

**1. cache-id 文件**
```bash
# 位置：/var/lib/docker/image/overlay2/layerdb/sha256/<chain-id>/cache-id
# 内容：指向 overlay2 目录的 ID
cat /var/lib/docker/image/overlay2/layerdb/sha256/<chain-id>/cache-id
# 输出：abc123def456...
# 对应：/var/lib/docker/overlay2/abc123def456.../
```

**2. diff 文件（DiffID）**
```bash
# 位置：/var/lib/docker/image/overlay2/layerdb/sha256/<chain-id>/diff
# 内容：层的 DiffID（内容哈希）
cat /var/lib/docker/image/overlay2/layerdb/sha256/<chain-id>/diff
# 输出：sha256:a1b2c3d4...
```

**3. parent 文件**
```bash
# 位置：/var/lib/docker/image/overlay2/layerdb/sha256/<chain-id>/parent
# 内容：父层的 ChainID
cat /var/lib/docker/image/overlay2/layerdb/sha256/<chain-id>/parent
# 输出：sha256:e5f6g7h8...
```

**4. lower 文件**
```bash
# 位置：/var/lib/docker/overlay2/<container-id>/lower
# 内容：lowerdir 列表（短链接形式）
cat /var/lib/docker/overlay2/<container-id>/lower
# 输出：l/ABCD1234:l/EFGH5678:l/IJKL9012
```

### 3.3 ChainID 计算原理

ChainID 是 Docker 用于唯一标识层链的哈希值，计算方式如下：

```
ChainID(L0) = DiffID(L0)
ChainID(LN) = SHA256(ChainID(LN-1) + " " + DiffID(LN))
```

**示例**：
```
Layer 0: DiffID = sha256:aaa...
         ChainID = sha256:aaa...

Layer 1: DiffID = sha256:bbb...
         ChainID = SHA256("sha256:aaa... sha256:bbb...")

Layer 2: DiffID = sha256:ccc...
         ChainID = SHA256("<layer1-chainid> sha256:ccc...")
```

```bash
# 计算示例
# Layer 1 DiffID
DIFF_ID_1="sha256:5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef"
# Layer 2 DiffID  
DIFF_ID_2="sha256:ccc...

# ChainID for Layer 2
echo -n "${DIFF_ID_1} ${DIFF_ID_2}" | sha256sum
```

### 3.4 镜像元数据解析

#### 3.4.1 Image Config

```bash
# 获取镜像配置
docker inspect nginx:latest --format='{{.Id}}'
# 输出：sha256:abc123...

# 查看镜像配置 JSON
cat /var/lib/docker/image/overlay2/imagedb/content/sha256/<image-id>
```

**关键字段说明**：

```json
{
  "architecture": "amd64",
  "config": {
    "Hostname": "",
    "Domainname": "",
    "User": "",
    "AttachStdin": false,
    "AttachStdout": false,
    "AttachStderr": false,
    "ExposedPorts": {
      "80/tcp": {}
    },
    "Tty": false,
    "OpenStdin": false,
    "StdinOnce": false,
    "Env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "NGINX_VERSION=1.21.0"
    ],
    "Cmd": [
      "nginx",
      "-g",
      "daemon off;"
    ],
    "Image": "",
    "Volumes": null,
    "WorkingDir": "",
    "Entrypoint": null,
    "OnBuild": null,
    "Labels": {
      "maintainer": "NGINX Docker Maintainers <docker-maint@nginx.com>"
    },
    "StopSignal": "SIGQUIT"
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:sha256:a1b2c3d4...",
      "sha256:sha256:e5f6g7h8...",
      "sha256:sha256:i9j0k1l2..."
    ]
  }
}
```

| 字段 | 说明 |
|------|------|
| `rootfs.diff_ids` | 镜像各层的 DiffID 列表，从底层到顶层 |
| `config.ExposedPorts` | 镜像声明的暴露端口 |
| `config.Env` | 默认环境变量 |
| `config.Cmd` | 默认启动命令 |
| `config.Entrypoint` | 入口点配置 |
| `config.Volumes` | 匿名卷声明 |

#### 3.4.2 Manifest 解析

```bash
# 查看 manifest（镜像清单）
docker manifest inspect nginx:latest
```

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
  "config": {
    "mediaType": "application/vnd.docker.container.image.v1+json",
    "size": 1234,
    "digest": "sha256:abc123..."
  },
  "layers": [
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
      "size": 1234567,
      "digest": "sha256:layer1..."
    },
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
      "size": 2345678,
      "digest": "sha256:layer2..."
    }
  ]
}
```

**digest vs diff_id**：
- **digest**：压缩层的哈希（用于镜像仓库传输）
- **diff_id**：解压后层的哈希（用于本地存储）

### 3.5 存储驱动故障排查

#### 3.5.1 查看层关系

```bash
# 查看镜像的层结构
docker history nginx:latest --no-trunc

# 查看镜像详细层信息
docker inspect nginx:latest --format='{{range .RootFS.Layers}}{{.}}\n{{end}}'

# 查看容器使用的层
docker inspect <container> --format='{{.GraphDriver.Data}}'
```

#### 3.5.2 分析磁盘占用

```bash
# 查看各层大小
for dir in /var/lib/docker/overlay2/*/; do
  echo "$(du -sh "$dir" 2>/dev/null) $(basename "$dir")"
done | sort -hr | head -20

# 查找大文件
find /var/lib/docker/overlay2 -type f -size +100M -exec ls -lh {} \;

# 分析镜像层共享情况
docker system df -v
```

#### 3.5.3 常见问题

**问题 1：inode 耗尽**
```bash
# 检查 inode 使用
df -i /var/lib/docker

# 解决方案：清理未使用的镜像和层
docker system prune -a
```

**问题 2：层数量过多**
```bash
# OverlayFS 限制：lowerdir 最多 128 层（内核 4.0+）
# 查看层数
docker inspect <image> --format='{{len .RootFS.Layers}}'

# 优化：减少 Dockerfile 中的 RUN 指令数量
```

**问题 3：存储驱动切换**
```bash
# 停止 Docker
systemctl stop docker

# 备份数据
cp -a /var/lib/docker /var/lib/docker.bak

# 修改存储驱动
# 编辑 /etc/docker/daemon.json
{
  "storage-driver": "devicemapper"  // 或其他驱动
}

# 启动 Docker（注意：切换驱动后原有镜像和容器不可见）
systemctl start docker
```

---

## 4. Docker Compose 调试方法

### 4.1 Compose 文件结构解析

```yaml
version: '3.8'

services:
  web:
    image: nginx:latest
    container_name: my-web
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
      - web-data:/data
    environment:
      - NGINX_HOST=example.com
      - NGINX_PORT=80
    networks:
      - frontend
      - backend
    depends_on:
      - db
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 256M

  db:
    image: mysql:8.0
    container_name: my-db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
      MYSQL_DATABASE: myapp
    volumes:
      - db-data:/var/lib/mysql
    secrets:
      - db_root_password
    networks:
      - backend
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  web-data:
    driver: local
  db-data:
    driver: local

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true  # 无外部访问

secrets:
  db_root_password:
    file: ./secrets/db_root_password.txt
```

### 4.2 调试命令详解

#### 4.2.1 启动与查看

```bash
# 前台启动（查看启动日志）
docker-compose up

# 后台启动
docker-compose up -d

# 强制重新构建镜像
docker-compose up -d --build

# 只启动指定服务
docker-compose up -d web

# 查看服务状态
docker-compose ps

# 查看详细状态
docker-compose ps -a
```

#### 4.2.2 日志分析

```bash
# 查看所有服务日志
docker-compose logs

# 实时跟踪日志
docker-compose logs -f

# 查看最近 100 行
docker-compose logs --tail=100

# 查看特定服务日志
docker-compose logs -f web

# 带时间戳
docker-compose logs -f -t

# 查看特定时间后的日志
docker-compose logs -f --since="2024-01-01T00:00:00"
```

#### 4.2.3 配置验证

```bash
# 验证并查看解析后的配置
docker-compose config

# 查看完整配置（不截断）
docker-compose config --no-interpolate

# 检查环境变量替换
docker-compose config | grep -E '\$\{|environment:'
```

### 4.3 健康检查调试

#### 4.3.1 健康检查配置详解

```yaml
healthcheck:
  # 测试命令
  test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
  # 或 shell 形式
  test: ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
  
  # 检查间隔（默认 30s）
  interval: 30s
  
  # 超时时间（默认 30s）
  timeout: 10s
  
  # 重试次数（默认 3）
  retries: 3
  
  # 启动宽限期（默认 0s）
  start_period: 40s
  
  # 启动间隔（默认 5s）
  start_interval: 5s
```

#### 4.3.2 健康状态排查

```bash
# 查看容器健康状态
docker-compose ps

# 查看健康检查日志
docker inspect --format='{{.State.Health}}' <container>

# 查看健康检查历史
docker inspect --format='{{json .State.Health.Log}}' <container> | jq .

# 手动执行健康检查命令
docker-compose exec web curl -f http://localhost:8080/health
```

**常见健康检查问题**：

1. **启动时间不足**
   ```yaml
   # 增加 start_period
   healthcheck:
     test: ["CMD", "curl", "-f", "http://localhost"]
     interval: 10s
     timeout: 5s
     retries: 5
     start_period: 60s  # 给应用足够启动时间
   ```

2. **依赖服务未就绪**
   ```yaml
   # 使用 condition 等待依赖服务健康
   depends_on:
     db:
       condition: service_healthy
   ```

### 4.4 依赖与启动顺序

#### 4.4.1 depends_on 详解

```yaml
services:
  web:
    depends_on:
      db:
        condition: service_healthy  # 等待 db 健康
      redis:
        condition: service_started  # 等待 redis 启动
      kafka:
        condition: service_completed_successfully  # 等待 kafka 初始化完成
```

**condition 类型**：
- `service_started`：服务已启动（默认）
- `service_healthy`：服务健康检查通过
- `service_completed_successfully`：服务成功完成（用于 init 容器）

#### 4.4.2 自定义等待脚本

```yaml
services:
  web:
    entrypoint: ["/wait-for-it.sh", "db:3306", "--", "/start-app.sh"]
```

```bash
#!/bin/bash
# wait-for-it.sh

host="$1"
port="$2"
shift 2
cmd="$@"

until nc -z "$host" "$port"; do
  echo "Waiting for $host:$port..."
  sleep 1
done

echo "$host:$port is available"
exec $cmd
```

### 4.5 网络调试

```bash
# 查看 Compose 创建的网络
docker network ls | grep <project-name>

# 查看网络详情
docker network inspect <project-name>_default

# 进入容器网络命名空间调试
docker-compose exec web sh
# 在容器内
ping db
nslookup db
curl http://db:3306

# 测试服务间连通性
docker-compose exec web wget -O- http://api:8080/health
```

### 4.6 资源限制调试

```bash
# 查看容器资源使用
docker-compose top

# 查看统计信息
docker stats $(docker-compose ps -q)

# 查看 OOM 事件
docker events --filter event=oom

# 检查 cgroup 限制
docker-compose exec web cat /sys/fs/cgroup/memory/memory.limit_in_bytes
docker-compose exec web cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us
```

---

## 5. 容器故障排查与分析方法

### 5.1 容器生命周期与退出码

#### 5.1.1 退出码详解

| 退出码 | 含义 | 常见原因 |
|--------|------|----------|
| 0 | 正常退出 | 应用正常结束 |
| 1 | 通用错误 | 应用程序错误 |
| 126 | 命令不可执行 | 权限问题或文件不存在 |
| 127 | 命令未找到 | PATH 问题或命令拼写错误 |
| 128 + N | 被信号 N 终止 | 如 137 = 128 + 9 (SIGKILL) |
| 130 | 被 Ctrl+C 终止 | SIGINT (2) |
| 137 | 被 SIGKILL 终止 | OOM  killed 或强制停止 |
| 143 | 被 SIGTERM 终止 | 优雅停止超时 |
| 255 | 退出状态溢出 | 通常表示错误 |

#### 5.1.2 退出码分析

```bash
# 查看容器退出码
docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.State}}"

# 查看详细状态
docker inspect <container> --format='{{.State.ExitCode}}'

# 查看是否被 OOM 杀死
docker inspect <container> --format='{{.State.OOMKilled}}'

# 查看错误信息
docker inspect <container> --format='{{.State.Error}}'
```

### 5.2 容器重启故障排查

#### 5.2.1 重启策略详解

| 策略 | 说明 |
|------|------|
| `no` | 不自动重启（默认） |
| `on-failure[:max-retries]` | 退出码非 0 时重启，可限制次数 |
| `always` | 总是重启（除非手动停止） |
| `unless-stopped` | 总是重启（除非手动停止或 Docker 停止） |

```bash
# 查看容器重启次数
docker inspect <container> --format='{{.RestartCount}}'

# 查看重启策略
docker inspect <container> --format='{{.HostConfig.RestartPolicy}}'
```

#### 5.2.2 重启故障排查流程

```bash
# 1. 查看容器状态
docker ps -a | grep <container>
# 状态可能是：Restarting, Exited, Dead

# 2. 查看退出码和 OOM 状态
docker inspect <container> --format='
ExitCode: {{.State.ExitCode}}
OOMKilled: {{.State.OOMKilled}}
Error: {{.State.Error}}
RestartCount: {{.RestartCount}}
'

# 3. 查看日志（包括已退出的容器）
docker logs --tail 100 <container>

# 4. 检查资源限制
docker inspect <container> --format='
Memory: {{.HostConfig.Memory}}
MemorySwap: {{.HostConfig.MemorySwap}}
CpuQuota: {{.HostConfig.CpuQuota}}
'

# 5. 检查系统日志（OOM 事件）
dmesg -T | grep -i "killed process"
journalctl -u docker.service -n 100

# 6. 检查健康检查状态
docker inspect <container> --format='{{json .State.Health}}' | jq .
```

#### 5.2.3 常见重启问题及解决

**问题 1：OOM  killed（退出码 137）**

```bash
# 确认 OOM
docker inspect <container> --format='{{.State.OOMKilled}}'
# 输出：true

# 查看系统 OOM 日志
dmesg -T | grep -i "oom"

# 解决方案：增加内存限制
docker run -m 2g --memory-swap 2g <image>

# 或优化应用内存使用
# 在 Java 应用中设置堆内存
-e JAVA_OPTS="-Xmx1g -Xms1g"
```

**问题 2：应用启动失败（退出码 1）**

```bash
# 查看详细日志
docker logs <container> 2>&1

# 检查配置文件
docker inspect <container> --format='{{json .Config}}' | jq .

# 检查挂载
docker inspect <container> --format='{{json .Mounts}}' | jq .

# 手动运行调试
docker run --rm -it <image> sh
# 在容器内手动启动应用查看错误
```

**问题 3：依赖服务未就绪**

```bash
# 使用健康检查和 depends_on
docker-compose.yml:
  services:
    app:
      depends_on:
        db:
          condition: service_healthy
    db:
      healthcheck:
        test: ["CMD", "mysqladmin", "ping"]
        interval: 5s
        timeout: 3s
        retries: 10
```

**问题 4：PID 1 问题**

```bash
# 问题：应用作为 PID 1 运行时无法正确处理信号

# 解决方案 1：使用 tini 或 dumb-init
FROM ubuntu
RUN apt-get update && apt-get install -y tini
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/start.sh"]

# 解决方案 2：Docker 内置 --init
docker run --init <image>

# 解决方案 3：使用 exec 启动
#!/bin/sh
# start.sh
exec /app/myapp  # 使用 exec 替换 shell 进程
```

### 5.3 系统级故障排查

#### 5.3.1 Docker 守护进程问题

```bash
# 检查 Docker 服务状态
systemctl status docker

# 查看 Docker 日志
journalctl -u docker.service -f

# 检查 Docker 配置
cat /etc/docker/daemon.json

# 验证配置
dockerd --validate

# 重启 Docker
systemctl restart docker
```

**常见守护进程问题**：

1. **存储驱动问题**
   ```bash
   # 检查存储驱动
   docker info | grep "Storage Driver"
   
   # 查看驱动错误日志
   journalctl -u docker | grep -i "overlay\|storage"
   ```

2. **网络问题**
   ```bash
   # 检查 docker0 网桥
   ip addr show docker0
   
   # 检查 iptables 规则
   iptables -L -n -v | grep DOCKER
   
   # 检查转发设置
   sysctl net.ipv4.ip_forward
   ```

3. **资源耗尽**
   ```bash
   # 检查磁盘空间
   df -h /var/lib/docker
   
   # 检查 inode
   df -i /var/lib/docker
   
   # 检查进程数
   cat /proc/sys/kernel/pid_max
   ps aux | wc -l
   ```

#### 5.3.2 内核与系统调用问题

```bash
# 检查内核版本
uname -r

# 检查 cgroup 版本
mount | grep cgroup

# 查看容器系统调用（使用 strace）
docker run --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  strace -f -e trace=network <command>

# 检查 SELinux/AppArmor 限制
getenforce  # SELinux
aa-status   # AppArmor

# 查看审计日志
ausearch -ts recent -k docker
```

### 5.4 高级调试技巧

#### 5.4.1 使用 nsenter 深入容器

```bash
# 获取容器 PID
PID=$(docker inspect -f '{{.State.Pid}}' <container>)

# 进入容器网络命名空间
nsenter --target $PID --net ip addr

# 进入容器所有命名空间
nsenter --target $PID --mount --uts --ipc --net --pid -- bash

# 查看容器的挂载点
nsenter --target $PID --mount cat /proc/mounts

# 查看容器的进程树
nsenter --target $PID --pid ps auxf
```

#### 5.4.2 使用 debug 容器

```bash
# 使用特权容器进行网络调试
docker run --rm -it \
  --network container:<target-container> \
  --pid container:<target-container> \
  --cap-add NET_ADMIN \
  --cap-add SYS_PTRACE \
  nicolaka/netshoot

# 常用工具：
# - tcpdump: 抓包
# - wireshark/tshark: 协议分析
# - nmap: 端口扫描
# - netstat/ss: 连接状态
# - curl/wget: HTTP 测试
# - dig/nslookup: DNS 测试
# - ping: 连通性测试
# - traceroute/mtr: 路由追踪
# - iperf3: 带宽测试
# - strace: 系统调用跟踪
```

#### 5.4.3 使用 crictl（containerd）

```bash
# 如果使用 containerd 运行时
# 安装 crictl
VERSION="v1.28.0"
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz
tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin

# 配置 crictl
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# 常用命令
crictl ps -a                    # 列出容器
crictl inspect <container-id>   # 查看容器详情
crictl logs <container-id>      # 查看日志
crictl exec -it <container-id> sh  # 进入容器
crictl pods                     # 列出 Pod
crictl images                   # 列出镜像
```

### 5.5 故障排查 checklist

#### 5.5.1 容器无法启动

- [ ] 检查镜像是否存在：`docker images | grep <image>`
- [ ] 检查镜像架构是否匹配：`docker inspect <image> --format='{{.Os}}/{{.Architecture}}'`
- [ ] 检查端口冲突：`netstat -tlnp | grep <port>`
- [ ] 检查卷权限：`ls -la <host-path>`
- [ ] 检查环境变量：`docker inspect <container> --format='{{json .Config.Env}}'`
- [ ] 检查资源限制：`docker inspect <container> --format='{{json .HostConfig}}'`
- [ ] 检查日志：`docker logs <container>`
- [ ] 检查系统日志：`journalctl -u docker -n 100`

#### 5.5.2 容器性能问题

- [ ] 检查 CPU 使用：`docker stats`
- [ ] 检查内存使用：`docker stats` 或 `docker exec <container> cat /sys/fs/cgroup/memory/memory.usage_in_bytes`
- [ ] 检查 IO 使用：`iostat -x 1`
- [ ] 检查网络带宽：`iftop` 或 `nload`
- [ ] 检查进程数：`docker exec <container> ps aux | wc -l`
- [ ] 检查文件描述符：`docker exec <container> cat /proc/sys/fs/file-nr`
- [ ] 检查线程数：`docker exec <container> ps -eLf | wc -l`

#### 5.5.3 网络问题

- [ ] 检查容器 IP：`docker inspect <container> --format='{{.NetworkSettings.IPAddress}}'`
- [ ] 检查网络配置：`docker inspect <container> --format='{{json .NetworkSettings}}'`
- [ ] 测试容器间连通性：`docker exec <container1> ping <container2-ip>`
- [ ] 检查 DNS 解析：`docker exec <container> cat /etc/resolv.conf`
- [ ] 检查端口映射：`docker port <container>`
- [ ] 检查防火墙规则：`iptables -L -n -v`
- [ ] 抓包分析：`tcpdump -i any -w capture.pcap`

---

## 附录

### A. 常用命令速查表

| 命令 | 说明 |
|------|------|
| `docker info` | 查看 Docker 系统信息 |
| `docker version` | 查看 Docker 版本 |
| `docker system df` | 查看磁盘使用情况 |
| `docker system prune` | 清理未使用资源 |
| `docker inspect <container>` | 查看容器详细信息 |
| `docker inspect -f '{{.State}}' <container>` | 格式化输出 |
| `docker stats` | 实时查看资源使用 |
| `docker events` | 查看 Docker 事件 |
| `docker top <container>` | 查看容器进程 |
| `docker port <container>` | 查看端口映射 |

### B. 配置文件路径

| 文件 | 路径 |
|------|------|
| Docker 配置 | `/etc/docker/daemon.json` |
| 容器配置 | `/var/lib/docker/containers/<id>/config.v2.json` |
| 镜像元数据 | `/var/lib/docker/image/overlay2/imagedb/` |
| 层元数据 | `/var/lib/docker/image/overlay2/layerdb/` |
| 卷数据 | `/var/lib/docker/volumes/` |
| 网络配置 | `/var/lib/docker/network/files/local-kv.db` |

### C. 推荐工具

| 工具 | 用途 |
|------|------|
| `ctop` | 容器资源监控 |
| `dive` | 镜像层分析 |
| `portainer` | Docker 可视化管理 |
| `lazydocker` | TUI 界面管理 |
| `netshoot` | 网络调试工具箱 |
| `sysdig` | 系统调用分析 |
| `cadvisor` | 容器资源监控 |

---

## 培训总结

本培训文档涵盖了 Docker 的高级主题：

1. **网络**：深入理解 bridge、host、overlay、macvlan 等网络模式的原理和适用场景
2. **存储**：掌握 Volume、Bind Mount、tmpfs 的使用方法和故障排查
3. **Overlay2**：理解存储驱动的底层结构、ChainID 计算、镜像元数据
4. **Compose**：学会使用健康检查、依赖管理、资源限制等高级特性
5. **故障排查**：建立系统化的排查思路，掌握各种调试工具和技巧

建议结合实际操作进行学习，通过创建测试容器、模拟故障场景来加深理解。

---

*文档版本：v1.0*
*最后更新：2025-05-31*

