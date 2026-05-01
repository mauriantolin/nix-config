# Overlay que reemplaza pkgs.vaultwarden por el fork Timshel/vaultwarden con SSO
# nativo + bundle "oidc_button_web_vault" como webvault (login form clásico +
# botón "Use Single-Sign On").
#
# Referencia: nixpkgs 25.11 empaqueta dani-garcia/vaultwarden 1.35.7 sin SSO.
# Ver memory `ref_homelab_sso_blockers.md`.
#
# Cuando subas el tag (1.35.8 → 1.35.x), si Cargo.lock cambió hay que actualizar
# `cargoHash`. nix-build falla mostrando el hash real — copialo del error.
final: prev: {
  vaultwarden = prev.vaultwarden.overrideAttrs (old: rec {
    pname = "vaultwarden";
    version = "1.35.8";

    src = prev.fetchFromGitHub {
      owner = "Timshel";
      repo = "vaultwarden";
      tag = version;
      hash = "sha256-bEPwH0+b4cQTh1hNiiX2qvTNeRxxShm2JXNKNfn4xm8=";
    };

    # cargoDeps se re-deriva del nuevo Cargo.lock. Reemplazar por el hash real
    # tras el primer build (el error de nix-build dice "got: sha256-...").
    cargoHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

    env = (old.env or { }) // { VW_VERSION = version; };

    passthru = (old.passthru or { }) // {
      webvault = final.callPackage ./webvault-oidc-button.nix { };
    };
  });
}
