# grey Docker 状态采集（开箱即用）

整个目录拷到 grey 服务器，**无需改任何配置**。

```bash
cd docker/grey
chmod +x install.sh collector.sh
sudo ./install.sh
```

手动试推：

```bash
/opt/docker-status-collector/collector.sh --dry-run
/opt/docker-status-collector/collector.sh
```

日志：`sudo journalctl -u docker-status-collector -f`
