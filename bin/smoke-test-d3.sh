#!/usr/bin/env bash
# Smoke test Fase D.3 — Keycloak SSO (Quarkus, postgres-shared, encrypted ZFS).
# Convención: igual que smoke-test-e1.sh — check name + comando, exit code = #fails.
set -uo pipefail

HOST="${HOST:-mauri@home-server}"
FAIL=0

check() {
  local name="$1"
  shift
  printf '%-65s ' "$name"
  if "$@" >/dev/null 2>&1; then
    echo OK
  else
    echo FAIL
    FAIL=1
  fi
}

echo "=== Smoke test Fase D.3 (Keycloak SSO) ==="

# === ZFS dataset + cifrado ===

check "1 dataset rpool/services/keycloak existe" ssh "$HOST" "
  sudo zfs list -H -o name rpool/services/keycloak"

check "2 dataset cifrado con aes-256-gcm" ssh "$HOST" "
  sudo zfs get -H -o value encryption rpool/services/keycloak | grep -q '^aes-256-gcm$'"

check "3 keystatus = available (key cargada)" ssh "$HOST" "
  sudo zfs get -H -o value keystatus rpool/services/keycloak | grep -q '^available$'"

check "4 keylocation apunta a /run/agenix/keycloakZfsKey" ssh "$HOST" "
  sudo zfs get -H -o value keylocation rpool/services/keycloak | grep -q '^file:///run/agenix/keycloakZfsKey$'"

check "5 /var/lib/keycloak está montado (zfs)" ssh "$HOST" "
  mountpoint -q /var/lib/keycloak && \
  findmnt -no FSTYPE /var/lib/keycloak | grep -q '^zfs$'"

# === agenix secrets visibles bajo /run/agenix ===

check "6 keycloakZfsKey decryptado por agenix (32 bytes)" ssh "$HOST" "
  sudo test -s /run/agenix/keycloakZfsKey && \
  [ \$(sudo wc -c < /run/agenix/keycloakZfsKey) -eq 32 ]"

check "7 keycloak-db-pass + keycloak-admin-pass disponibles" ssh "$HOST" "
  sudo test -s /run/agenix/keycloak-db-pass && \
  sudo test -s /run/agenix/keycloak-admin-pass"

# === postgres-shared: DB + user keycloak ===

check "8 postgres DB 'keycloak' existe + owner='keycloak'" ssh "$HOST" "
  sudo -u postgres psql -tAc \"SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='keycloak'\" | grep -q '^keycloak\$'"

check "9 user keycloak puede autenticar contra su DB" ssh "$HOST" "
  pass=\$(sudo cat /run/agenix/keycloak-db-pass)
  PGPASSWORD=\"\$pass\" psql -h 127.0.0.1 -U keycloak -d keycloak -tAc 'SELECT 1' | grep -q '^1\$'"

# === keycloak.service ===

check "10 keycloak.service active (running)" ssh "$HOST" "
  sudo systemctl is-active keycloak.service | grep -q '^active$'"

check "11 keycloak escucha 127.0.0.1:8180 (no LAN/WAN)" ssh "$HOST" "
  sudo ss -tnlp | grep -q '127.0.0.1:8180' && \
  ! sudo ss -tnlp | grep -E ':8180' | grep -qv '127.0.0.1'"

check "12 /health/ready devuelve UP (management port :9000)" ssh "$HOST" "
  curl -sf -m 10 http://127.0.0.1:9000/health/ready | grep -q '\"status\": \"UP\"'"

# === bootstrap oneshot ===

check "13 keycloak-bootstrap.service ejecutó sin error" ssh "$HOST" "
  sudo systemctl is-active keycloak-bootstrap.service | grep -qE '^(active|inactive)$' && \
  ! sudo systemctl is-failed keycloak-bootstrap.service | grep -q '^failed$'"

check "14 bootstrap log: 'DONE' al final" ssh "$HOST" "
  sudo journalctl -u keycloak-bootstrap.service --no-pager -n 200 | grep -q '\\[bootstrap\\] DONE'"

# === realm 'homelab' importado ===

check "15 realm 'homelab' accesible" ssh "$HOST" "
  curl -sf -m 10 http://127.0.0.1:8180/realms/homelab/.well-known/openid-configuration | jq -e '.issuer' | grep -q 'realms/homelab'"

check "16 admin login con pass real (master realm, user='admin')" ssh "$HOST" "
  pass=\$(sudo cat /run/agenix/keycloak-admin-pass)
  curl -sf -X POST 'http://127.0.0.1:8180/realms/master/protocol/openid-connect/token' \
    -d 'username=admin' --data-urlencode \"password=\$pass\" \
    -d 'grant_type=password&client_id=admin-cli' | jq -e .access_token >/dev/null"

check "17 placeholder admin pass YA NO sirve (rotated)" ssh "$HOST" "
  CODE=\$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    'http://127.0.0.1:8180/realms/master/protocol/openid-connect/token' \
    -d 'username=admin&password=BOOTSTRAP_PLACEHOLDER_X47Tq9_DO_NOT_USE&grant_type=password&client_id=admin-cli')
  [ \"\$CODE\" = '401' ]"

# === clients OIDC en realm homelab ===

check "18 13 OIDC clients presentes en realm 'homelab'" ssh "$HOST" "
  pass=\$(sudo cat /run/agenix/keycloak-admin-pass)
  TOKEN=\$(curl -sf -X POST 'http://127.0.0.1:8180/realms/master/protocol/openid-connect/token' \
    -d 'username=admin' --data-urlencode \"password=\$pass\" \
    -d 'grant_type=password&client_id=admin-cli' | jq -r .access_token)
  COUNT=\$(curl -sf -H \"Authorization: Bearer \$TOKEN\" \
    'http://127.0.0.1:8180/admin/realms/homelab/clients' | jq '[.[] | select(.clientId | test(\"^(vaultwarden|paperless|grafana|jellyfin|jellyseerr|oauth2proxy-)\"))] | length')
  [ \"\$COUNT\" = '13' ]"

# === ingress público ===

check "19 auth.mauricioantolin.com vía CF Tunnel responde" bash -c '
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -L --max-redirs 0 \
    https://auth.mauricioantolin.com/realms/homelab/.well-known/openid-configuration 2>/dev/null)
  # Esperado 200 (Keycloak es ingress público sin CF Access).
  [ "$CODE" = "200" ]'

check "20 hostname-strict: Host header LAN no aceptado (rechaza :8180 sin host válido)" ssh "$HOST" "
  CODE=\$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Host: home-server.local' \
    http://127.0.0.1:8180/admin/master/console/)
  # Con hostname-strict=true, requests con Host distinto a auth.* devuelven 404/400.
  [ \"\$CODE\" != '200' ]"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase D.3 verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
