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


# Phase 4 — fail2ban-cloudflare
check "4.1 fail2ban jail vaultwarden activo"                 ssh "$HOST" "sudo fail2ban-client status vaultwarden >/dev/null"
check "4.2 action cloudflare-homelab declarada"              ssh "$HOST" "sudo test -f /etc/fail2ban/action.d/cloudflare-homelab.conf"
check "4.3 ban/unban 203.0.113.99 round-trip con CF API"     ssh "$HOST" '
  sudo fail2ban-client set vaultwarden banip 203.0.113.99 >/dev/null 2>&1
  sleep 3
  TOKEN=$(sudo cat /run/agenix/cloudflareApiToken)
  ZID=$(sudo curl -sS -H "Authorization: Bearer $TOKEN" "https://api.cloudflare.com/client/v4/zones?name=mauricioantolin.com" | jq -r ".result[0].id")
  HIT=$(sudo curl -sS -H "Authorization: Bearer $TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZID/firewall/access_rules/rules?configuration.value=203.0.113.99" | jq ".result | length")
  sudo fail2ban-client set vaultwarden unbanip 203.0.113.99 >/dev/null 2>&1
  [ "$HIT" = "1" ]
'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase C.1 verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
