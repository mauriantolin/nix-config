{
  description = "Mauricio's NixOS home-lab (ported from notthebee/nix-config, Phase A minimal)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    agenix.inputs.home-manager.follows = "home-manager";

    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    nixos-anywhere.inputs.nixpkgs.follows = "nixpkgs";
    nixos-anywhere.inputs.disko.follows = "disko";

    # Secretos cifrados en repo privado separado.
    # NOTE: hosts que evalúan este flake deben tener un key autorizado para git@github.com.
    # En la PC Windows del user el alias 'github-mauri' funciona, pero el URL aquí
    # apunta a github.com directo porque evalúa también en home-server / VM Hetzner.
    secrets = {
      url = "git+ssh://git@github.com/mauriantolin/nix-private.git";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, home-manager, disko, agenix, nixos-anywhere, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      flake = {
        nixosConfigurations = {
          home-server = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit inputs; };
            modules = [
              disko.nixosModules.disko
              agenix.nixosModules.default
              home-manager.nixosModules.home-manager
              ./modules/machines/nixos/home-server
            ];
          };

          # Variante efímera para V1 dry-run en VM Hetzner (disko diferente).
          home-server-vm = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit inputs; };
            modules = [
              disko.nixosModules.disko
              agenix.nixosModules.default
              home-manager.nixosModules.home-manager
              ./modules/machines/nixos/home-server
              ./modules/machines/nixos/home-server/vm-overlay.nix
            ];
          };

          # Test machine TEMPORAL para validar módulos E.1 pre-merge sin tocar el host real.
          # Solo se usa con `nix flake check` o `nix build .#nixosConfigurations.home-server-e1-test.config.system.build.toplevel`.
          # Eliminar antes del merge final E.1b (cuando los módulos ya estén integrados al host real).
          home-server-e1-test = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit inputs; };
            modules = [
              agenix.nixosModules.default
              ./modules/services/postgres-shared
              ./modules/services/paperless
              ./modules/services/radicale
              ({ config, pkgs, ... }: {
                # Mínimo viable para que el módulo nixos eval no explote.
                boot.loader.grub.device = "nodev";
                fileSystems."/" = { device = "tmpfs"; fsType = "tmpfs"; };
                system.stateVersion = "25.11";

                # Stub user `mauri` (paperless lo agrega a su grupo).
                users.users.mauri = {
                  isNormalUser = true;
                  uid = 1000;
                };

                # Enable los 3 módulos E.1 con valores dummy.
                # (Los .age files NO existen en este test config; el eval no los lee, solo el path.)
                services.postgres-shared-homelab = {
                  enable = true;
                  databases = {
                    paperless = { user = "paperless"; secretFile = "/run/agenix/postgres-paperless-pass"; };
                    grafana   = { user = "grafana";   secretFile = "/run/agenix/postgres-grafana-pass"; };
                    nextcloud = { user = "nextcloud"; secretFile = "/run/agenix/postgres-nextcloud-pass"; };
                    immich    = { user = "immich";    secretFile = "/run/agenix/postgres-immich-pass"; };
                    hass      = { user = "hass";      secretFile = "/run/agenix/postgres-hass-pass"; };
                  };
                };

                services.paperless-homelab.enable = true;
                services.radicale-homelab.enable = true;

                # Stub agenix secrets (paths ficticios — solo eval, no decryption real).
                age.secrets.postgresPaperlessPass.file = pkgs.writeText "stub" "stub";
                age.secrets.paperlessSecretKey.file    = pkgs.writeText "stub" "stub";
                age.secrets.paperlessAdminPass.file    = pkgs.writeText "stub" "stub";
                age.secrets.radicaleHtpasswd.file      = pkgs.writeText "stub" "stub";
              })
            ];
          };
        };
      };

      perSystem = { pkgs, system, ... }: {
        devShells.default = pkgs.mkShell {
          packages = [
            agenix.packages.${system}.default
            disko.packages.${system}.disko
            nixos-anywhere.packages.${system}.nixos-anywhere
            pkgs.just
            pkgs.git
            pkgs.openssh
          ];
        };

        formatter = pkgs.nixpkgs-fmt;
      };
    };
}
