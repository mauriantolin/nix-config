#!/usr/bin/env bash
# Smoke test Fase E.2d — Jellyseerr + CF Tunnel
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

echo "=== Smoke test Fase E.2d ==="

check "1 dataset E.2d mounted (jellyseerr)" ssh "$HOST" "
  mountpoint -q /var/lib/jellyseerr"

check "2 jellyseerr active" ssh "$HOST" '
  sudo systemctl is-active jellyseerr | grep -q "^active$"'

check "3 jellyseerr listening on 127.0.0.1:5055 only" ssh "$HOST" "
  sudo ss -tnlp | grep -q '127.0.0.1:5055' && \
  ! sudo ss -tnlp | grep -E ':5055' | grep -qv '127.0.0.1'"

check "4 jellyseerr /api/v1/status returns 200" ssh "$HOST" '
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:5055/api/v1/status)
  [ "$CODE" = "200" ]'

check "5 jellyseerr-bootstrap.service ran clean" ssh "$HOST" "
  sudo systemctl is-active jellyseerr-bootstrap.service | grep -qE 'active'"

check "6 jellyseerr initialized=true (wizard hecho)" ssh "$HOST" '
  curl -sf http://127.0.0.1:5055/api/v1/settings/public | jq -r .initialized | grep -q true'

check "7 cloudflared sumó requests.* a ingress config" ssh "$HOST" "
  sudo systemctl status cloudflared --no-pager | grep -q 'requests.mauricioantolin.com' || \
  sudo cat /etc/cloudflared/config.yml 2>/dev/null | grep -q 'requests.mauricioantolin.com'"

check "8 requests.* via CF Tunnel responde (sin auth bypass debe ser 200/302/401)" bash -c '
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 https://requests.mauricioantolin.com/api/v1/status 2>/dev/null)
  # 200 si CF Access bypass; 302 si redirect a CF Access login; cualquier otra cosa = error
  [ "$CODE" = "200" ] || [ "$CODE" = "302" ]'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase E.2d verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
