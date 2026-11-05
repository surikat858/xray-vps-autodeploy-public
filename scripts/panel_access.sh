#!/usr/bin/env bash
# Print an SSH tunnel command and panel URL, optionally generated credentials.
# WARNING: --show-credentials prints sensitive information to your terminal.
set -Eeuo pipefail
umask 077
[[ $(id -u) -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }

show_credentials=0
server_ip=''
ssh_port=22
while (( $# )); do
  case "$1" in
    --show-credentials) show_credentials=1; shift ;;
    --server-ip)
      (( $# >= 2 )) || { echo 'Missing server IP' >&2; exit 2; }
      server_ip=$2; shift 2 ;;
    --ssh-port)
      (( $# >= 2 )) || { echo 'Missing SSH port' >&2; exit 2; }
      ssh_port=$2; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

FILE=/etc/x-ui/install-result.env
[[ -f "$FILE" ]] || { echo "Missing $FILE" >&2; exit 1; }
# shellcheck disable=SC1091
source "$FILE"
: "${XUI_PANEL_PORT:?Missing panel port}" "${XUI_WEB_BASE_PATH:?Missing base path}"
[[ "$XUI_PANEL_PORT" =~ ^[0-9]{1,5}$ ]] || exit 1
[[ "$ssh_port" =~ ^[0-9]{1,5}$ ]] || exit 1

# Preserve the generated web path exactly, with one trailing slash.
path_segment="/${XUI_WEB_BASE_PATH#/}"
path_segment="${path_segment%/}/"
target="${server_ip:-VPS_IP}"
scheme=http
if [[ -f /etc/x-ui/autodeploy-public.env ]]; then
  # shellcheck disable=SC1091
  source /etc/x-ui/autodeploy-public.env
  if [[ "${PANEL_TLS_MODE:-ssh}" == domain ]]; then scheme=https; fi
fi

echo '=== 3X-UI PANEL ACCESS (Windows PowerShell) ==='
if ss -H -ltn "( sport = :${XUI_PANEL_PORT} )" | grep -q '127[.]0[.]0[.]1'; then
  echo 'Panel: 127.0.0.1 (SSH tunnel required)'
else
  echo 'WARNING: expected 127.0.0.1 panel listener not found'
fi
printf 'SSH tunnel: ssh -N -o ExitOnForwardFailure=yes -p %s -L 127.0.0.1:8443:127.0.0.1:%s root@%s\n' \
  "$ssh_port" "$XUI_PANEL_PORT" "$target"
printf 'Panel URL: %s://127.0.0.1:8443%s\n' "$scheme" "$path_segment"
if [[ $scheme == https ]]; then
  echo 'NOTE: Domain TLS certificate will not match 127.0.0.1; SSH tunnel already encrypts transport.'
fi
echo 'Leave the Windows PowerShell session running while using the panel.'
if (( show_credentials )); then
  if [[ -z "${XUI_USERNAME:-}" || -z "${XUI_PASSWORD:-}" ]]; then
    echo 'WARNING: generated panel credentials are absent from install-result.env' >&2
    exit 1
  fi
  echo '═══════════════════════════════════════════'
  echo '     Panel Installation Complete!'
  echo '═══════════════════════════════════════════'
  printf 'Username:    %s\n' "$XUI_USERNAME"
  printf 'Password:    %s\n' "$XUI_PASSWORD"
  printf 'Port:        %s\n' "$XUI_PANEL_PORT"
  printf 'WebBasePath: %s\n' "$path_segment"
  printf 'Database:    %s\n' "${XUI_DB_TYPE:-sqlite}"
  printf 'Access URL:  %s://127.0.0.1:8443%s\n' "$scheme" "$path_segment"
  printf 'API Token:   %s\n' "${XUI_API_TOKEN:-not-set}"
  echo '═══════════════════════════════════════════'
  echo 'Do not share, screenshot or upload these values.'
else
  echo 'Credentials are stored in /etc/x-ui/install-result.env (root only).'
  echo 'To display them explicitly: bash scripts/panel_access.sh --show-credentials'
fi
