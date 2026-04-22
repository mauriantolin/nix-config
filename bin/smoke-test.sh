#!/usr/bin/env bash
# Smoke test Fase A — §7.3 del spec. Corre desde cualquier host con SSH a mauri@home-server.
set -euo pipefail

HOST="${HOST:-mauri@home-server}"
FAIL=0

check() {
  local name="$1"; shift
  printf '%-45s ' "$name"
  if "$@" >/dev/null 2>&1; then
    echo OK
  else
    echo FAIL
    FAIL=1
  fi
}

echo "=== Smoke test: $HOST ==="

check "1. SSH reachable"                ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true
check "2. Tailscale exit-node advertised" \
  ssh "$HOST" 'tailscale status --json | grep -q "\"ExitNodeOption\": true"'
check "3. nixos-rebuild dry-build OK"  \
  ssh "$HOST" 'cd ~/nix-config && sudo nixos-rebuild dry-build --flake .#home-server'
check "4. agenix: hello-secret mounted" \
  ssh "$HOST" 'test -f /run/agenix/hello-secret'
check "5. ZFS pools healthy"           \
  ssh "$HOST" 'sudo zpool status -x | grep -q "all pools are healthy"'
check "6. rpool + tank present"        \
  bash -c "ssh $HOST 'zfs list -H -o name' | grep -q '^rpool' && ssh $HOST 'zfs list -H -o name' | grep -q '^tank'"
check "7. snapshot rpool/root@smoke"   \
  ssh "$HOST" "sudo zfs snapshot -r rpool/root@smoke-\$(date +%s)"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Smoke test verde (falta criterio 7 del spec: rollback — manual)"
  exit 0
else
  echo "✗ Al menos un check falló; no taggear phase-a-done"
  exit 1
fi
