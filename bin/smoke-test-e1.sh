#!/usr/bin/env bash
# Smoke test Fase E.1 — postgres-shared + paperless + radicale
# Convención: igual que smoke-test-d1.sh — check name + comando, exit code = #fails
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

echo "=== Smoke test Fase E.1 ==="

# === postgres-shared ===

check "1 postgres listening on 127.0.0.1:5432 only" ssh "$HOST" "
  sudo ss -tnlp | grep -q '127.0.0.1:5432' && \
  ! sudo ss -tnlp | grep -E ':5432' | grep -qv '127.0.0.1'"

check "2 all 5 DBs exist (paperless/grafana/nextcloud/immich/hass)" ssh "$HOST" "
  for db in paperless grafana nextcloud immich hass; do
    sudo -u postgres psql -tAc \"SELECT 1 FROM pg_database WHERE datname='\$db'\" | grep -q '^1\$' || exit 1
  done"

check "3 each DB owner matches its user (ensureDBOwnership)" ssh "$HOST" "
  for db in paperless grafana nextcloud immich hass; do
    owner=\$(sudo -u postgres psql -tAc \"SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='\$db'\")
    [ \"\$owner\" = \"\$db\" ] || exit 1
  done"

check "4 postgres-set-passwords ran clean (paperless ALTER USER OK)" ssh "$HOST" "
  sudo journalctl -u postgres-set-passwords --no-pager -n 50 | grep -q 'password set for role paperless'"

check "5 paperless can connect to its DB (auth handshake works)" ssh "$HOST" "
  pass=\$(sudo cat /run/agenix/postgresPaperlessPass)
  PGPASSWORD=\"\$pass\" psql -h 127.0.0.1 -U paperless -d paperless -tAc 'SELECT 1' | grep -q '^1\$'"

# === paperless ===

check "6 paperless web responds on 8000" ssh "$HOST" '
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/)
  [ "$CODE" = "302" ] || [ "$CODE" = "200" ]'

check "7 paperless task queue + scheduler + consumer all active" ssh "$HOST" "
  sudo systemctl is-active paperless-task-queue paperless-scheduler paperless-consumer paperless-web | \
    grep -c '^active' | grep -q '^4\$'"

check "8 paperless DB connection clean (no FATAL in journal)" ssh "$HOST" "
  ! sudo journalctl -u paperless-web --no-pager -n 200 | grep -qE 'FATAL.*paperless|password authentication failed'"

check "9 redis socket for paperless exists" ssh "$HOST" "
  sudo test -S /run/redis-paperless/redis.sock"

check "10 paperless.* via CF Tunnel responds (Access redirect)" bash -c '
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -L --max-redirs 0 \
    https://paperless.mauricioantolin.com/ 2>/dev/null)
  # Esperado: 302 a CF Access login (sin cookie). Si CF DNS aún no existe → fail (no resolution).
  [ "$CODE" = "302" ]'

# === radicale ===

check "11 radicale responds on 5232 (401 sin auth)" ssh "$HOST" '
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5232/)
  [ "$CODE" = "401" ] || [ "$CODE" = "200" ]'

check "12 cal.* via CF (BYPASS Access, radicale 401 directo)" bash -c '
  # Q1 RESUELTO: CF Access tiene bypass policy para cal.* → llega directo a radicale.
  # Si esta check da 302, probablemente falta el bypass policy en CF dashboard.
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    https://cal.mauricioantolin.com/ 2>/dev/null)
  [ "$CODE" = "401" ]'

# === datasets + samba share ===

check "13 datasets mounted (postgres + paperless + radicale + tank/docs)" ssh "$HOST" "
  mountpoint -q /var/lib/postgresql && \
  mountpoint -q /var/lib/paperless && \
  mountpoint -q /var/lib/radicale && \
  mountpoint -q /srv/docs"

check "14 samba share paperless-consume listed" ssh "$HOST" '
  PASS=$(sudo cat /run/agenix/smbMauriPassword)
  smbclient -L //127.0.0.1 -U "mauri%$PASS" 2>/dev/null | grep -q paperless-consume'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase E.1 verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
