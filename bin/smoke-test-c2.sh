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
# check "9.X smb.service active"                   ssh "$HOST" "systemctl is-active smb"
# ...

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase C.2 verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
