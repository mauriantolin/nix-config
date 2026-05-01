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

check "1 jellyseerr state dir existe (DynamicUser, sin dataset)" ssh "$HOST" "
  test -L /var/lib/jellyseerr -o -d /var/lib/jellyseerr"

check "2 jellyseerr active" ssh "$HOST" '
  sudo systemctl is-active jellyseerr | grep -q "^active$"'

check "3 jellyseerr listening on :5055 (tailscale0 only via firewall)" ssh "$HOST" "
  sudo ss -tnlp | grep -qE ':5055' && \
  sudo iptables -S nixos-fw 2>/dev/null | grep -qE 'tailscale0.*dport 5055'"

check "4 jellyseerr /api/v1/status returns 200" ssh "$HOST" '
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:5055/api/v1/status)
  [ "$CODE" = "200" ]'

check "5 jellyseerr-bootstrap.service ran clean" ssh "$HOST" "
  sudo systemctl is-active jellyseerr-bootstrap.service | grep -qE 'active'"

check "6 jellyseerr initialized=true (wizard hecho)" ssh "$HOST" '
  curl -sf http://127.0.0.1:5055/api/v1/settings/public | jq -r .initialized | grep -q true'

check "7 cloudflared sumó requests.* a ingress config" ssh "$HOST" "
  # cloudflared NixOS module crea unit cloudflared-tunnel-<UUID>; config en /nix/store.
  sudo systemctl cat 'cloudflared-tunnel-*.service' 2>/dev/null | \
    grep -oE 'cloudflared\.yml=[^[:space:]]+' | head -1 | cut -d= -f2 | \
    xargs -r sudo cat | grep -q 'requests.mauricioantolin.com' || \
  sudo systemctl show 'cloudflared-tunnel-*.service' -p ExecStart 2>/dev/null | \
    grep -oE -- '--config=[^ ]+\.yml' | head -1 | cut -d= -f2 | \
    xargs -r sudo cat | grep -q 'requests.mauricioantolin.com'"

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
