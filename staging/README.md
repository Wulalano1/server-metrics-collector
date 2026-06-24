# staging 服务器指标采集（开箱即用）

整个目录拷到 staging 服务器，**无需改任何配置**。

```bash
cd server-metrics-collector-staging
chmod +x install.sh collector.sh
sudo ./install.sh
```

手动试推：

```bash
/opt/server-metrics-collector/collector.sh --dry-run
/opt/server-metrics-collector/collector.sh
```

日志：`sudo journalctl -u server-metrics-collector -f`
