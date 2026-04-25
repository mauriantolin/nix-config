#!/usr/bin/env bash
# Smoke test Fase D.1 — edge hardening (geo-block + CF Access + fail2ban-samba)
set -euo pipefail

HOST="${HOST:-mauri@home-server}"
FAIL=0

check() {
  local name="$1"; shift
  printf '%-65s ' "$name"
  if "$@" >/dev/null 2>&1; then
    echo OK
  else
    echo FAIL
    FAIL=1
  fi
}

echo "=== Smoke test Fase D.1 ==="

# === Phase 1: refactor + samba jail (host-side) ===

check "1 fail2ban-jails module wired (both action.d files emitted)" ssh "$HOST" "
  sudo test -f /etc/fail2ban/action.d/cf-edge.conf && \
  sudo test -f /etc/fail2ban/action.d/nft-local.conf"

check "2 nftables table inet fail2ban-homelab present"         ssh "$HOST" '
  NFT=$(readlink -f $(find /nix/store -maxdepth 3 -name nft -type f -executable 2>/dev/null | head -1))
  sudo "$NFT" list table inet fail2ban-homelab 2>/dev/null | grep -q "set banlist"'

check "3 VW jail still active (regression)"                    ssh "$HOST" "
  sudo fail2ban-client status vaultwarden 2>/dev/null | grep -q 'Currently failed'"

check "4 Samba jail active"                                    ssh "$HOST" "
  sudo fail2ban-client status samba 2>/dev/null | grep -q 'Currently failed'"

check "5 Samba auth_audit Auth lines in journal"               ssh "$HOST" '
  PASS=$(sudo cat /run/agenix/smbMauriPassword)
  smbclient -L //127.0.0.1 -U "mauri%$PASS" >/dev/null 2>&1 || true
  sleep 1
  sudo journalctl -u samba-smbd -n 50 | grep -q "Auth:"'

check "6 VW jail regression — failregex matches"               ssh "$HOST" '
  sudo cat /etc/fail2ban/filter.d/vaultwarden.conf | grep -q "Username or password is incorrect"'

check "7 Samba ignoreip includes Tailnet"                       ssh "$HOST" "
  sudo cat /etc/fail2ban/jail.d/samba.local 2>/dev/null | grep -q '100.64.0.0/10' || \
  sudo fail2ban-client get samba ignoreip 2>/dev/null | grep -q '100.64.0.0/10'"

check "8 nft chain has priority -10"                            ssh "$HOST" '
  NFT=$(readlink -f $(find /nix/store -maxdepth 3 -name nft -type f -executable 2>/dev/null | head -1))
  sudo "$NFT" list chain inet fail2ban-homelab input | grep -qE "priority -10|priority filter - 10"'

# === Phase 4: CF Access + geo-block (CF dashboard) ===
# These checks fail until CF dashboard is configured (Tasks 11-12).

check "9 CF Access redirects vault.* to Access login"          bash -c '
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -L --max-redirs 0 \
    https://vault.mauricioantolin.com/ 2>/dev/null)
  [ "$CODE" = "302" ]'

check "10 CF Access bypass funciona para whoami.*"             bash -c '
  RESP=$(curl -s --max-time 10 https://whoami.mauricioantolin.com/ 2>/dev/null)
  echo "$RESP" | grep -q "Hostname:"'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase D.1 verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
