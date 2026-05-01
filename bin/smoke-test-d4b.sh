#!/usr/bin/env bash
# Smoke test Fase D.4b — oauth2-proxy multi-instancia frente a 8 servicios sin
# OIDC nativo (sonarr, radarr, prowlarr, bazarr, deluge, homepage, kuma,
# prometheus). Una instancia oauth2-proxy = un client OIDC en realm homelab.
#
# Convención: misma que smoke-test-d4a.sh — check name + comando, exit = #fails.
set -uo pipefail

HOST="${HOST:-mauri@home-server}"
FAIL=0

check() {
  local name="$1"
  shift
  printf '%-78s ' "$name"
  if "$@" >/dev/null 2>&1; then
    echo OK
  else
    echo FAIL
    FAIL=1
  fi
}

echo "=== Smoke test Fase D.4b (oauth2-proxy multi-instancia) ==="

# === 1-8: las 8 systemd units están active ===
i=1
for svc in sonarr radarr prowlarr bazarr deluge homepage kuma prometheus; do
  check "$i oauth2-proxy-$svc.service active" ssh "$HOST" "
    sudo systemctl is-active oauth2-proxy-$svc | grep -q '^active$'"
  i=$((i+1))
done

# === 9-16: cada instancia escucha en su listenPort y responde 302 a KC ===
declare -A PORTS=(
  [sonarr]=4181 [radarr]=4182 [prowlarr]=4183 [bazarr]=4184
  [deluge]=4185 [homepage]=4186 [kuma]=4187 [prometheus]=4188
)
i=9
for svc in sonarr radarr prowlarr bazarr deluge homepage kuma prometheus; do
  port="${PORTS[$svc]}"
  check "$i oauth2-proxy-$svc redirect → KC con client_id=oauth2proxy-$svc" ssh "$HOST" "
    loc=\$(curl -s -o /dev/null -w '%{redirect_url}' http://127.0.0.1:$port/)
    echo \"\$loc\" | grep -q 'auth.mauricioantolin.com/realms/homelab/protocol/openid-connect/auth' && \
    echo \"\$loc\" | grep -q 'client_id=oauth2proxy-$svc' && \
    echo \"\$loc\" | grep -q 'scope=openid'"
  i=$((i+1))
done

# === 17-24: realm tiene secret real (no placeholder) por client ===
i=17
for svc in sonarr radarr prowlarr bazarr deluge homepage kuma prometheus; do
  check "$i KC client 'oauth2proxy-$svc' tiene secret real" ssh "$HOST" "
    pass=\$(sudo cat /run/agenix/keycloak-admin-pass)
    TOKEN=\$(curl -sf -X POST 'http://127.0.0.1:8180/realms/master/protocol/openid-connect/token' \
      -d 'username=admin' --data-urlencode \"password=\$pass\" \
      -d 'grant_type=password&client_id=admin-cli' | jq -r .access_token)
    ID=\$(curl -sf -H \"Authorization: Bearer \$TOKEN\" 'http://127.0.0.1:8180/admin/realms/homelab/clients?clientId=oauth2proxy-$svc' | jq -r '.[0].id')
    SECRET=\$(curl -sf -H \"Authorization: Bearer \$TOKEN\" \"http://127.0.0.1:8180/admin/realms/homelab/clients/\$ID/client-secret\" | jq -r .value)
    [ \${#SECRET} -ge 32 ] && [ \"\$SECRET\" != 'REPLACE_SECRET_oauth2proxy-$svc' ]"
  i=$((i+1))
done

# === 25: TS Serve external host produces redirect_uri con ese host ===
# Confirma que oauth2-proxy en reverse-proxy=true deriva el redirect_uri desde
# X-Forwarded-Host (TS Serve lo seta), no desde el listen-address loopback.
check "25 TS Serve (sonarr 9089) → redirect_uri usa host externo" ssh "$HOST" '
  loc=$(curl -sk -o /dev/null -w "%{redirect_url}" https://home-server.tailee5654.ts.net:9089/)
  echo "$loc" | grep -q "redirect_uri=https%3A%2F%2Fhome-server.tailee5654.ts.net%3A9089%2Foauth2%2Fcallback"'

# === 26: cookie-secret de la instancia es válido (32 bytes raw) ===
check "26 oauth2-proxy cookie-secret decrypta a 32 bytes raw" ssh "$HOST" '
  sudo bash -c "wc -c < /run/agenix/oauth2ProxyCookieSecret" | grep -qx 32'

# === 27: backend sigue loopback-only (sonarr 8989 NO responde via TS Serve) ===
# El handler tailscale-serve para sonarr (port 9089) ahora apunta a oauth2-proxy
# (4181), no al backend directo (8989). Si alguien tira https://...:8989, falla.
# Hay 8989 como otro tailscale-serve handler? No — solo está 9089 → oauth2-proxy.
check "27 backend sonarr (8989) NO expuesto via TS Serve directo" ssh "$HOST" '
  # 8989 no es un handler en TS Serve; tailscale serve status no debe listarlo
  # como destino de un puerto external. Fallback: curl al puerto externo 8989
  # directo del nodo tailnet → connection refused (TS no escucha).
  ! sudo "$(which tailscale)" serve status 2>/dev/null | grep -q "://127.0.0.1:8989"'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase D.4b (oauth2-proxy 8 instancias) verde"
  echo
  echo "MANUAL — Validación end-to-end requiere browser:"
  echo "  1. Browser → https://sonarr.mauricioantolin.com (o uptime, home, etc.)"
  echo "  2. Verificar redirect → auth.mauricioantolin.com (KC login)"
  echo "  3. Login con user del realm homelab → vuelve al servicio autenticado"
  echo "  4. UI del servicio carga (sonarr/radarr/etc.) — login interno propio"
  echo "     queda como fallback (los users con cuenta KC siguen pudiendo usar"
  echo "     el localadmin si SSO se rompe)."
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
