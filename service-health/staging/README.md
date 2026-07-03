# staging 服务端口探针（开箱即用）

整个目录拷到 staging 服务器，**推送地址与 Token 已预填，开箱可跑**。

脚本每次运行通过 `ss -tlnH` **自动发现本机所有 TCP 监听端口**并探针（80 用 HTTP、443/8443 用 HTTPS，其余用 TCP）。无需手动列举端口。

```bash
cd service-health/staging
chmod +x install.sh collector.sh
sudo ./install.sh
```

手动试推：

```bash
/opt/service-health-probe/collector.sh --dry-run
/opt/service-health-probe/collector.sh
```

日志：`sudo journalctl -u service-health-probe -f`

可选配置（`/opt/service-health-probe/collector.env`）：

- `PROBE_EXCLUDE_PORTS=22,111` — 排除指定端口
- `PROBE_TARGETS='[...]'` — 完全手动指定目标（设置后不再自动发现）

改完配置：`sudo systemctl restart service-health-probe`
