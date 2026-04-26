#!/usr/bin/env bash
# bootstrap-e2-secrets.sh — Genera y encripta los 2 secretos de Fase E.2.
#
# Uso (en home-server):
#   ssh home-server
#   cd ~/nix-config && bash bin/bootstrap-e2-secrets.sh
#
# IDEMPOTENTE: si el .age ya existe, lo skip (no sobrescribe).
# Imprime los passwords UNA VEZ — guardalos en Vaultwarden.
#
set -euo pipefail
cd ~/nix-private

RECIPIENTS=$(mktemp)
trap 'rm -f "$RECIPIENTS"' EXIT
cat > "$RECIPIENTS" <<RCP
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM0/mKSFJ9hlyypK0uf3n55WDh/TCVWP8Rbbv9HAQl/q mauriantolin5@gmail.com
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINUKK/LQTrCtgAfZcE054PqcgwKO+w8uMTZXpRkQEYrO root@home-server-nixos
RCP

openssl_cmd() {
  nix shell nixpkgs#openssl --command openssl "$@"
}

encrypt() {
  local target="$1"
  local value="$2"
  if [ -z "$value" ] || [ ${#value} -lt 16 ]; then
    echo "ERROR: value vacío/corto para $target" >&2
    return 1
  fi
  printf '%s' "$value" | nix run nixpkgs#rage -- -a -R "$RECIPIENTS" -o "$target"
  echo "[OK] $target ($(stat -c%s "$target") bytes)"
}

# ─── jellyfin-admin-pass ────────────────────────────────────────────────────
if [ -f secrets/jellyfin-admin-pass.age ]; then
  echo "[skip] secrets/jellyfin-admin-pass.age ya existe"
  JELLYFIN_PASS="<existente; usar el de VW>"
else
  JELLYFIN_PASS=$(openssl_cmd rand -base64 24)
  encrypt secrets/jellyfin-admin-pass.age "$JELLYFIN_PASS"
fi

# ─── deluge-web-pass ────────────────────────────────────────────────────────
if [ -f secrets/deluge-web-pass.age ]; then
  echo "[skip] secrets/deluge-web-pass.age ya existe"
  DELUGE_PASS="<existente; usar el de VW>"
else
  DELUGE_PASS=$(openssl_cmd rand -base64 24)
  encrypt secrets/deluge-web-pass.age "$DELUGE_PASS"
fi

echo
echo "================================================================"
echo "GUARDALOS EN VAULTWARDEN AHORA (no se vuelve a mostrar):"
echo "  Jellyfin   user=mauri   pass=$JELLYFIN_PASS"
echo "  Deluge     user=mauri   pass=$DELUGE_PASS"
echo "================================================================"
echo
echo "Próximo: commit + push (necesita SSH config sudo + host key):"
echo "  cd ~/nix-private"
echo "  git add secrets/{jellyfin-admin-pass,deluge-web-pass}.age"
echo "  git -c user.email=mauri@home-server -c user.name=mauri commit -m 'feat(secrets): E.2 bootstrap'"
echo "  git push origin main"
echo
echo "Después en ~/nix-config:"
echo "  sudo nix flake update secrets"
echo "  sudo nixos-rebuild switch --flake .#home-server"
echo "  just smoke-e2"
