#!/usr/bin/env bash
# Crea los client-scopes estándar (email, profile, roles, web-origins, acr) en
# el realm homelab y los asigna como default a todos los clients OIDC (5 D.4a +
# 8 D.4b). Idempotente: skip si ya existen / ya están asignados.
#
# Bug origen: realm-export.json declaraba defaultDefaultClientScopes pero NO los
# scopes mismos en clientScopes[]. KC los toma sólo en realm-creation desde UI;
# en partial-import se ignoran. Resultado: clients OIDC sin scopes default →
# error invalid_scope al login.
set -uo pipefail

HOST="${HOST:-mauri@home-server}"

ssh "$HOST" 'set -uo pipefail
pass=$(sudo cat /run/agenix/keycloak-admin-pass)
TOKEN=$(curl -sf -X POST "http://127.0.0.1:8180/realms/master/protocol/openid-connect/token" \
  -d "username=admin" --data-urlencode "password=$pass" \
  -d "grant_type=password&client_id=admin-cli" | jq -r .access_token)
KC=http://127.0.0.1:8180/admin/realms/homelab
H=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")

# Helper: crea un client-scope si no existe; devuelve su ID via stdout
create_scope() {
  local name="$1" body="$2"
  local existing
  existing=$(curl -sf "${H[@]}" "$KC/client-scopes" | jq -r ".[] | select(.name==\"$name\") | .id")
  if [ -n "$existing" ]; then
    echo "[scope] $name ya existe ($existing)" >&2
    echo "$existing"
    return
  fi
  curl -sf -X POST "${H[@]}" "$KC/client-scopes" --data-binary "$body" >/dev/null
  curl -sf "${H[@]}" "$KC/client-scopes" | jq -r ".[] | select(.name==\"$name\") | .id"
}

# === scope: email ===
EMAIL_BODY=$(jq -n "{
  name: \"email\",
  description: \"OpenID Connect built-in scope: email\",
  protocol: \"openid-connect\",
  attributes: {
    \"include.in.token.scope\": \"true\",
    \"display.on.consent.screen\": \"true\",
    \"consent.screen.text\": \"\${emailScopeConsentText}\"
  },
  protocolMappers: [
    {
      name: \"email\",
      protocol: \"openid-connect\",
      protocolMapper: \"oidc-usermodel-attribute-mapper\",
      config: {
        \"userinfo.token.claim\": \"true\",
        \"user.attribute\": \"email\",
        \"id.token.claim\": \"true\",
        \"access.token.claim\": \"true\",
        \"claim.name\": \"email\",
        \"jsonType.label\": \"String\"
      }
    },
    {
      name: \"email verified\",
      protocol: \"openid-connect\",
      protocolMapper: \"oidc-usermodel-property-mapper\",
      config: {
        \"userinfo.token.claim\": \"true\",
        \"user.attribute\": \"emailVerified\",
        \"id.token.claim\": \"true\",
        \"access.token.claim\": \"true\",
        \"claim.name\": \"email_verified\",
        \"jsonType.label\": \"boolean\"
      }
    }
  ]
}")
EMAIL_ID=$(create_scope email "$EMAIL_BODY")

# === scope: profile ===
PROFILE_BODY=$(jq -n "{
  name: \"profile\",
  description: \"OpenID Connect built-in scope: profile\",
  protocol: \"openid-connect\",
  attributes: {
    \"include.in.token.scope\": \"true\",
    \"display.on.consent.screen\": \"true\",
    \"consent.screen.text\": \"\${profileScopeConsentText}\"
  },
  protocolMappers: [
    { name: \"username\",          protocol:\"openid-connect\", protocolMapper:\"oidc-usermodel-attribute-mapper\",
      config: {\"userinfo.token.claim\":\"true\",\"user.attribute\":\"username\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"claim.name\":\"preferred_username\",\"jsonType.label\":\"String\"} },
    { name: \"family name\",        protocol:\"openid-connect\", protocolMapper:\"oidc-usermodel-attribute-mapper\",
      config: {\"userinfo.token.claim\":\"true\",\"user.attribute\":\"lastName\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"claim.name\":\"family_name\",\"jsonType.label\":\"String\"} },
    { name: \"given name\",         protocol:\"openid-connect\", protocolMapper:\"oidc-usermodel-attribute-mapper\",
      config: {\"userinfo.token.claim\":\"true\",\"user.attribute\":\"firstName\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"claim.name\":\"given_name\",\"jsonType.label\":\"String\"} },
    { name: \"full name\",          protocol:\"openid-connect\", protocolMapper:\"oidc-full-name-mapper\",
      config: {\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"userinfo.token.claim\":\"true\"} }
  ]
}")
PROFILE_ID=$(create_scope profile "$PROFILE_BODY")

# === scope: roles ===
ROLES_BODY=$(jq -n "{
  name: \"roles\",
  description: \"OpenID Connect scope for add user roles to the access token\",
  protocol: \"openid-connect\",
  attributes: {
    \"include.in.token.scope\": \"false\",
    \"display.on.consent.screen\": \"true\",
    \"consent.screen.text\": \"\${rolesScopeConsentText}\"
  },
  protocolMappers: [
    { name: \"audience resolve\",   protocol:\"openid-connect\", protocolMapper:\"oidc-audience-resolve-mapper\", config: {} },
    { name: \"realm roles\",        protocol:\"openid-connect\", protocolMapper:\"oidc-usermodel-realm-role-mapper\",
      config: {\"multivalued\":\"true\",\"userinfo.token.claim\":\"false\",\"user.attribute\":\"foo\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"claim.name\":\"realm_access.roles\",\"jsonType.label\":\"String\"} },
    { name: \"client roles\",       protocol:\"openid-connect\", protocolMapper:\"oidc-usermodel-client-role-mapper\",
      config: {\"multivalued\":\"true\",\"userinfo.token.claim\":\"false\",\"user.attribute\":\"foo\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"claim.name\":\"resource_access.\${client_id}.roles\",\"jsonType.label\":\"String\"} }
  ]
}")
ROLES_ID=$(create_scope roles "$ROLES_BODY")

# === scope: web-origins ===
WEB_BODY=$(jq -n "{
  name: \"web-origins\",
  description: \"OpenID Connect scope for add allowed web origins to the access token\",
  protocol: \"openid-connect\",
  attributes: {
    \"include.in.token.scope\": \"false\",
    \"display.on.consent.screen\": \"false\",
    \"consent.screen.text\": \"\"
  },
  protocolMappers: [
    { name: \"allowed web origins\", protocol:\"openid-connect\", protocolMapper:\"oidc-allowed-origins-mapper\", config: {} }
  ]
}")
WEB_ID=$(create_scope web-origins "$WEB_BODY")

# === scope: acr ===
ACR_BODY=$(jq -n "{
  name: \"acr\",
  description: \"OpenID Connect scope for add acr (authentication context class reference) to the token\",
  protocol: \"openid-connect\",
  attributes: {
    \"include.in.token.scope\": \"false\",
    \"display.on.consent.screen\": \"false\"
  },
  protocolMappers: [
    { name: \"acr loa level\", protocol:\"openid-connect\", protocolMapper:\"oidc-acr-mapper\",
      config: {\"id.token.claim\":\"true\",\"access.token.claim\":\"true\"} }
  ]
}")
ACR_ID=$(create_scope acr "$ACR_BODY")

echo "Scope IDs: email=$EMAIL_ID profile=$PROFILE_ID roles=$ROLES_ID web-origins=$WEB_ID acr=$ACR_ID"

# === Asignar como default a todos los clients OIDC ===
CLIENTS="vaultwarden paperless grafana jellyfin jellyseerr oauth2proxy-sonarr oauth2proxy-radarr oauth2proxy-prowlarr oauth2proxy-bazarr oauth2proxy-deluge oauth2proxy-homepage oauth2proxy-kuma oauth2proxy-prometheus"
for client in $CLIENTS; do
  CID=$(curl -sf "${H[@]}" "$KC/clients?clientId=$client" | jq -r ".[0].id // empty")
  if [ -z "$CID" ]; then echo "$client → NO ENCONTRADO"; continue; fi
  for sid in $EMAIL_ID $PROFILE_ID $ROLES_ID $WEB_ID $ACR_ID; do
    [ -z "$sid" ] && continue
    curl -sf -X PUT "${H[@]}" "$KC/clients/$CID/default-client-scopes/$sid" >/dev/null || true
  done
  ASSIGNED=$(curl -sf "${H[@]}" "$KC/clients/$CID/default-client-scopes" | jq -r "[.[].name] | join(\",\")")
  echo "$client → $ASSIGNED"
done
'
