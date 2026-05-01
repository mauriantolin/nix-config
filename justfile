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

# Rollback a la generación anterior (en caliente)
rollback:
	sudo nixos-rebuild switch --rollback

# Smoke test post-install (corre desde Atos PC)
smoke:
	bash bin/smoke-test.sh

# Lista generaciones de NixOS
generations:
	sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
