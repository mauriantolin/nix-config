#!/usr/bin/env bash
# Smoke test Fase C.1 — Vaultwarden + Uptime Kuma + Homepage + TS Serve + fail2ban-cloudflare
# Se agregan checks a medida que cada sub-task cierra. Al llegar a Task 8.1 debe tener 9.
set -euo pipefail

HOST="${HOST:-mauri@home-server}"
ZONE="${ZONE:-mauricioantolin.com}"
TAILNET_HOST="${TAILNET_HOST:-home-server.tailee5654.ts.net}"
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

echo "=== Smoke test Fase C.1 ==="
echo "(stub — los checks se agregan a medida que cada phase cierra)"

# Phase 3 — Vaultwarden
check "3.1 vaultwarden.service active"                       ssh "$HOST" "systemctl is-active vaultwarden | grep -q active"
check "3.2 puerto 127.0.0.1:8222 escuchando"                 ssh "$HOST" "sudo ss -tlnp | grep -q '127.0.0.1:8222'"
check "3.3 /alive responde via CF tunnel"                    curl -fsS "https://vault.$ZONE/alive"
check "3.4 admin token montado owner vaultwarden"            ssh "$HOST" "sudo test -s /run/agenix/vaultwardenAdminToken"
check "3.5 signups cerrados (/api/accounts/register 4xx)"    bash -c 'CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "https://vault.'"$ZONE"'/api/accounts/register" -H "Content-Type: application/json" -d "{}"); [ "$CODE" -ge 400 ]'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase C.1 verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
