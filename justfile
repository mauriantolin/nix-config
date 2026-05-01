default:
	@just --list

# Verifica formato + evaluación sin construir nada
check:
	nix flake check --no-build

# Formatea todos los .nix
fmt:
	nix fmt

# Build local sin activar (dry-build)
dry:
	nixos-rebuild dry-build --flake .#home-server

# Rebuild + switch (solo funciona EN home-server)
deploy:
	#!/usr/bin/env bash
	set -euo pipefail
	if ! git diff-index --quiet HEAD --; then
	  echo "ERROR: working tree sucio; commiteá o stasheá antes de deploy." >&2
	  exit 1
	fi
	sudo nixos-rebuild switch --flake .#home-server

# `nixos-rebuild switch --rollback` asume NIX_PATH legacy (roto en sistemas flake-only),
# por eso hacemos el swap de profile + switch-to-configuration a mano.
# Rollback a la generación anterior (en caliente).
rollback:
	sudo nix-env --profile /nix/var/nix/profiles/system --rollback
	sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch

# Smoke test Fase A (corre desde Atos PC)
smoke:
	bash bin/smoke-test.sh

# Smoke test Fase B — ingress público via Cloudflare Tunnel
smoke-b:
	bash bin/smoke-test-b.sh

# Lista generaciones de NixOS
generations:
	sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

# Smoke test Fase C.1 — web services + fail2ban-cloudflare
smoke-c1:
	bash bin/smoke-test-c1.sh

# Smoke test Fase C.2 — Samba
smoke-c2:
	bash bin/smoke-test-c2.sh

# Shortcut diagnóstico fail2ban
fail2ban-status:
	ssh mauri@home-server 'sudo fail2ban-client status'
