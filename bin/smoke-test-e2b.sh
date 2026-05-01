#!/usr/bin/env bash
# Smoke test Fase E.2b — Deluge (Path A no-VPN)
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

echo "=== Smoke test Fase E.2b ==="

check "1 datasets E.2b mounted (deluge state + downloads)" ssh "$HOST" "
  mountpoint -q /var/lib/deluge && \
  mountpoint -q /srv/downloads"

check "2 downloads dirs ownership=deluge:media + setgid (2775)" ssh "$HOST" '
  for d in /srv/downloads /srv/downloads/incomplete /srv/downloads/complete; do
    perms=$(stat -c "%a %U %G" "$d")
    [ "$perms" = "2775 deluge media" ] || { echo "FAIL: $d → $perms"; exit 1; }
  done'

check "3 deluged + deluge-web active" ssh "$HOST" '
  sudo systemctl is-active deluged | grep -q active && \
  sudo systemctl is-active deluge-web | grep -q active'

check "4 deluge web :8112 returns login form" ssh "$HOST" '
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:8112/)
  [ "$CODE" = "200" ]'

check "5 deluge daemon RPC :58846 loopback only" ssh "$HOST" "
  sudo ss -tnlp | grep -q '127.0.0.1:58846' && \
  ! sudo ss -tnlp | grep -E ':58846' | grep -qv '127.0.0.1'"

check "6 deluge web :8112 listening (loopback OR 0.0.0.0 + firewall)" ssh "$HOST" "
  sudo ss -tnlp | grep -qE ':8112'"

check "7 BT listen ports 6881-6889 abiertos en firewall" ssh "$HOST" '
  sudo iptables -L nixos-fw -n | grep -qE "tcp .* dpts:6881:6889" && \
  sudo iptables -L nixos-fw -n | grep -qE "udp .* dpts:6881:6889"'

check "8 deluge encryption=forced en core.conf (enc_in/out_policy=2)" ssh "$HOST" '
  sudo cat /var/lib/deluge/.config/deluge/core.conf | grep -q "\"enc_in_policy\": 2" && \
  sudo cat /var/lib/deluge/.config/deluge/core.conf | grep -q "\"enc_out_policy\": 2"'

check "9 deluge UPnP/NATPMP off" ssh "$HOST" '
  sudo cat /var/lib/deluge/.config/deluge/core.conf | grep -q "\"upnp\": false" && \
  sudo cat /var/lib/deluge/.config/deluge/core.conf | grep -q "\"natpmp\": false"'

check "10 deluge max_connections_global=100 (Path A cap)" ssh "$HOST" '
  sudo cat /var/lib/deluge/.config/deluge/core.conf | grep -q "\"max_connections_global\": 100"'

check "11 deluge web auth file rendered" ssh "$HOST" "
  sudo test -r /run/deluge/auth && \
  sudo grep -q '^mauri:.*:10\$' /run/deluge/auth"

check "12 deluge via Tailscale Serve :8212 responde" ssh "$HOST" '
  CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 https://home-server.tailee5654.ts.net:8212/)
  [ "$CODE" = "200" ]'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase E.2b verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
