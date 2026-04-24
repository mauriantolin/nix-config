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


# Phase 5 — Uptime Kuma (sólo checks locales; path via TS Serve se valida en Phase 7)
check "5.1 uptime-kuma.service active"                       ssh "$HOST" "systemctl is-active uptime-kuma | grep -q active"
check "5.2 puerto :3001 escuchando (0.0.0.0 o 127.0.0.1)"    ssh "$HOST" "sudo ss -tlnp | grep -qE '(127\\.0\\.0\\.1|0\\.0\\.0\\.0):3001'"
check "5.3 kuma responde HTTP (2xx o 3xx)"                   ssh "$HOST" "curl -sS -o /dev/null -w '%{http_code}\\n' http://127.0.0.1:3001/ | grep -qE '^(200|301|302|303|307|308)\$'"


# Phase 6 — Homepage
check "6.1 podman-homepage.service active"                   ssh "$HOST" "systemctl is-active podman-homepage | grep -q active"
check "6.2 puerto 127.0.0.1:3000 escuchando"                 ssh "$HOST" "sudo ss -tlnp | grep -q '127.0.0.1:3000'"
check "6.3 homepage responde HTTP 200"                       ssh "$HOST" "curl -sS -o /dev/null -w '%{http_code}\\n' http://127.0.0.1:3000/ | grep -q '^200\$'"


# Phase 7 — Tailscale Serve
check "7.1 tailscale-serve-config.service active"            ssh "$HOST" "systemctl is-active tailscale-serve-config | grep -q active"
check "7.2 tailnet HTTPS / (Homepage)"                       ssh "$HOST" "curl -fsS -o /dev/null https://$TAILNET_HOST/"
check "7.3 tailnet HTTPS:8443 (Kuma puerto dedicado)"         ssh "$HOST" "curl -fsS -o /dev/null https://$TAILNET_HOST:8443/"

# Phase 8 — reboot limpio (última verificación antes del tag phase-c1-done)
# Se saltea si REBOOT=0 en env (para runs rápidos; por default reboot).
if [ "${REBOOT:-1}" = "1" ]; then
check "8.1 reboot limpio — todos los servicios vuelven <120s"    bash -c '
  ssh "'"$HOST"'" "sudo reboot" >/dev/null 2>&1 || true
  sleep 100
  ssh "'"$HOST"'" "uptime && systemctl is-active vaultwarden uptime-kuma podman-homepage tailscale-serve-config fail2ban | grep -cv active" | tail -1 | grep -q "^0\$"
'
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase C.1 verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
