# Plugin SSO-Auth para Jellyfin (9p4/jellyfin-plugin-sso). Pre-compilado .NET,
# distribuído como zip con .dll + meta.json. No requiere build — solo unpack.
#
# Compatible con Jellyfin 10.10.x (ABI declarada en manifest del plugin).
#
# Para subir versión: cambiar `version`, refrescar `hash` con:
#   nix-prefetch-url --type sha256 \
#     https://github.com/9p4/jellyfin-plugin-sso/releases/download/vX.Y.Z.W/sso-authentication_X.Y.Z.W.zip
#   (luego nix hash to-sri --type sha256 <hex>)
{ lib, stdenvNoCC, fetchurl, unzip }:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "jellyfin-plugin-sso";
  version = "4.0.0.3";

  src = fetchurl {
    url = "https://github.com/9p4/jellyfin-plugin-sso/releases/download/v${finalAttrs.version}/sso-authentication_${finalAttrs.version}.zip";
    hash = "sha256-3glRJVvsTtZGA3ZB5+CqEhCzoAoUFAZUgIe+2ZTLm90=";
  };

  nativeBuildInputs = [ unzip ];

  dontConfigure = true;
  dontBuild = true;

  unpackPhase = ''
    runHook preUnpack
    unzip $src -d unpacked
    runHook postUnpack
  '';

  # Jellyfin espera plugins en `<dataDir>/plugins/<Name>_<Version>/<file>.dll`.
  # Exportamos el contenido a $out/plugin/ y lo copia un oneshot al runtime dir.
  installPhase = ''
    runHook preInstall
    install -d $out/plugin
    cp -R unpacked/. $out/plugin/
    runHook postInstall
  '';

  meta = {
    description = "SSO-Auth plugin for Jellyfin (OIDC + SAML)";
    homepage = "https://github.com/9p4/jellyfin-plugin-sso";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
  };
})
