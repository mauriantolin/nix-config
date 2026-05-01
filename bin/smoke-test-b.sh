#!/usr/bin/env bash
# Smoke test Fase B — Cloudflare Tunnel + whoami público.
# Corre desde cualquier host con acceso a internet + SSH al home-server.
set -euo pipefail

HOST="${HOST:-mauri@home-server}"
DOMAIN="${DOMAIN:-whoami.mauricioantolin.com}"
FAIL=0

check() {
  local name="$1"; shift
  printf '%-50s ' "$name"
  if "$@" >/dev/null 2>&1; then
    echo OK
  else
    echo FAIL
    FAIL=1
  fi
}

echo "=== Smoke test Fase B: $DOMAIN via $HOST ==="

check "1. cloudflared.service active"              ssh "$HOST" "systemctl is-active cloudflared.service | grep -q active"
check "2. whoami (nginx) on 127.0.0.1:8080"        ssh "$HOST" "curl -sf http://127.0.0.1:8080/ | grep -q 'home-server online'"
check "3. DNS resolves $DOMAIN"                    bash -c "getent hosts $DOMAIN || dig +short $DOMAIN | grep -Eq '^[0-9a-f.:]+$'"
check "4. TLS handshake to $DOMAIN"                bash -c "curl -sfI https://$DOMAIN --max-time 10 >/dev/null"
check "5. whoami responde via tunnel"              bash -c "curl -sf https://$DOMAIN --max-time 10 | grep -q 'home-server online'"
check "6. CF-Ray header presente"                  bash -c "curl -sI https://$DOMAIN --max-time 10 | grep -iq '^cf-ray:'"
check "7. no expone TCP 80/443 a internet"         bash -c "nc -zw2 \$(curl -s ifconfig.me) 80 2>&1 | grep -q 'succeeded' && exit 1 || exit 0"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase B verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
