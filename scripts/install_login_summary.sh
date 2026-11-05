#!/usr/bin/env bash
# Install an interactive root-only SSH greeting; do not change sshd or shell rc.
set -Eeuo pipefail
[[ $(id -u) -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f /etc/x-ui/autodeploy-public.env && -f /etc/x-ui/install-result.env ]] || {
  echo 'Install server summary only after completed panel setup' >&2
  exit 1
}
install -o root -g root -m 700 "$BASE/scripts/server_info.sh" /usr/local/sbin/xui-server-info
install -o root -g root -m 700 "$BASE/scripts/panel_access.sh" /usr/local/sbin/xui-panel-access
cat > /etc/profile.d/99-xui-server-info.sh <<'PROFILE'
# Print non-secret status only on interactive root SSH login sessions.
if [[ ${EUID:-$(id -u)} -eq 0 && -n "${SSH_CONNECTION:-}" && $- == *i* &&
      -x /usr/local/sbin/xui-server-info ]]; then
  /usr/local/sbin/xui-server-info || :
fi
PROFILE
chmod 644 /etc/profile.d/99-xui-server-info.sh
echo 'Interactive SSH root login summary enabled (no passwords or API tokens).'
