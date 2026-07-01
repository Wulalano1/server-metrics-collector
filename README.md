# server-metrics-collector

运维平台宿主机采集脚本，推送到 `ops-api.dev.iannil.net`。

**开箱即用**：`collector.env` 已预填 Token 与环境，部署无需改配置。

## 仓库结构

```
staging/                  → 服务器指标（CPU / 内存 / 磁盘）
grey/                     → 服务器指标
docker/staging/           → Docker 容器状态
docker/grey/              → Docker 容器状态
service-health/staging/   → 服务端口探针（MySQL 3306 / HTTP 80 / HTTPS 443）
service-health/grey/      → 服务端口探针
service-health/production/→ 服务端口探针
```

---

## 一、服务器指标

### 部署（staging）

```bash
git clone https://github.com/Wulalano1/server-metrics-collector.git /opt/server-metrics-collector-repo
cd /opt/server-metrics-collector-repo/staging
chmod +x install.sh collector.sh
sudo ./install.sh
```

### 部署（grey）

```bash
git clone https://github.com/Wulalano1/server-metrics-collector.git /opt/server-metrics-collector-repo
cd /opt/server-metrics-collector-repo/grey
chmod +x install.sh collector.sh
sudo ./install.sh
```

### 验证

```bash
/opt/server-metrics-collector/collector.sh
sudo journalctl -u server-metrics-collector -f
```

---

## 二、Docker 状态监控

与服务器指标相同流程：clone 同一仓库，进入 `docker/<环境>` 目录安装。

### 部署（staging）

```bash
git clone https://github.com/Wulalano1/server-metrics-collector.git /opt/server-metrics-collector-repo
cd /opt/server-metrics-collector-repo/docker/staging
chmod +x install.sh collector.sh
sudo ./install.sh
```

### 部署（grey）

```bash
git clone https://github.com/Wulalano1/server-metrics-collector.git /opt/server-metrics-collector-repo
cd /opt/server-metrics-collector-repo/docker/grey
chmod +x install.sh collector.sh
sudo ./install.sh
```

### 验证

```bash
/opt/docker-status-collector/collector.sh --dry-run
/opt/docker-status-collector/collector.sh
sudo journalctl -u docker-status-collector -f
```

---

## ops 后台配置

ops-api 容器 `.env` 需有：

```env
OPS_DB_HOST=...
OPS_DB_DATABASE=ops_platform
METRICS_PUSH_TOKEN=ops-metrics-push-iannil-2026
DOCKER_MONITOR_ENABLED=true
```

与各目录 `collector.env` 中 `METRICS_PUSH_TOKEN` 一致。

推送接口：

| 类型 | 路径 |
|------|------|
| 服务器指标 | `POST /api/v1/server/metrics/report` |
| Docker 状态 | `POST /api/v1/docker/report` |
| 服务端口探针 | `POST /api/v1/service-health/report` |

---

## 三、服务端口探针

与服务器指标、Docker 相同流程：clone 同一仓库，进入 `service-health/<环境>` 目录安装。

默认探针：MySQL `3306`（TCP）、HTTP `80`、HTTPS `443`。

### 部署（staging）

```bash
git clone https://github.com/Wulalano1/server-metrics-collector.git /opt/server-metrics-collector-repo
cd /opt/server-metrics-collector-repo/service-health/staging
chmod +x install.sh collector.sh
sudo ./install.sh
```

### 部署（grey）

```bash
git clone https://github.com/Wulalano1/server-metrics-collector.git /opt/server-metrics-collector-repo
cd /opt/server-metrics-collector-repo/service-health/grey
chmod +x install.sh collector.sh
sudo ./install.sh
```

### 部署（production）

```bash
git clone https://github.com/Wulalano1/server-metrics-collector.git /opt/server-metrics-collector-repo
cd /opt/server-metrics-collector-repo/service-health/production
chmod +x install.sh collector.sh
sudo ./install.sh
```

### 验证

```bash
/opt/service-health-probe/collector.sh --dry-run
/opt/service-health-probe/collector.sh
sudo journalctl -u service-health-probe -f
```

如需增删探针，编辑 `/opt/service-health-probe/collector.env` 中的 `PROBE_TARGETS`（JSON 数组）。
