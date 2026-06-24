#!/usr/bin/env bash
# grey Docker 状态采集一键安装：sudo ./install.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=/opt/docker-status-collector

[[ "$(id -u)" -eq 0 ]] || { echo "请使用 sudo ./install.sh"; exit 1; }
[[ "$(uname -s)" == "Linux" ]] || { echo "仅支持 Linux"; exit 1; }

mkdir -p "$TARGET"
cp "$DIR/collector.sh" "$DIR/collector.env" "$TARGET/"
chmod +x "$TARGET/collector.sh"
cp "$DIR/docker-status-collector.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now docker-status-collector

echo "安装完成: $TARGET"
systemctl status docker-status-collector --no-pager || true
