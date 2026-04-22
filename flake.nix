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
