#!/usr/bin/env bash
# Smoke test Fase E.2a — Jellyfin + media datasets + QSV + Tailscale Serve
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

echo "=== Smoke test Fase E.2a ==="

# === datasets ===

check "1 datasets E.2a mounted (jellyfin/cache + media subdirs)" ssh "$HOST" "
  mountpoint -q /var/lib/jellyfin && \
  mountpoint -q /var/cache/jellyfin && \
  mountpoint -q /srv/storage/media/movies && \
  mountpoint -q /srv/storage/media/tv && \
  mountpoint -q /srv/storage/media/music"

check "2 media dirs ownership=jellyfin:media + setgid (2775)" ssh "$HOST" '
  for d in /srv/storage/media/movies /srv/storage/media/tv /srv/storage/media/music; do
    perms=$(stat -c "%a %U %G" "$d")
    [ "$perms" = "2775 jellyfin media" ] || { echo "FAIL: $d → $perms"; exit 1; }
  done'

# === Jellyfin service ===

check "3 jellyfin listening on :8096 (firewall bloquea LAN)" ssh "$HOST" "
  sudo ss -tnlp | grep -qE ':8096'"

check "4 jellyfin /System/Info/Public returns 200 + JSON" ssh "$HOST" '
  RESP=$(curl -sf http://127.0.0.1:8096/System/Info/Public)
  echo "$RESP" | grep -q "\"ServerName\""'

check "5 jellyfin via Tailscale Serve :8196 responde" ssh "$HOST" '
  CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 https://home-server.tailee5654.ts.net:8196/System/Info/Public)
  [ "$CODE" = "200" ]'

# === HW accel ===

check "6 /dev/dri/renderD128 existe (iGPU expuesta)" ssh "$HOST" '
  test -c /dev/dri/renderD128'

check "7 jellyfin user en grupos render+video+media" ssh "$HOST" '
  groups jellyfin | grep -q render && \
  groups jellyfin | grep -q video && \
  groups jellyfin | grep -q media'

check "8 jellyfin puede leer /dev/dri/renderD128" ssh "$HOST" '
  sudo -u jellyfin test -r /dev/dri/renderD128'

# === Bootstrap ===

check "9 jellyfin-bootstrap.service ran clean (admin user creado)" ssh "$HOST" "
  sudo systemctl is-active jellyfin-bootstrap.service | grep -q active && \
  sudo journalctl -u jellyfin-bootstrap --no-pager -n 50 | grep -qE 'admin user|wizard already completed'"

check "10 3 libraries provisionadas (Movies/TV Shows/Music)" ssh "$HOST" '
  PASS=$(sudo cat /run/agenix/jellyfinAdminPass)
  TOKEN=$(curl -sf -X POST http://127.0.0.1:8096/Users/AuthenticateByName \
    -H "Content-Type: application/json" \
    -H "Authorization: MediaBrowser Client=\"smoke\", Device=\"smoke\", DeviceId=\"smoke\", Version=\"1\"" \
    -d "{\"Username\":\"mauri\",\"Pw\":\"$PASS\"}" | jq -r .AccessToken)
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || exit 1
  COUNT=$(curl -sf http://127.0.0.1:8096/Library/VirtualFolders -H "X-Emby-Token: $TOKEN" | jq "length")
  [ "$COUNT" -ge 3 ]'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase E.2a verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
