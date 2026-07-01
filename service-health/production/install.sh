#!/usr/bin/env bash
# production 服务端口探针一键安装：sudo ./install.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=/opt/service-health-probe

[[ "$(id -u)" -eq 0 ]] || { echo "请使用 sudo ./install.sh"; exit 1; }
[[ "$(uname -s)" == "Linux" ]] || { echo "仅支持 Linux"; exit 1; }

mkdir -p "$TARGET"
cp "$DIR/collector.sh" "$DIR/collector.env" "$TARGET/"
chmod +x "$TARGET/collector.sh"
cp "$DIR/service-health-probe.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now service-health-probe

echo "安装完成: $TARGET"
systemctl status service-health-probe --no-pager || true
