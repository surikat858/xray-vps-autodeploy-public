#!/usr/bin/env bash
# Configure hands-off Let's Encrypt renewal for one established DuckDNS VLESS node.
# No issuance, no force-renewal, and no service restart during installation.
set -Eeuo pipefail
umask 077

[[ $(id -u) -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }

BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG_FILE:-$BASE/config.env}"
if [[ -f /etc/x-ui/autodeploy-public.env ]]; then
  CONFIG=/etc/x-ui/autodeploy-public.env
fi
[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"
: "${DOMAIN:?Missing DOMAIN}"

[[ "$DOMAIN" =~ ^[a-z0-9-]+[.]duckdns[.]org$ ]] || {
  echo 'Only a valid DuckDNS hostname is supported' >&2
  exit 1
}
[[ -f /etc/x-ui/x-ui.db ]] || { echo '3X-UI database missing' >&2; exit 1; }
command -v certbot >/dev/null || { echo 'Install certbot first' >&2; exit 1; }

CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
RENEW="/etc/letsencrypt/renewal/$DOMAIN.conf"
[[ -s "$CERT" && -s "$KEY" && -s "$RENEW" ]] || {
  echo "Missing cert, private key, or renewal config for $DOMAIN" >&2
  exit 1
}
openssl x509 -in "$CERT" -noout -checkend 604800 >/dev/null || {
  echo 'Certificate already expired or expires in under 7 days' >&2
  exit 1
}
# The current server uses standalone HTTP-01, which requires incoming TCP/80.
grep -Eq '^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*standalone([[:space:]]|$)' "$RENEW" || {
  echo "Certbot renewal is not configured for standalone HTTP-01; review $RENEW" >&2
  exit 1
}

install -d -o root -g root -m 755 /etc/letsencrypt/renewal-hooks/deploy
install -d -o root -g root -m 700 /etc/x-ui
printf '%s\n' "$DOMAIN" > /etc/x-ui/autodeploy-cert-domain
chmod 600 /etc/x-ui/autodeploy-cert-domain

cat > /etc/letsencrypt/renewal-hooks/deploy/30-xui-restart.sh <<'HOOK'
#!/usr/bin/env bash
# Invoked by Certbot ONLY after successful renewal of a certificate.
set -Eeuo pipefail
DOMAIN=$(cat /etc/x-ui/autodeploy-cert-domain)
[[ "$DOMAIN" =~ ^[a-z0-9-]+[.]duckdns[.]org$ ]] || exit 1
EXPECTED="/etc/letsencrypt/live/$DOMAIN"
[[ "${RENEWED_LINEAGE:-}" == "$EXPECTED" ]] || exit 0
[[ -f "$EXPECTED/fullchain.pem" && -f "$EXPECTED/privkey.pem" ]] || exit 1
openssl x509 -in "$EXPECTED/fullchain.pem" -noout -checkend 604800 >/dev/null
systemctl restart x-ui
systemctl is-active --quiet x-ui
logger -t xui-cert-renew "3X-UI restarted after certificate renewal for $DOMAIN"
HOOK
chmod 700 /etc/letsencrypt/renewal-hooks/deploy/30-xui-restart.sh

systemctl enable --now certbot.timer
systemctl is-enabled --quiet certbot.timer
systemctl is-active --quiet certbot.timer

echo "Certificate renewal configured for $DOMAIN"
echo 'Current certificate was NOT renewed and x-ui was NOT restarted.'
echo 'HTTP-01 renewal requires port 80 reachable from the Internet when due.'
echo 'Check: certbot renew --dry-run (does not restart x-ui by default).'
