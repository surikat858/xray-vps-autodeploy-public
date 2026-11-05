#!/usr/bin/env bash
set -euo pipefail
source /etc/x-ui/autodeploy-public.env
printf 'Panel: '; systemctl is-active x-ui
printf 'VPN TCP: '; ss -ltn "( sport = :${VPN_PORT} )" | grep -q LISTEN && echo listening
printf 'Cert: '; openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -checkend 604800 >/dev/null && echo valid-over-7d
printf 'DNS: '; getent ahostsv4 "$DOMAIN" | head -1
printf 'Firewall: '; iptables -S INPUT | grep '2096' || echo 'No subscription block'
