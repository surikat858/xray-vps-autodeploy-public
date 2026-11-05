#!/usr/bin/env python3
"""Offline release contract checks. No server commands are executed."""
from pathlib import Path
import ast
import re

root = Path(__file__).resolve().parent.parent
read = lambda p: (root / p).read_text(encoding="utf-8")
installer = read("install.sh")
wizard = read("scripts/setup_interactive.sh")
api = read("scripts/api_inbound.py")
firewall = read("scripts/block_subscription.sh")
hook = read("scripts/install_cert_hook.sh")
example = read("config.example.env")

# Pass 1: safety before first write on clean systems.
assert "Existing x-ui database detected: refusing to overwrite" in installer
assert "Existing x-ui executable detected: refusing to overwrite" in installer
assert "--no-remove ca-certificates curl certbot python3 iptables cron openssl" in installer
assert "iptables-persistent" not in re.sub(r"^#.*$", "", installer, flags=re.MULTILINE)
assert "bash \"$BASE/scripts/block_subscription.sh\"" in installer
assert "install -m 700" in firewall
assert "xui-block-subscription.service" in firewall
assert "ip6tables" in firewall and "iptables" in firewall
assert "ufw deny" not in installer.lower()
assert "rm -rf /etc/x-ui" not in installer

# Pass 2: pinned upstream API model, TLS, and error handling.
ast.parse(api)
assert "for field in ('settings', 'streamSettings', 'sniffing')" in api
assert "payload[field] = json.dumps(payload[field]" in api
assert "basepath = '/' + args.web_path.strip('/')" in api
assert "/csrf-token" in api
assert "X-CSRF-Token" in api
assert 'panel_base="$' in installer and 'panel_base%/' in installer
assert "response=$(curl --noproxy" in installer
assert "json.load(sys.stdin)" in installer
assert "UPSTREAM_LOG=/var/log/xray-vps-upstream-private.log" in installer
assert "chmod 600" in installer or "install -o root -g root -m 600" in installer
assert "certificateFile" in api and "keyFile" in api
assert "RENEWED_LINEAGE" in hook

# Pass 3: reboot-resume guard, no secret in git, stable Xray default.
assert "REBOOT_STATE=/var/lib/xray-autodeploy/reboot-pending" in installer
assert "source_boot != \"$current_boot\"" in installer or 'source_boot != "$current_boot"' in installer
assert "systemctl disable xray-autodeploy-resume.service" in installer
assert 'rm -f -- "$REBOOT_STATE"' in installer
assert 'XRAY_VERSION:-bundled' in installer
assert 'XRAY_VERSION=bundled' in example
assert 'XUI_DB_TYPE=sqlite' in example
assert 'PANEL_TLS_MODE=ssh' in example
assert 'XUI_DB_TYPE=postgres' in wizard
assert 'PANEL_TLS_MODE=domain; break' in wizard and 'PANEL_TLS_MODE=ssh; break' in wizard
assert 'PANEL_TLS_MODE == domain' in installer
assert '1|bundled) XRAY_VERSION=bundled' in wizard
assert '2|latest) XRAY_VERSION=latest' in wizard
assert "prompt 'Вариант Xray (1/2/3, Enter = bundled)' '1'" in wizard
assert "answer=$(printf '%s' " in wizard
assert "apt-get update" in wizard and "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" in wizard
assert "apt-prepared-boot" in installer and "apt-prepared-boot" in wizard
assert "install_login_summary.sh" in installer
assert "xui-server-info" in read("scripts/install_login_summary.sh")
assert "Access URL:" in read("scripts/server_info.sh")
assert "Xray-core:" in read("scripts/server_info.sh")
assert '[[ ! -e "$CFG" ]]' in wizard
assert '[[ -f "$BASE/install.sh"' in wizard
assert 'XUI_NONINTERACTIVE=1 XUI_DB_TYPE=' in installer
assert 'XUI_SSL_MODE=none bash' in installer
assert "config.env" in read(".gitignore")
assert "DUCKDNS_TOKEN=" in example and "vpn-example.duckdns.org" in example

print("PASS 1: safe prereqs, UFW preservation, firewall scope")
print("PASS 2: upstream API JSON contract, readiness and private credentials")
print("PASS 3: one-time reboot safety, bundled core and secret hygiene")
