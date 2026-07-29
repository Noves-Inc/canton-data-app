# Keycloak configuration

Create separate Keycloak clients for browser login and background capture. The browser client
is public and uses the authorization-code flow with PKCE. The capture client is confidential
and uses service accounts.

In the examples below, `APP_URL` is the exact public Data App URL and `REALM` is the validator's
realm.

## 1. Browser client

1. Open **Clients > Create client** and select **OpenID Connect**.
2. Set a distinct client ID, such as `noves-canton-data-app-browser`.
3. Enable **Standard flow**.
4. Disable **Client authentication** so the client is public.
5. Set:
   - **Valid redirect URIs:** `APP_URL/callback`
   - **Valid post logout redirect URIs:** `APP_URL`
   - **Web origins:** `APP_URL`
6. Require PKCE with `S256` when that option is available.
7. Add the validator's `daml_ledger_api` client scope as a default scope.

<!-- screenshot-slot: keycloak-public-client -->

Use these Helm values:

```yaml
oidc:
  provider: keycloak
  appUrl: https://data.example.com
  keycloak:
    url: https://sso.example.com
    realm: canton
    clientId: noves-canton-data-app-browser
```

For Compose, use the equivalent `VITE_KEYCLOAK_*` values in `.env`.

## 2. Dedicated capture client

1. Create another OpenID Connect client, such as `noves-canton-data-app-capture`.
2. Enable **Client authentication** and **Service accounts roles**.
3. Disable browser-oriented flows for this client.
4. Add `daml_ledger_api` as a default client scope.
5. In the audience mapper used by the validator, include the Canton Ledger API audience.
6. Record the client ID and generated secret. The token endpoint is:

   ```text
   KEYCLOAK_URL/realms/REALM/protocol/openid-connect/token
   ```

<!-- screenshot-slot: keycloak-service-account -->

<!-- screenshot-slot: keycloak-ledger-scope -->

## 3. Observe the exact token subject

Request one token locally:

```bash
TOKEN_RESPONSE="$(
  curl -fsS -X POST \
    -d grant_type=client_credentials \
    -d client_id="$M2M_CLIENT_ID" \
    -d client_secret="$M2M_CLIENT_SECRET" \
    "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token"
)"
TOKEN="$(jq -r '.access_token' <<<"$TOKEN_RESPONSE")"
PAYLOAD="$(cut -d. -f2 <<<"$TOKEN" | tr '_-' '/+')"
printf '%s' "$PAYLOAD===" | base64 -d 2>/dev/null | jq '{sub,iss,aud}'
unset TOKEN TOKEN_RESPONSE PAYLOAD
```

Copy the exact, case-sensitive `sub`. Do not assume it is the client ID or service-account
display name.

<!-- screenshot-slot: keycloak-token-subject -->

## 4. Matching Canton user

Create a Canton user whose ID exactly equals the observed `sub`:

```scala
participant.ledger_api.users.create(
  id = "<exact-token-subject>",
  readAsAnyParty = true
)
```

Grant no other rights. In particular, leave participant administration, identity-provider
administration, act-as, and execute-as disabled.

In guided setup, the installer can detect the Keycloak URL, realm, Ledger API audience, and scope
from the validator configuration. After you create and enter the separate capture client, the
wizard asks for explicit confirmation and can create this Canton user automatically. It does not
create or modify a Keycloak client. If automatic participant provisioning is unavailable, use
the copyable `grpcurl -expand-headers` commands shown by the wizard.

<!-- screenshot-slot: keycloak-canton-rights -->

## 5. Verify

The setup wizard checks discovery, client-credentials exchange, exact subject equality, rights,
participant identity, network, and database readiness. A broader Canton user is rejected rather
than accepted with a warning.
