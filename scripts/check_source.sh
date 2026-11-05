#!/usr/bin/env bash
set -Eeuo pipefail
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE"
echo '=== Bash syntax ==='
while IFS= read -r -d '' f; do
  bash -n "$f"
  echo "OK $f"
done < <(find . -name '*.sh' -type f -print0)
echo '=== Python syntax (without writing pycache) ==='
python3 - <<'PY'
from pathlib import Path
for path in Path('scripts').rglob('*.py'):
    compile(path.read_bytes(), str(path), 'exec')
    print('OK', path)
PY
echo '=== Sensitive files tracked in Git ==='
if git ls-files | grep -E '(^|/)(config[.]env|install-result[.]env|x-ui[.]db)$|[.](pem|key|vless)$'; then
  echo 'ERROR: sensitive file tracked' >&2
  exit 1
fi
echo 'Static source checks: OK'
