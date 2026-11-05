#!/usr/bin/env bash
# Pinned Xray-core upgrade, bounded health checks and rollback.
set -Eeuo pipefail
umask 077
# Default: newest upstream stable release, resolved at installation time.
# Set XRAY_VERSION=v26.10.31 to pin a tested release instead.
XRAY_VERSION="${XRAY_VERSION:-latest}"
[[ "$XRAY_VERSION" == latest || "$XRAY_VERSION" =~ ^v?[0-9]+[.][0-9]+[.][0-9]+$ ]] || {
  echo 'Invalid XRAY_VERSION; use latest or vMAJOR.MINOR.PATCH' >&2
  exit 1
}
if [[ "$XRAY_VERSION" == latest ]]; then
  XRAY_API=https://api.github.com/repos/XTLS/Xray-core/releases/latest
else
  XRAY_API="https://api.github.com/repos/XTLS/Xray-core/releases/tags/v${XRAY_VERSION#v}"
fi
# GitHub release asset's sha256 digest is used as the trust anchor.
# Fail closed if a release is missing a digest; do not execute unverified binaries.
RELEASE=$(python3 - "$XRAY_API" <<'PYRELEASE'
import json, re, sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'xray-vps-autodeploy/1.0',
})
with urllib.request.urlopen(req, timeout=20) as response:
    release = json.load(response)
tag = release.get('tag_name', '')
if not re.fullmatch(r'v[0-9]+[.][0-9]+[.][0-9]+', tag):
    raise SystemExit('Invalid release tag')
if release.get('draft') or release.get('prerelease'):
    raise SystemExit('Refusing draft/pre-release Xray')
assets = [a for a in release.get('assets', []) if a.get('name') == 'Xray-linux-64.zip']
if len(assets) != 1:
    raise SystemExit('Expected one linux-amd64 archive')
asset = assets[0]
digest = asset.get('digest') or ''
url = asset.get('browser_download_url') or ''
if not re.fullmatch(r'sha256:[a-fA-F0-9]{64}', digest):
    raise SystemExit('Release asset lacks SHA-256 digest')
expected = f'https://github.com/XTLS/Xray-core/releases/download/{tag}/Xray-linux-64.zip'
if url != expected:
    raise SystemExit('Unexpected release asset URL')
print(tag[1:], digest.split(':', 1)[1].lower(), url, sep=' ')
PYRELEASE
) || { echo 'Could not verify upstream Xray release metadata' >&2; exit 1; }
read -r VERSION EXPECTED_SHA256 RELEASE_URL <<< "$RELEASE"
BIN=/usr/local/x-ui/bin/xray-linux-amd64
DIR=/root/xray-autodeploy-upgrade
mkdir -p "$DIR"; chmod 700 "$DIR"
[[ $(id -u) -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
[[ -x "$BIN" ]] || { echo "Missing Xray binary: $BIN" >&2; exit 1; }
current_version=$("$BIN" version | sed -n '1p')
if [[ "$current_version" == "Xray $VERSION "* ]]; then
  echo "Already using Xray $VERSION"; exit 0
fi
PORT=443
if [[ -f /etc/x-ui/autodeploy-public.env ]]; then
  # shellcheck disable=SC1091
  source /etc/x-ui/autodeploy-public.env
  PORT="${VPN_PORT:-443}"
fi
[[ $PORT =~ ^[0-9]{1,5}$ && $PORT -ge 1 && $PORT -le 65535 ]] || exit 1
systemctl is-active --quiet x-ui || { echo '3X-UI is not active; aborting' >&2; exit 1; }
ss -H -ltn "( sport = :$PORT )" | grep -q LISTEN || {
  echo "VPN port $PORT not listening before upgrade; aborting" >&2
  exit 1
}
echo "Current Xray: $current_version"
echo "Target Xray: $VERSION; VPN port: $PORT"
curl -fsSL --retry 3 -o "$DIR/Xray-linux-64.zip" \
  "$RELEASE_URL"
printf '%s  %s\n' "$EXPECTED_SHA256" "$DIR/Xray-linux-64.zip" | sha256sum -c -
python3 - "$DIR" <<'PY'
import pathlib, sys, zipfile
base = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(base / 'Xray-linux-64.zip') as z:
    if 'xray' not in z.namelist():
        raise SystemExit('Missing xray executable in archive')
    (base / 'xray-new').write_bytes(z.read('xray'))
(base / 'xray-new').chmod(0o755)
PY
new_version=$("$DIR/xray-new" version | sed -n '1p')
[[ $new_version == "Xray $VERSION "* ]] || { echo "Wrong binary version: $new_version" >&2; exit 1; }
CONFIG=/usr/local/x-ui/bin/config.json
if [[ -s "$CONFIG" ]]; then
  XRAY_LOCATION_ASSET=/usr/local/x-ui/bin "$DIR/xray-new" run -test -config "$CONFIG"
else
  echo 'No static config.json found; validate after x-ui restart'
fi

# Always snapshot the working binary immediately before changing it.
cp -a "$BIN" "$DIR/xray-previous"
chmod 600 "$DIR/xray-previous"
changed=0
rollback() {
  local rc=$?
  trap - ERR
  echo "Upgrade health check failed (exit $rc). Restoring previous Xray." >&2
  if [[ "$changed" == 1 ]]; then
    install -o root -g root -m 755 "$DIR/xray-previous" "${BIN}.revert"
    mv -f "${BIN}.revert" "$BIN"
    systemctl restart x-ui || true
  fi
  journalctl -u x-ui -n 18 --no-pager -o cat >&2 || true
  exit "$rc"
}
trap rollback ERR
install -o root -g root -m 755 "$DIR/xray-new" "${BIN}.new"
mv -f "${BIN}.new" "$BIN"
changed=1
systemctl restart x-ui

# x-ui can reach active before its child Xray binds the VPN listener.
healthy=0
for attempt in $(seq 1 30); do
  service_state=$(systemctl is-active x-ui 2>/dev/null || true)
  listener=$(ss -H -ltn "( sport = :$PORT )" 2>/dev/null || true)
  process=$(pgrep -f '^bin/xray-linux-amd64 -c bin/config.json$' || true)
  if [[ "$service_state" == active && "$listener" == *LISTEN* && -n "$process" ]]; then
    healthy=1
    break
  fi
  sleep 1
done
if [[ "$healthy" != 1 ]]; then
  echo "After 30s: service=$service_state, listener=${listener:-none}, xray_pids=${process:-none}" >&2
  false
fi
installed_version=$("$BIN" version | sed -n '1p')
[[ "$installed_version" == "Xray $VERSION "* ]] || {
  echo "Installed binary version mismatch: $installed_version" >&2
  false
}
trap - ERR
echo "Xray upgraded to $VERSION; running listener $PORT confirmed."
echo "Previous binary retained at $DIR/xray-previous"
