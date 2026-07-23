# staging 服务端口探针（开箱即用）

整个目录拷到 staging 服务器，**推送地址与 Token 已预填，开箱可跑**。

脚本每次运行通过 `ss -tlnH` **自动发现本机所有 TCP 监听端口**并探针。可在 ops 平台或 `PROBE_PORTS` 中**额外指定**端口（可不在监听列表中），与自动发现合并去重。

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

- `PROBE_PORTS=9999,8788` — 额外指定端口（可不在 ss 列表中）
- `PROBE_EXCLUDE_PORTS=22,111` — 自动发现时排除端口
- `USE_OPS_PROBE_CONFIG=1` — 仅探测 ops 配置的端口（关闭自动发现）
- `PROBE_TARGETS='[...]'` — 完全手动 JSON 目标（优先级最高）

改完配置：`sudo systemctl restart service-health-probe`
