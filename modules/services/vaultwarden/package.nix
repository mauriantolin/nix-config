# Fork Timshel/vaultwarden con SSO nativo. Empaquetado como función para que
# callPackage lo envuelva con makeOverridable y exponga `.override` —
# requisito del módulo NixOS upstream:
#
#   vaultwarden = cfg.package.override { inherit (cfg) dbBackend; };
#
# Ver `sso-overlay.nix` para el contexto de por qué reemplazamos el upstream.
{ lib
, fetchFromGitHub
, rustPackages_1_94
, pkg-config
, openssl
, callPackage
, dbBackend ? "sqlite"
}:

rustPackages_1_94.rustPlatform.buildRustPackage rec {
  pname = "vaultwarden";
  version = "1.35.8";

  src = fetchFromGitHub {
    owner = "Timshel";
    repo = "vaultwarden";
    tag = version;
    hash = "sha256-bEPwH0+b4cQTh1hNiiX2qvTNeRxxShm2JXNKNfn4xm8=";
  };

  cargoHash = "sha256-gcE3qfSVCk08haADyqOff4R0ekd9Q6RB59LUtow9Yi4=";

  env.VW_VERSION = version;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  buildFeatures = [ dbBackend ];

  passthru = {
    webvault = callPackage ./webvault-oidc-button.nix { };
  };

  meta = {
    description = "Vaultwarden con SSO nativo (fork Timshel)";
    homepage = "https://github.com/Timshel/vaultwarden";
    license = lib.licenses.agpl3Only;
    mainProgram = "vaultwarden";
    platforms = lib.platforms.linux;
  };
}
