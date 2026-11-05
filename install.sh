#!/usr/bin/env bash
# Fresh Ubuntu 24.04 only. No destructive reconfiguration of an existing 3X-UI server.
set -Eeuo pipefail
umask 077
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CFG="${CONFIG_FILE:-$BASE/config.env}"
[[ $(id -u) -eq 0 ]] || { echo 'Run as root'; exit 1; }
[[ -f "$CFG" ]] || { echo "Copy config.example.env to config.env and edit it: $CFG"; exit 1; }
[[ $(stat -c %a "$CFG") == 600 ]] || { echo 'chmod 600 config.env first'; exit 1; }
# Config is admin-controlled, root-only; never load an untrusted env file.
# shellcheck disable=SC1090
source "$CFG"
: "${DOMAIN:?}" "${LE_EMAIL:?}" "${SSH_PORT:?}" "${VPN_PORT:?}" "${WS_PATH:?}" "${CLIENT_NAME:?}"
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
log 'Updating Ubuntu package lists and upgrading installed packages before deployment'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
log 'Installing deployment prerequisites'
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl certbot python3 iptables iptables-persistent cron openssl
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
log 'Issuing standalone certificate via Let’s Encrypt'
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
XUI_NONINTERACTIVE=1 bash "$TMP/install.sh" "$XUI_VERSION"
[[ -f /etc/x-ui/install-result.env ]] || { echo 'Missing generated panel credentials'; exit 1; }
# shellcheck disable=SC1091
source /etc/x-ui/install-result.env
log 'Binding the admin panel to loopback only'
/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1
systemctl restart x-ui
systemctl is-active --quiet x-ui
# The panel may briefly report active before its HTTP API is ready.
panel_ready=0
for attempt in $(seq 1 20); do
  code=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH#/}csrf-token" 2>/dev/null || true)
  if [[ "$code" == 200 ]]; then panel_ready=1; break; fi
  sleep 1
done
[[ "$panel_ready" == 1 ]] || { echo 'Panel API did not become ready' >&2; exit 1; }
log 'Installing domain-specific automatic renewal hook'
bash "$BASE/scripts/install_cert_hook.sh"
log 'Creating VLESS/WebSocket/TLS inbound through authenticated localhost API'
export XUI_USERNAME XUI_PASSWORD
python3 "$BASE/scripts/api_inbound.py" --domain "$DOMAIN" --port "$VPN_PORT" \
    --panel-port "$XUI_PANEL_PORT" --web-path "$XUI_WEB_BASE_PATH" \
    --ws-path "$WS_PATH" --client-name "$CLIENT_NAME" --cert "$CERT" --key "$KEY"
unset XUI_PASSWORD XUI_USERNAME
log 'Saving server parameters for health checks and Xray validation'
install -d -m 700 /etc/x-ui
cat > /etc/x-ui/autodeploy-public.env <<ENV
DOMAIN=$DOMAIN
VPN_PORT=$VPN_PORT
SSH_PORT=$SSH_PORT
ENV
chmod 600 /etc/x-ui/autodeploy-public.env
log 'Installing newest stable Xray-core (or pinned XRAY_VERSION)'
XRAY_VERSION="${XRAY_VERSION:-latest}" bash "$BASE/scripts/upgrade_xray.sh"
log 'Applying non-disruptive firewall policy'
iptables -C INPUT ! -i lo -p tcp --dport 2096 -j REJECT 2>/dev/null || iptables -I INPUT 1 ! -i lo -p tcp --dport 2096 -j REJECT
ip6tables -C INPUT ! -i lo -p tcp --dport 2096 -j REJECT 2>/dev/null || ip6tables -I INPUT 1 ! -i lo -p tcp --dport 2096 -j REJECT
netfilter-persistent save
log 'Verifying service and ports'
for i in {1..10}; do
  if ss -lnt "( sport = :${VPN_PORT} )" | grep -q LISTEN; then break; fi
  sleep 1
done
systemctl is-active --quiet x-ui
ss -lnt "( sport = :${VPN_PORT} )" | grep -q LISTEN
ss -lnt "( sport = :${XUI_PANEL_PORT} )" | grep -q '127.0.0.1'
bash "$BASE/scripts/backup.sh"
log 'Enabling automated daily local backups'
bash "$BASE/scripts/install_backup_timer.sh"
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
