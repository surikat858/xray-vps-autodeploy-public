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
assert "'bundled'" in wizard
assert '[[ ! -e "$CFG" ]]' in wizard
assert '[[ -f "$BASE/install.sh"' in wizard
assert 'XUI_NONINTERACTIVE=1 bash' in installer
assert "config.env" in read(".gitignore")
assert "DUCKDNS_TOKEN=" in example and "vpn-example.duckdns.org" in example

print("PASS 1: safe prereqs, UFW preservation, firewall scope")
print("PASS 2: upstream API JSON contract, readiness and private credentials")
print("PASS 3: one-time reboot safety, bundled core and secret hygiene")
