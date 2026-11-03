#!/usr/bin/env bash
# tests/run.sh IMAGE: every check a release must pass, in throwaway containers.
# ENGINE=docker for CI (default: podman).
set -euo pipefail
IMG=${1:?usage: tests/run.sh IMAGE}
ENGINE=${ENGINE:-podman}
podman() { command "$ENGINE" "$@"; }
VOL=ro; [[ $ENGINE == podman ]] && VOL=ro,Z
T=$(cd "$(dirname "$0")" && pwd)
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; rc=1; }
rc=0

echo "== versions"
podman run --rm --entrypoint sh "$IMG" -c '
  set -e
  dpkg --compare-versions "$(dpkg-query -W -f="\${Version}" libbrotli1)" ge 1.1.0-2+deb13u1
  test "$(cat /etc/hermes/chromium-executable-path)" = /usr/bin/chromium
  ! find /opt/hermes/tools -type f \( -name chrome -o -name chromium \) | grep -q .   # no bundled Chrome left
  (cd /opt/hermes && /opt/hermes/.venv/bin/python -c "
import sys; sys.path.insert(0, \"/opt/hermes\")
import os
try:
    from hermes_cli.browser_runtime import chromium_executable as ce
except ImportError:
    ce = None
p = ce(allow_override=False) if ce else None
print(\"hermes resolves chromium:\", p)
assert p is None or os.path.realpath(p).startswith(\"/usr/lib/chromium\") or os.path.realpath(p) == \"/usr/bin/chromium\", p")
  /opt/hermes/.venv/bin/python -c "
import importlib.metadata as m, brotlicffi
need = {\"brotlicffi\": (1,2,1,0), \"pyasn1\": (0,6,5), \"tornado\": (6,6), \"pypdf\": (6,21,4)}
for p, v in list(need.items()):
    try:
        have = tuple(int(x) for x in m.version(p).split(\".\"))
    except m.PackageNotFoundError:
        need.pop(p); continue          # not in this Hermes release
    assert have >= v, f\"{p} {have} < {v}\"
d = b\"x\" * 4096; assert brotlicffi.decompress(brotlicffi.compress(d)) == d
print(\"python ok:\", {p: m.version(p) for p in need})"
  chromium --version
  hermes --version | sed -n 1p' && pass "patched versions" || fail "patched versions"

echo "== tools"
podman run --rm --entrypoint sh "$IMG" -c '
  set -e
  docker --version; ! dpkg -s docker-cli >/dev/null 2>&1
  test "$(npm --version)" = 12.2.1
  for n in /opt/hermes/tools/node-*/lib/node_modules/npm /opt/hermes/tools/npm-*/lib/node_modules/npm; do
    test "$(node -p "require(\"$n/package.json\").version")" = 12.2.1
    test "$(node -p "require(\"$n/node_modules/undici/package.json\").version")" = 6.29.1; done
  npm view npm version >/dev/null   # npm itself still works (registry fetch through its undici)
  npx --version >/dev/null
  cd /opt/hermes/plugins/platforms/photon/sidecar
  test "$(node -p "require(\"./node_modules/undici/package.json\").version")" = 7.30.1
  node --input-type=module -e "await import(\"spectrum-ts\")"
  cd /opt/hermes && python3 -c "from pm import installed_package as i; assert i(\"npm\") and i(\"node\")"
  echo "tools ok"' && pass "docker, npm, photon sidecar, pm records" || fail "tools"

echo "== boot (stage2 exports the Chromium path)"
log=$(timeout 300 podman run --rm "$IMG" --version 2>&1 || true)
grep -qE "Chromium binary: /usr/bin/chromium" <<<"$log" && pass "stage2 uses /usr/bin/chromium" \
  || fail "stage2 Chromium line missing: $(grep -i chrom <<<"$log" | head -2)"
! grep -qi "chromium binary is missing" <<<"$log" || fail "stage2 says the Chromium binary is missing"
grep -q "Hermes Agent v" <<<"$log" && pass "hermes starts through the entrypoint" || fail "no version through the entrypoint"

echo "== browser end to end"
podman run --rm -v "$T":/t:$VOL --entrypoint sh "$IMG" -c '
  export HERMES_HOME=/tmp/hh   # no override: Hermes resolves its browser itself, as in production
  mkdir -p /tmp/hh; (cd /t && exec python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1) &
  sleep 1; cd /opt/hermes; timeout 300 /opt/hermes/.venv/bin/python /t/browser_e2e.py' \
  && pass "browser tool" || fail "browser tool"

echo "== functional (the code paths that use the updated packages)"
podman run --rm -v "$T":/t:$VOL --entrypoint sh "$IMG" /t/functional.sh \
  && pass "PDF skill, brotli, google-auth, tornado, Chromium, npm" || fail "functional"

exit $rc
