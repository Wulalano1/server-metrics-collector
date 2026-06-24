# server-metrics-collector

运维平台服务器指标采集（CPU / 内存 / 磁盘），推送到 `ops-api.dev.iannil.net`。

**开箱即用**：`collector.env` 已预填 Token 与环境，部署无需改配置。

## 仓库结构

```
staging/    → 拷到 staging 服务器，sudo ./install.sh
grey/       → 拷到 grey 服务器，sudo ./install.sh
```

## 部署（staging 示例）

```bash
git clone https://github.com/Wulalano1/server-metrics-collector.git /opt/server-metrics-collector-repo
cd /opt/server-metrics-collector-repo/staging
chmod +x install.sh collector.sh
sudo ./install.sh
```

## 部署（grey）

```bash
git clone https://github.com/Wulalano1/server-metrics-collector.git /opt/server-metrics-collector-repo
cd /opt/server-metrics-collector-repo/grey
chmod +x install.sh collector.sh
sudo ./install.sh
```

## 验证

```bash
/opt/server-metrics-collector/collector.sh
sudo journalctl -u server-metrics-collector -f
```

## ops 后台

staging 上 ops 容器 `.env` 需有：

```env
METRICS_PUSH_TOKEN=ops-metrics-push-iannil-2026
```

与 `collector.env` 一致。
