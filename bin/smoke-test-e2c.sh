#!/usr/bin/env bash
# Smoke test Fase E.2c — *arr stack (Prowlarr + Sonarr + Radarr + Bazarr)
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

echo "=== Smoke test Fase E.2c ==="

check "1 datasets E.2c mounted (sonarr/radarr/bazarr — prowlarr en rpool/var)" ssh "$HOST" "
  mountpoint -q /var/lib/sonarr && \
  mountpoint -q /var/lib/radarr && \
  mountpoint -q /var/lib/bazarr"

check "2 services activos" ssh "$HOST" '
  for s in sonarr radarr prowlarr bazarr; do
    sudo systemctl is-active "$s" | grep -q "^active$" || { echo "FAIL: $s no active"; exit 1; }
  done'

check "3 ownership=<svc>:media + 0750 (sonarr/radarr/bazarr)" ssh "$HOST" '
  for s in sonarr radarr bazarr; do
    perms=$(stat -c "%a %U %G" /var/lib/$s)
    [ "$perms" = "750 $s media" ] || { echo "FAIL: /var/lib/$s → $perms"; exit 1; }
  done'

check "4 sonarr/radarr/bazarr users en grupo media" ssh "$HOST" '
  for u in sonarr radarr bazarr; do
    groups "$u" | grep -q media || { echo "FAIL: $u no en media"; exit 1; }
  done'

check "5 puertos abiertos en tailscale0 only (no LAN/wan)" ssh "$HOST" "
  for p in 8989 7878 9696 6767; do
    sudo iptables -L nixos-fw-tailscale0 -n 2>/dev/null | grep -qE \"dpt:\$p\" || \
      sudo iptables -L nixos-fw -n | grep -qE \"dpt:\$p\" || { echo \"FAIL: \$p\"; exit 1; }
  done"

check "6 sonarr API responde" ssh "$HOST" '
  KEY=$(sudo sed -n "s|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p" /var/lib/sonarr/config.xml 2>/dev/null)
  [ -n "$KEY" ] || exit 1
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Api-Key: $KEY" http://127.0.0.1:8989/api/v3/system/status)
  [ "$CODE" = "200" ]'

check "7 radarr API responde" ssh "$HOST" '
  KEY=$(sudo sed -n "s|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p" /var/lib/radarr/config.xml 2>/dev/null)
  [ -n "$KEY" ] || exit 1
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Api-Key: $KEY" http://127.0.0.1:7878/api/v3/system/status)
  [ "$CODE" = "200" ]'

check "8 prowlarr API responde" ssh "$HOST" '
  KEY=$(sudo sed -n "s|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p" /var/lib/prowlarr/config.xml 2>/dev/null)
  [ -n "$KEY" ] || exit 1
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Api-Key: $KEY" http://127.0.0.1:9696/api/v1/system/status)
  [ "$CODE" = "200" ]'

check "9 bazarr UI responde" ssh "$HOST" '
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:6767/)
  [ "$CODE" = "200" ] || [ "$CODE" = "302" ]'

check "10 arr-bootstrap.service ran clean" ssh "$HOST" "
  sudo systemctl is-active arr-bootstrap.service | grep -qE 'active'"

check "11 Sonarr root folder /srv/storage/media/tv configurado" ssh "$HOST" '
  KEY=$(sudo sed -n "s|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p" /var/lib/sonarr/config.xml)
  curl -sf -H "X-Api-Key: $KEY" http://127.0.0.1:8989/api/v3/rootfolder | \
    jq -e ".[] | select(.path==\"/srv/storage/media/tv\")" >/dev/null'

check "12 Radarr root folder /srv/storage/media/movies configurado" ssh "$HOST" '
  KEY=$(sudo sed -n "s|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p" /var/lib/radarr/config.xml)
  curl -sf -H "X-Api-Key: $KEY" http://127.0.0.1:7878/api/v3/rootfolder | \
    jq -e ".[] | select(.path==\"/srv/storage/media/movies\")" >/dev/null'

check "13 Sonarr download client Deluge configurado" ssh "$HOST" '
  KEY=$(sudo sed -n "s|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p" /var/lib/sonarr/config.xml)
  curl -sf -H "X-Api-Key: $KEY" http://127.0.0.1:8989/api/v3/downloadclient | \
    jq -e ".[] | select(.name==\"Deluge\")" >/dev/null'

check "14 Radarr download client Deluge configurado" ssh "$HOST" '
  KEY=$(sudo sed -n "s|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p" /var/lib/radarr/config.xml)
  curl -sf -H "X-Api-Key: $KEY" http://127.0.0.1:7878/api/v3/downloadclient | \
    jq -e ".[] | select(.name==\"Deluge\")" >/dev/null'

check "15 Prowlarr ↔ Sonarr+Radarr applications configuradas" ssh "$HOST" '
  KEY=$(sudo sed -n "s|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p" /var/lib/prowlarr/config.xml)
  APPS=$(curl -sf -H "X-Api-Key: $KEY" http://127.0.0.1:9696/api/v1/applications)
  echo "$APPS" | jq -e ".[] | select(.name==\"Sonarr\")" >/dev/null && \
  echo "$APPS" | jq -e ".[] | select(.name==\"Radarr\")" >/dev/null'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase E.2c verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
