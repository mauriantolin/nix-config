# Overlay que reemplaza pkgs.vaultwarden por el fork Timshel/vaultwarden con SSO
# nativo + bundle "oidc_button_web_vault" como webvault (login form clásico +
# botón "Use Single-Sign On").
#
# Referencia: nixpkgs 25.11 empaqueta dani-garcia/vaultwarden 1.35.7 sin SSO.
# Ver memory `ref_homelab_sso_blockers.md`.
#
# Construido como derivación nueva (no overrideAttrs) porque el fork tiene un
# Cargo.lock distinto y override no resetea cargoDeps del upstream — el builder
# reutilizaba el vendor 1.35.7 y fallaba con "Cargo.lock is not the same".
#
# Cuando subas el tag (1.35.8 → 1.35.x), reemplazá `cargoHash` por el real
# después del primer build (set "" → fallar → copiar got: sha256-...).
final: prev: {
  vaultwarden = prev.rustPackages_1_94.rustPlatform.buildRustPackage rec {
    pname = "vaultwarden";
    version = "1.35.8";

    src = prev.fetchFromGitHub {
      owner = "Timshel";
      repo = "vaultwarden";
      tag = version;
      hash = "sha256-bEPwH0+b4cQTh1hNiiX2qvTNeRxxShm2JXNKNfn4xm8=";
    };

    cargoHash = "";

    env.VW_VERSION = version;

    nativeBuildInputs = [ prev.pkg-config ];
    buildInputs = [ prev.openssl ];

    buildFeatures = [ "sqlite" ];

    passthru = {
      webvault = final.callPackage ./webvault-oidc-button.nix { };
    };

    meta = {
      description = "Vaultwarden con SSO nativo (fork Timshel)";
      homepage = "https://github.com/Timshel/vaultwarden";
      license = prev.lib.licenses.agpl3Only;
      mainProgram = "vaultwarden";
      platforms = prev.lib.platforms.linux;
    };
  };
}
