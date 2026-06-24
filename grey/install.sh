#!/usr/bin/env bash
# grey 一键安装：sudo ./install.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=/opt/server-metrics-collector

[[ "$(id -u)" -eq 0 ]] || { echo "请使用 sudo ./install.sh"; exit 1; }
[[ "$(uname -s)" == "Linux" ]] || { echo "仅支持 Linux"; exit 1; }

mkdir -p "$TARGET"
cp "$DIR/collector.sh" "$DIR/collector.env" "$TARGET/"
chmod +x "$TARGET/collector.sh"
cp "$DIR/server-metrics-collector.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now server-metrics-collector

echo "安装完成: $TARGET"
systemctl status server-metrics-collector --no-pager || true
