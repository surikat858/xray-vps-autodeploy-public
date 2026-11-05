#!/usr/bin/env bash
# Fresh Ubuntu 24.04 only. No destructive reconfiguration of an existing 3X-UI server.
set -Eeuo pipefail
umask 077
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CFG="${CONFIG_FILE:-$BASE/config.env}"
REBOOT_STATE=/var/lib/xray-autodeploy/reboot-pending
RESUME_UNIT=/etc/systemd/system/xray-autodeploy-resume.service
RESUME_MODE=0
if [[ $# -eq 1 && $1 == --resume-after-reboot ]]; then
  RESUME_MODE=1
elif (( $# != 0 )); then
  echo "Usage: bash install.sh [--resume-after-reboot]" >&2
  exit 2
fi
[[ $(id -u) -eq 0 ]] || { echo 'Run as root'; exit 1; }
[[ -f "$CFG" ]] || { echo "Copy config.example.env to config.env and edit it: $CFG"; exit 1; }
[[ $(stat -c %a "$CFG") == 600 ]] || { echo 'chmod 600 config.env first'; exit 1; }
# Config is admin-controlled, root-only; never load an untrusted env file.
# shellcheck disable=SC1090
source "$CFG"
: "${DOMAIN:?}" "${LE_EMAIL:?}" "${SSH_PORT:?}" "${VPN_PORT:?}" "${WS_PATH:?}" "${CLIENT_NAME:?}"
XUI_DB_TYPE="${XUI_DB_TYPE:-sqlite}"
PANEL_TLS_MODE="${PANEL_TLS_MODE:-ssh}"
[[ $XUI_DB_TYPE == sqlite || $XUI_DB_TYPE == postgres ]] || { echo 'Invalid XUI_DB_TYPE'; exit 1; }
[[ $PANEL_TLS_MODE == ssh || $PANEL_TLS_MODE == domain ]] || { echo 'Invalid PANEL_TLS_MODE'; exit 1; }
XUI_VERSION="${XUI_VERSION:-v3.11.0}"
[[ $XUI_VERSION == 'v3.11.0' ]] || { echo 'Only tested for v3.11.0'; exit 1; }
[[ $DOMAIN =~ ^[a-z0-9-]+\.duckdns\.org$ ]] || { echo 'Invalid DuckDNS hostname'; exit 1; }
[[ $LE_EMAIL == *@*.* ]] || { echo 'Set a valid LE_EMAIL'; exit 1; }
[[ $VPN_PORT =~ ^[0-9]+$ && $VPN_PORT -ge 1 && $VPN_PORT -le 65535 ]] || exit 1
[[ $SSH_PORT =~ ^[0-9]+$ && $SSH_PORT -ge 1 && $SSH_PORT -le 65535 ]] || exit 1
[[ $WS_PATH == /* && $WS_PATH != *\?* && $WS_PATH != *\#* ]] || exit 1
[[ $(. /etc/os-release; echo "$ID:$VERSION_ID") == 'ubuntu:24.04' ]] || { echo 'Requires Ubuntu 24.04'; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'Requires x86_64'; exit 1; }
[[ ! -e /etc/x-ui/x-ui.db ]] || { echo 'Existing x-ui database detected: refusing to overwrite'; exit 1; }
[[ ! -e /usr/local/x-ui/x-ui ]] || { echo 'Existing x-ui executable detected: refusing to overwrite'; exit 1; }
[[ $(df -Pm / | awk 'NR==2 {print $4}') -ge 1500 ]] || { echo 'Need at least 1.5 GB free'; exit 1; }
[[ $SSH_PORT != "$VPN_PORT" ]] || exit 1
[[ $VPN_PORT != 80 && $VPN_PORT != 2096 ]] || exit 1
LOG=/var/log/xray-vps-autodeploy.log
# Keep a private reference to the original terminal. Secret credentials must
# bypass tee/log files, and must never be printed for unattended/no-TTY runs.
exec 3>&1
exec > >(tee -a "$LOG") 2>&1
log() { printf '\n[%s] %s\n' "$(date -Is)" "$*"; }
fail() { echo "ERROR at line $1. No automatic removal of installed components. See $LOG"; }
trap 'fail "$LINENO"' ERR
log 'Checking DNS and resource availability'
for port in 80 "$VPN_PORT" 2096; do
  if ss -H -ltn "( sport = :$port )" | grep -q LISTEN; then
    echo "Port $port already in use: refusing fresh install" >&2
    ss -H -ltnp "( sport = :$port )"
    exit 1
  fi
done
# Resumption is valid only after a reboot scheduled by the initial run.
# A one-time marker contains the source boot ID; never retry a partial panel install.
if (( RESUME_MODE )); then
  [[ -f "$REBOOT_STATE" && ! -L "$REBOOT_STATE" ]] || { echo 'No scheduled reboot continuation; refusing resume' >&2; exit 1; }
  [[ $(stat -c %a "$REBOOT_STATE") == 600 ]] || { echo 'Unsafe resume marker permissions' >&2; exit 1; }
  source_boot=$(cat "$REBOOT_STATE")
  current_boot=$(cat /proc/sys/kernel/random/boot_id)
  [[ $source_boot =~ ^[0-9a-f-]{36}$ && $source_boot != "$current_boot" ]] || {
    echo 'Resume requires a different boot after the OS update' >&2
    exit 1
  }
  # One attempt only: disable before any installation work, so repeated reboots
  # after an incomplete 3X-UI setup cannot re-run the installer.
  systemctl disable xray-autodeploy-resume.service
  rm -f -- "$REBOOT_STATE"
  log 'Resuming clean VPS setup after Ubuntu reboot'
else
  # The interactive wizard has already upgraded packages in THIS boot.
  # For direct install.sh use, perform update/upgrade here.
  APT_MARKER=/run/xray-autodeploy/apt-prepared-boot
  current_boot=$(cat /proc/sys/kernel/random/boot_id)
  if [[ -f "$APT_MARKER" && ! -L "$APT_MARKER" &&
        $(stat -c %a "$APT_MARKER") == 600 &&
        $(cat "$APT_MARKER") == "$current_boot" ]]; then
    log 'Ubuntu updated by interactive wizard in this boot; skipping duplicate apt upgrade'
    rm -f -- "$APT_MARKER"
  else
    log 'Updating Ubuntu package lists and upgrading installed packages before deployment'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  fi
  if [[ -f /var/run/reboot-required ]]; then
    log 'OS reboot required. Scheduling one-time install continuation.'
    [[ $BASE =~ ^/[A-Za-z0-9/_-]+$ ]] || { echo 'Unsupported checkout path for systemd continuation' >&2; exit 1; }
    [[ ! -e "$REBOOT_STATE" ]] || { echo 'Existing reboot marker: inspect before continuing' >&2; exit 1; }
    install -d -m 700 /var/lib/xray-autodeploy
    cat /proc/sys/kernel/random/boot_id > "$REBOOT_STATE"
    chmod 600 "$REBOOT_STATE"
    cat > "$RESUME_UNIT" <<UNIT
[Unit]
Description=Resume one-time Xray VPN install after OS upgrade reboot
Wants=network-online.target
After=network-online.target
ConditionPathExists=$REBOOT_STATE

[Service]
Type=oneshot
ExecStart=/bin/bash $BASE/install.sh --resume-after-reboot
WorkingDirectory=$BASE
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$RESUME_UNIT"
    systemctl daemon-reload
    systemctl enable xray-autodeploy-resume.service
    log 'Rebooting now; SSH will disconnect. Installation will continue once after boot.'
    log 'After reconnect: journalctl -u xray-autodeploy-resume.service -b --no-pager'
    systemctl reboot
    exit 0
  fi
fi
log 'Installing deployment prerequisites'
# Never install iptables-persistent here: apt can REMOVE an existing UFW setup.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove ca-certificates curl certbot python3 iptables cron openssl
IP=$(curl -4fsS --max-time 10 https://api.ipify.org)
if [[ -n ${DUCKDNS_TOKEN:-} ]]; then
    label=${DOMAIN%.duckdns.org}
    # Keep DuckDNS token out of logs; secrets are only in root-owned config.env.
    result=$(curl -fsS --max-time 20 --get \
      --data-urlencode "domains=$label" --data-urlencode "token=$DUCKDNS_TOKEN" \
      --data-urlencode "ip=$IP" https://www.duckdns.org/update)
    [[ $result == OK ]] || { echo 'DuckDNS update did not return OK'; exit 1; }
fi
DNS_IP=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}')
[[ $DNS_IP == "$IP" ]] || { echo "DNS mismatch: $DOMAIN => ${DNS_IP:-none}, server => $IP"; exit 1; }
log 'Issuing standalone Let\x27s Encrypt certificate'
certbot certonly --standalone --preferred-challenges http --non-interactive --agree-tos \
  --email "$LE_EMAIL" -d "$DOMAIN" --keep-until-expiring
CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
openssl x509 -in "$CERT" -noout -checkend 604800 >/dev/null
log 'Installing pinned 3X-UI release'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 -o "$TMP/install.sh" \
  'https://raw.githubusercontent.com/MHSanaei/3x-ui/v3.11.0/install.sh'
# Official installer checks GitHub release checksum itself.
# The official installer prints panel password, base path and API token.
# Never forward this output to the console or the general install log.
UPSTREAM_LOG=/var/log/xray-vps-upstream-private.log
install -o root -g root -m 600 /dev/null "$UPSTREAM_LOG"
if ! XUI_NONINTERACTIVE=1 XUI_DB_TYPE="$XUI_DB_TYPE" XUI_SSL_MODE=none bash "$TMP/install.sh" "$XUI_VERSION" >"$UPSTREAM_LOG" 2>&1; then
  echo "Official 3X-UI installer failed. Private output: $UPSTREAM_LOG" >&2
  echo 'Do not publish this file: it contains credentials.' >&2
  exit 1
fi
log '3X-UI installed; upstream credentials stored in root-only log'
[[ -f /etc/x-ui/install-result.env ]] || { echo 'Missing generated panel credentials'; exit 1; }
# shellcheck disable=SC1091
source /etc/x-ui/install-result.env
log 'Binding the admin panel to loopback only'
/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1
if [[ $PANEL_TLS_MODE == domain ]]; then
  log 'Configuring panel HTTPS with validated domain certificate (loopback-only)'
  /usr/local/x-ui/x-ui cert -webCert "$CERT" -webCertKey "$KEY"
  PANEL_SCHEME=https
else
  PANEL_SCHEME=http
fi
systemctl restart x-ui
systemctl is-active --quiet x-ui
# Official v3.11.0 endpoint is /<webBasePath>/csrf-token.
# Require a valid JSON CSRF response instead of only HTTP 200.
panel_base="${PANEL_SCHEME}://127.0.0.1:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH#/}"
panel_base="${panel_base%/}"
panel_ready=0
last_http=none
for _ in $(seq 1 40); do
  response=$(curl --noproxy '*' -kfsS --max-time 3 "$panel_base/csrf-token" 2>/dev/null || true)
  if [[ -n "$response" ]] && printf '%s' "$response" | python3 -c '
import json,sys
try:
    j=json.load(sys.stdin)
    assert j.get("success") is True
    assert isinstance(j.get("obj"),str) and len(j["obj"]) >= 16
except (ValueError, KeyError, AssertionError, AttributeError):
    sys.exit(1)
' >/dev/null 2>&1; then
    panel_ready=1
    break
  fi
  last_http=$(curl --noproxy '*' -ksS --max-time 3 -o /dev/null -w '%{http_code}' "$panel_base/csrf-token" 2>/dev/null || true)
  sleep 1
done
[[ "$panel_ready" == 1 ]] || {
  echo "Panel API readiness failed: HTTP ${last_http:-unavailable}, after 40 checks." >&2
  echo 'Run: systemctl status x-ui; journalctl -u x-ui -n 40 --no-pager' >&2
  exit 1
}
log 'Installing domain-specific automatic renewal hook'
bash "$BASE/scripts/install_cert_hook.sh"
log 'Creating VLESS/WebSocket/TLS inbound through authenticated localhost API'
export XUI_USERNAME XUI_PASSWORD
python3 "$BASE/scripts/api_inbound.py" --domain "$DOMAIN" --port "$VPN_PORT" \
    --panel-port "$XUI_PANEL_PORT" --panel-scheme "$PANEL_SCHEME" --web-path "$XUI_WEB_BASE_PATH" \
    --ws-path "$WS_PATH" --client-name "$CLIENT_NAME" --cert "$CERT" --key "$KEY"
unset XUI_PASSWORD XUI_USERNAME
log 'Saving server parameters for health checks and Xray validation'
install -d -m 700 /etc/x-ui
cat > /etc/x-ui/autodeploy-public.env <<ENV
DOMAIN=$DOMAIN
VPN_PORT=$VPN_PORT
SSH_PORT=$SSH_PORT
PANEL_TLS_MODE=$PANEL_TLS_MODE
XUI_DB_TYPE=$XUI_DB_TYPE
ENV
chmod 600 /etc/x-ui/autodeploy-public.env
if [[ "${XRAY_VERSION:-bundled}" == bundled ]]; then
  log 'Keeping Xray-core version bundled and tested with 3X-UI v3.11.0'
else
  log 'Upgrading Xray-core to explicitly selected version'
  XRAY_VERSION="$XRAY_VERSION" bash "$BASE/scripts/upgrade_xray.sh"
fi
log 'Applying persistent, scoped subscription-port block without changing UFW'
bash "$BASE/scripts/block_subscription.sh"
log 'Verifying service and ports'
for _ in {1..10}; do
  if ss -lnt "( sport = :${VPN_PORT} )" | grep -q LISTEN; then break; fi
  sleep 1
done
systemctl is-active --quiet x-ui
ss -lnt "( sport = :${VPN_PORT} )" | grep -q LISTEN
ss -lnt "( sport = :${XUI_PANEL_PORT} )" | grep -q '127.0.0.1'
bash "$BASE/scripts/backup.sh"
log 'Enabling automated daily local backups'
bash "$BASE/scripts/install_backup_timer.sh"
log 'Installing root-only SSH login server summary'
bash "$BASE/scripts/install_login_summary.sh"
log 'INSTALL COMPLETE'
echo "Domain: $DOMAIN, VPN TCP port: $VPN_PORT"
echo 'Client profile: /etc/x-ui/autodeploy-client.json (root only).'
echo 'Test VPN from an external network before enabling strict firewall rules.'
echo 'Panel details are shown on the original terminal only; secrets are excluded from this installation log.'
if [[ -t 3 ]]; then
  # No tee: show the username/password directly on the operator's terminal.
  bash "$BASE/scripts/panel_access.sh" --server-ip "$IP" --ssh-port "$SSH_PORT" --show-credentials >&3
else
  # Noninteractive cloud-init/pipelines must never emit passwords.
  echo 'No interactive terminal: credentials remain in /etc/x-ui/install-result.env (root only).'
  echo 'Later, in an SSH session, run: bash scripts/panel_access.sh --show-credentials'
fi
