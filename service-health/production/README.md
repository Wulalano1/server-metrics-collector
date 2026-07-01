# production 服务端口探针（开箱即用）

整个目录拷到 production 服务器，**无需改任何配置**。

默认探针：MySQL `3306`（TCP）、HTTP `80`、HTTPS `443`。

```bash
cd service-health/production
chmod +x install.sh collector.sh
sudo ./install.sh
```

手动试推：

```bash
/opt/service-health-probe/collector.sh --dry-run
/opt/service-health-probe/collector.sh
```

日志：`sudo journalctl -u service-health-probe -f`
