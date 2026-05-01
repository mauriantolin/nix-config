#!/usr/bin/env bash
# Smoke test Fase D.4a — Native-OIDC SSO en servicios homelab.
# Cubre Grafana + Paperless (OIDC nativo automatizable) + Vaultwarden (fork
# Timshel build) + Jellyfin (plugin 9p4/jellyfin-plugin-sso install).
# Jellyseerr hereda de Jellyfin (auth via /api/v1/auth/jellyfin) — no checks
# directos.
#
# Convención: misma que smoke-test-d3.sh — check name + comando, exit = #fails.
set -uo pipefail

HOST="${HOST:-mauri@home-server}"
FAIL=0

check() {
  local name="$1"
  shift
  printf '%-70s ' "$name"
  if "$@" >/dev/null 2>&1; then
    echo OK
  else
    echo FAIL
    FAIL=1
  fi
}

echo "=== Smoke test Fase D.4a (native-OIDC services) ==="

# === Grafana — auth.generic_oauth ===

check "1 grafana.service active" ssh "$HOST" "
  sudo systemctl is-active grafana | grep -q '^active$'"

check "2 oidc-client-grafana secret legible por user grafana" ssh "$HOST" "
  sudo -u grafana test -r /run/agenix/oidcClientGrafana"

check "3 grafana login HTML expone provider Keycloak/generic_oauth" ssh "$HOST" '
  # Grafana renderiza el button via React props (config.oauth en window.grafanaBootData);
  # match strings claves en el bootstrap HTML.
  curl -sf http://127.0.0.1:3030/login | grep -qiE "(generic_oauth|keycloak)"'

check "4 grafana /login/generic_oauth redirect → KC con PKCE + scopes correctos" ssh "$HOST" '
  loc=$(curl -sf -o /dev/null -w "%{redirect_url}" "http://127.0.0.1:3030/login/generic_oauth")
  echo "$loc" | grep -q "auth.mauricioantolin.com/realms/homelab/protocol/openid-connect/auth" && \
  echo "$loc" | grep -q "client_id=grafana" && \
  echo "$loc" | grep -q "code_challenge_method=S256" && \
  echo "$loc" | grep -q "scope=openid" && echo "$loc" | grep -q "roles"'

# === Paperless — allauth.socialaccount.providers.openid_connect ===

check "5 paperless-web.service active" ssh "$HOST" "
  sudo systemctl is-active paperless-web | grep -q '^active$'"

check "6 oidc-client-paperless secret legible por user paperless" ssh "$HOST" "
  sudo -u paperless test -r /run/agenix/oidcClientPaperless"

check "7 paperless env file rinde SOCIALACCOUNT_PROVIDERS con quotes válidas" ssh "$HOST" "
  sudo bash -c 'set -a; . /run/paperless-env/db.env; [ \${#PAPERLESS_SOCIALACCOUNT_PROVIDERS} -gt 200 ]'"

check "8 paperless POST /accounts/oidc/keycloak/login/ → 302 a Keycloak" ssh "$HOST" '
  COOKIES=$(mktemp); LOGIN=$(mktemp)
  curl -s -c "$COOKIES" "http://127.0.0.1:8000/accounts/login/" -o "$LOGIN"
  CSRF=$(grep -oE "csrfmiddlewaretoken[^>]*value=\"[^\"]*" "$LOGIN" | head -1 | sed "s/.*value=\"//")
  loc=$(curl -s -b "$COOKIES" -c "$COOKIES" -X POST "http://127.0.0.1:8000/accounts/oidc/keycloak/login/" \
    -d "csrfmiddlewaretoken=$CSRF" -H "Referer: http://127.0.0.1:8000/accounts/login/" \
    -o /dev/null -w "%{redirect_url}")
  rm -f "$COOKIES" "$LOGIN"
  echo "$loc" | grep -q "auth.mauricioantolin.com/realms/homelab/protocol/openid-connect/auth" && \
  echo "$loc" | grep -q "client_id=paperless" && \
  echo "$loc" | grep -q "code_challenge_method=S256"'

# === Realm-side: clients tienen secret real (no placeholder) ===

check "9 KC client 'grafana' tiene secret real (no REPLACE_SECRET)" ssh "$HOST" "
  pass=\$(sudo cat /run/agenix/keycloak-admin-pass)
  TOKEN=\$(curl -sf -X POST 'http://127.0.0.1:8180/realms/master/protocol/openid-connect/token' \
    -d 'username=admin' --data-urlencode \"password=\$pass\" \
    -d 'grant_type=password&client_id=admin-cli' | jq -r .access_token)
  ID=\$(curl -sf -H \"Authorization: Bearer \$TOKEN\" 'http://127.0.0.1:8180/admin/realms/homelab/clients?clientId=grafana' | jq -r '.[0].id')
  SECRET=\$(curl -sf -H \"Authorization: Bearer \$TOKEN\" \"http://127.0.0.1:8180/admin/realms/homelab/clients/\$ID/client-secret\" | jq -r .value)
  [ \${#SECRET} -ge 32 ] && [ \"\$SECRET\" != 'REPLACE_SECRET_grafana' ]"

check "10 KC client 'paperless' tiene secret real" ssh "$HOST" "
  pass=\$(sudo cat /run/agenix/keycloak-admin-pass)
  TOKEN=\$(curl -sf -X POST 'http://127.0.0.1:8180/realms/master/protocol/openid-connect/token' \
    -d 'username=admin' --data-urlencode \"password=\$pass\" \
    -d 'grant_type=password&client_id=admin-cli' | jq -r .access_token)
  ID=\$(curl -sf -H \"Authorization: Bearer \$TOKEN\" 'http://127.0.0.1:8180/admin/realms/homelab/clients?clientId=paperless' | jq -r '.[0].id')
  SECRET=\$(curl -sf -H \"Authorization: Bearer \$TOKEN\" \"http://127.0.0.1:8180/admin/realms/homelab/clients/\$ID/client-secret\" | jq -r .value)
  [ \${#SECRET} -ge 32 ] && [ \"\$SECRET\" != 'REPLACE_SECRET_paperless' ]"

# === Vaultwarden — fork Timshel con SSO nativo ===

check "11 vaultwarden.service active (fork Timshel 1.35.8)" ssh "$HOST" "
  sudo systemctl is-active vaultwarden | grep -q '^active$'"

check "12 VW combined.env tiene SSO_CLIENT_SECRET" ssh "$HOST" "
  sudo grep -q '^SSO_CLIENT_SECRET=' /run/vaultwarden-sso/combined.env"

check "13 VW /identity/sso/prevalidate → 200" ssh "$HOST" '
  curl -sf -o /dev/null http://127.0.0.1:8222/identity/sso/prevalidate'

check "14 VW webvault es OIDCWarden (variant button)" ssh "$HOST" '
  curl -s http://127.0.0.1:8222/ | grep -q "OIDCWarden Web vault"'

check "15 KC client 'vaultwarden' tiene secret real" ssh "$HOST" "
  pass=\$(sudo cat /run/agenix/keycloak-admin-pass)
  TOKEN=\$(curl -sf -X POST 'http://127.0.0.1:8180/realms/master/protocol/openid-connect/token' \
    -d 'username=admin' --data-urlencode \"password=\$pass\" \
    -d 'grant_type=password&client_id=admin-cli' | jq -r .access_token)
  ID=\$(curl -sf -H \"Authorization: Bearer \$TOKEN\" 'http://127.0.0.1:8180/admin/realms/homelab/clients?clientId=vaultwarden' | jq -r '.[0].id')
  SECRET=\$(curl -sf -H \"Authorization: Bearer \$TOKEN\" \"http://127.0.0.1:8180/admin/realms/homelab/clients/\$ID/client-secret\" | jq -r .value)
  [ \${#SECRET} -ge 32 ] && [ \"\$SECRET\" != 'REPLACE_SECRET_vaultwarden' ]"

# === Jellyfin — plugin 9p4/jellyfin-plugin-sso ===

check "16 jellyfin.service active" ssh "$HOST" "
  sudo systemctl is-active jellyfin | grep -q '^active$'"

check "17 SSO-Auth plugin .dll instalado" ssh "$HOST" "
  sudo test -f /var/lib/jellyfin/plugins/SSO-Auth_4.0.0.3/SSO-Auth.dll"

check "18 SSO-Auth plugin loaded por jellyfin (journalctl)" ssh "$HOST" '
  sudo journalctl -u jellyfin -n 200 --no-pager | grep -q "Loaded plugin: SSO-Auth"'

check "19 plugin endpoint /sso/OID/States responde (rejects GET con 405 = unit alive)" ssh "$HOST" '
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8096/sso/OID/States)
  [ "$code" = "405" ] || [ "$code" = "401" ] || [ "$code" = "200" ]'

check "20 KC client 'jellyfin' tiene secret real" ssh "$HOST" "
  pass=\$(sudo cat /run/agenix/keycloak-admin-pass)
  TOKEN=\$(curl -sf -X POST 'http://127.0.0.1:8180/realms/master/protocol/openid-connect/token' \
    -d 'username=admin' --data-urlencode \"password=\$pass\" \
    -d 'grant_type=password&client_id=admin-cli' | jq -r .access_token)
  ID=\$(curl -sf -H \"Authorization: Bearer \$TOKEN\" 'http://127.0.0.1:8180/admin/realms/homelab/clients?clientId=jellyfin' | jq -r '.[0].id')
  SECRET=\$(curl -sf -H \"Authorization: Bearer \$TOKEN\" \"http://127.0.0.1:8180/admin/realms/homelab/clients/\$ID/client-secret\" | jq -r .value)
  [ \${#SECRET} -ge 32 ] && [ \"\$SECRET\" != 'REPLACE_SECRET_jellyfin' ]"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase D.4a (Grafana + Paperless + Vaultwarden + Jellyfin) verde"
  echo
  echo "MANUAL — Jellyfin SSO provider config:"
  echo "  jellyfin-sso-bootstrap es tolerante (exit 0 con warning) si el password en"
  echo "  agenix no matches el set en la UI inicial. Workaround:"
  echo "  Dashboard → Plugins → SSO-Auth → Add OID provider:"
  echo "    Endpoint: https://auth.mauricioantolin.com/realms/homelab"
  echo "    ClientId: jellyfin    Secret: \$(sudo cat /run/agenix/jellyfinSsoSecret 2>/dev/null)"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
