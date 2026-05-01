# Overlay que reemplaza pkgs.vaultwarden por el fork Timshel/vaultwarden con SSO
# nativo + bundle "oidc_button_web_vault" como webvault (login form clásico +
# botón "Use Single-Sign On").
#
# Referencia: nixpkgs 25.11 empaqueta dani-garcia/vaultwarden 1.35.7 sin SSO.
# Ver memory `ref_homelab_sso_blockers.md`.
#
# Usamos `callPackage` (no inline) porque el módulo NixOS upstream invoca
# `cfg.package.override { inherit (cfg) dbBackend; }` — sin makeOverridable
# (lo hace callPackage automáticamente) eso falla con "attribute 'override'
# missing".
final: prev: {
  vaultwarden = final.callPackage ./package.nix { };
}
