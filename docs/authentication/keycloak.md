# Keycloak configuration

The Noves Data App needs two Keycloak clients:

| Client | Type | Use |
|---|---|---|
| `noves-canton-data-app-browser` | Public, authorization code with PKCE | Human sign-in |
| `noves-canton-data-app-capture` | Confidential, service account | Background participant capture |

Do not reuse the validator client. In the examples, replace:

- `APP_URL` with the exact public frontend URL;
- `KEYCLOAK_URL` with the Keycloak base URL, without `/realms/...`;
- `REALM` with the validator realm; and
- `AUDIENCE` with the validator Ledger API audience, normally `https://canton.network.global`.

You can verify the issuer and token endpoint before opening the admin console:

```bash
curl -fsS \
  "$KEYCLOAK_URL/realms/$REALM/.well-known/openid-configuration" |
  jq '{issuer, token_endpoint}'
```

## 1. Create the browser client

In the Keycloak admin console:

1. Select the validator realm.
2. Open **Clients**, select **Create client**, and choose **OpenID Connect**.
3. Set **Client ID** to `noves-canton-data-app-browser`.
4. In **Capability config**:
   - disable **Client authentication**;
   - enable **Standard flow**;
   - disable **Direct access grants**; and
   - leave service accounts disabled.
5. In **Login settings**, set:
   - **Valid redirect URIs:** `APP_URL/callback`
   - **Valid post logout redirect URIs:** `APP_URL`
   - **Web origins:** `APP_URL`
6. Save the client.
7. On **Settings > Capability config**, set **PKCE Method** to `S256`.
8. Assign `daml_ledger_api` as a default client scope. Follow [Assign the Ledger API scope](#assign-the-ledger-api-scope).

The browser client has no secret. Put only these public values in Compose `.env`:

```dotenv
APP_URL=https://data.example.com
VITE_AUTH0_DOMAIN=
VITE_AUTH0_CLIENT_ID=
VITE_AUTH0_AUDIENCE=
VITE_KEYCLOAK_URL=https://keycloak.example.com
VITE_KEYCLOAK_REALM=canton
VITE_KEYCLOAK_CLIENT_ID=noves-canton-data-app-browser
```

Equivalent Helm values are:

```yaml
oidc:
  provider: keycloak
  appUrl: https://data.example.com
  keycloak:
    url: https://keycloak.example.com
    realm: canton
    clientId: noves-canton-data-app-browser
```

## 2. Create the capture client

1. Create another OpenID Connect client with client ID `noves-canton-data-app-capture`.
2. In **Capability config**:
   - enable **Client authentication**;
   - disable **Standard flow**;
   - disable **Direct access grants**; and
   - enable **Service accounts roles**.
3. Leave **Root URL** and **Home URL** blank in **Login settings**, then save the client.
4. Assign `daml_ledger_api` as a default client scope. Follow [Assign the Ledger API scope](#assign-the-ledger-api-scope).
5. Open **Credentials** and record the generated client secret.

### Assign the Ledger API scope

On the client's **Client scopes** tab:

1. Select **Add client scope**.
2. Select the checkbox next to `daml_ledger_api`.
3. Open the **Add** menu and choose **Default**.
4. Confirm that the `daml_ledger_api` row shows **Default**.

The access token must contain the Ledger API audience. Request a token in the next section and inspect `aud` first. If `AUDIENCE` is absent, add an audience mapper to this client's dedicated scope:

1. Open the capture client and select **Client scopes**.
2. Open the row whose name ends in `-dedicated`.
3. Select **Configure a new mapper**, then choose **Audience**.
4. Set:
   - **Name:** `ledger-api-audience`
   - **Included Custom Audience:** `AUDIENCE`
5. Keep **Add to access token** enabled and save.

This keeps the app-specific mapper on the capture client instead of changing a realm-wide scope.

Use this private Compose file:

```dotenv
M2M_INDEXER_ENABLED=true
M2M_TOKEN_ENDPOINT=https://keycloak.example.com/realms/canton/protocol/openid-connect/token
M2M_CLIENT_ID=noves-canton-data-app-capture
M2M_CLIENT_SECRET=replace-with-the-generated-client-secret
M2M_AUDIENCE=https://canton.network.global
M2M_SCOPE=daml_ledger_api
```

Store it at `docker-compose/.state/capture.env` with mode `0600`.

## 3. Read the exact capture subject

Set shell variables without adding the secret to shell history, then request one client-credentials token:

```bash
read -r -p 'Keycloak URL: ' KEYCLOAK_URL
read -r -p 'Realm: ' REALM
read -r -p 'Capture client ID: ' M2M_CLIENT_ID
read -r -s -p 'Capture client secret: ' M2M_CLIENT_SECRET
printf '\n'
M2M_AUDIENCE=https://canton.network.global

TOKEN_RESPONSE="$(
  curl -fsS --request POST \
    "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=client_credentials \
    --data-urlencode client_id="$M2M_CLIENT_ID" \
    --data-urlencode client_secret="$M2M_CLIENT_SECRET" \
    --data-urlencode scope=daml_ledger_api
)"
TOKEN="$(jq -er '.access_token' <<<"$TOKEN_RESPONSE")"
PAYLOAD="$(cut -d. -f2 <<<"$TOKEN" | tr '_-' '/+')"
printf '%s' "$PAYLOAD===" | base64 -d 2>/dev/null |
  jq --arg audience "$M2M_AUDIENCE" \
    '{
      sub,
      iss,
      aud,
      audiencePresent: (
        if (.aud | type) == "array"
        then (.aud | index($audience) != null)
        else .aud == $audience
        end
      )
    }'
```

Confirm:

- `iss` is `KEYCLOAK_URL/realms/REALM`;
- `audiencePresent` is `true`; and
- `sub` is non-empty.

Copy the exact, case-sensitive `sub`. It is not necessarily the client ID or service-account display name.

Clear the credential and token variables when the check is complete:

```bash
unset M2M_CLIENT_SECRET TOKEN TOKEN_RESPONSE PAYLOAD
```

## 4. Create the matching Canton user

Create a Canton user whose ID exactly equals the observed token `sub`:

```scala
participant.ledger_api.users.create(
  id = "<exact-token-subject>",
  readAsAnyParty = true
)
```

If the user already exists, grant `CanReadAsAnyParty` and list its rights. Remove anything else. In particular, the user must not have participant or identity provider administration, act as, execute as, or rights for individual parties.

Use your validator's normal Canton administrator procedure to create or update the Canton user.

## 5. Verify the Noves Data App configuration

Follow [Verify authentication](verify.md).
