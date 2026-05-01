#!/usr/bin/env bash
# Smoke test Fase C.2 — Samba share
set -euo pipefail

HOST="${HOST:-mauri@home-server}"
TAILNET_HOST="${TAILNET_HOST:-home-server.tailee5654.ts.net}"
LAN_HOST="${LAN_HOST:-192.168.0.17}"
FAIL=0

check() {
  local name="$1"; shift
  printf '%-60s ' "$name"
  if "$@" >/dev/null 2>&1; then
    echo OK
  else
    echo FAIL
    FAIL=1
  fi
}

echo "=== Smoke test Fase C.2 ==="

# Phase 9 — Samba
check "9.1 smb.service active"                               ssh "$HOST" "systemctl is-active samba-smbd | grep -q active"
check "9.2 samba-user-setup oneshot completed"               ssh "$HOST" "systemctl is-active samba-user-setup | grep -qE '^(active|activating)$'"
check "9.3 pdbedit lista user mauri"                         ssh "$HOST" "sudo pdbedit -L | grep -q '^mauri:'"
check "9.4 listener en :445 (lo/enp2s0/tailscale0)"          ssh "$HOST" "sudo ss -tlnp | grep -q ':445'"
check "9.5 smbclient list + put/get roundtrip"               ssh "$HOST" '
  PASS=$(sudo cat /run/agenix/smbMauriPassword)
  T=$(mktemp)
  echo "smoke-$(date +%s)" > "$T"
  smbclient -L //127.0.0.1 -U "mauri%$PASS" 2>&1 | grep -q "mauri  " && \
  smbclient //127.0.0.1/mauri -U "mauri%$PASS" -c "put $T smoke.txt" 2>&1 | grep -q "putting file" && \
  smbclient //127.0.0.1/mauri -U "mauri%$PASS" -c "get smoke.txt $T.out" 2>&1 | grep -q "getting file" && \
  diff "$T" "$T.out" >/dev/null
  EC=$?
  sudo rm -f /srv/storage/shares/smoke.txt
  rm -f "$T" "$T.out"
  exit $EC
'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase C.2 verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
