#!/usr/bin/env bash
# Block only externally reachable TCP/2096 without touching UFW configuration.
# Works with iptables-nft on Ubuntu 24.04; persistent via a dedicated systemd unit.
set -Eeuo pipefail
umask 077
[[ $(id -u) -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }

if [[ "${1:-}" == --rules-only ]]; then
  for tool in iptables ip6tables; do
    command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
    if ! "$tool" -C INPUT ! -i lo -p tcp --dport 2096 -j REJECT 2>/dev/null; then
      "$tool" -I INPUT 1 ! -i lo -p tcp --dport 2096 -j REJECT
    fi
  done
  exit 0
fi
[[ $# -eq 0 ]] || { echo 'Usage: block_subscription.sh [--rules-only]' >&2; exit 2; }

# Preflight both stacks before changing any rule.
iptables -S INPUT >/dev/null
ip6tables -S INPUT >/dev/null

install -m 700 -o root -g root "$0" /usr/local/sbin/xui-block-subscription
cat > /etc/systemd/system/xui-block-subscription.service <<'UNIT'
[Unit]
Description=Block public 3X-UI subscription port 2096 (IPv4/IPv6)
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/xui-block-subscription --rules-only

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 /etc/systemd/system/xui-block-subscription.service
systemctl daemon-reload
systemctl enable --now xui-block-subscription.service
systemctl is-active --quiet xui-block-subscription.service
for tool in iptables ip6tables; do
  "$tool" -C INPUT ! -i lo -p tcp --dport 2096 -j REJECT
done
echo 'Subscription TCP/2096 blocked for IPv4/IPv6; UFW preserved.'
