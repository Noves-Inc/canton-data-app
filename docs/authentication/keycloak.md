# Keycloak configuration

The Noves Data App needs two Keycloak clients:

| Client | Type | Use |
|---|---|---|
| `noves-canton-data-app-browser` | Public, authorization code with PKCE | Human sign-in |
| `noves-canton-data-app-m2m-indexing` | Confidential, service account | Background participant M2M indexing |

Do not reuse the validator client. In the examples, replace:

- `APP_URL` with the exact public frontend URL;
- `KEYCLOAK_URL` with the Keycloak base URL, without `/realms/...`;
- `REALM` with the validator realm; and
- `AUDIENCE` with the validator Ledger API audience, normally `https://canton.network.global`.

Both the browser and M2M access tokens must contain `AUDIENCE`. Assign the Ledger API scope and audience to each client separately. `AUDIENCE` is the Ledger API identifier, not the M2M client ID.

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
9. Ensure the browser access token contains `AUDIENCE`. Follow [Add the Ledger API audience](#add-the-ledger-api-audience).

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

### Browser users

Users sign in with normal human accounts from this realm, not with the M2M service account. Each browser access token's exact, case-sensitive `sub` must match a Canton user on the selected participant. That Canton user's `CanReadAs` and `CanActAs` rights determine which parties the user can read or act as in the UI.

Creating the M2M client in the next section does not replace or modify browser users. Existing browser users can continue to sign in as long as their token subjects remain unchanged and their new tokens contain the Ledger API audience.

## 2. Create the M2M indexing client

1. Create another OpenID Connect client with client ID `noves-canton-data-app-m2m-indexing`.
2. In **Capability config**:
   - enable **Client authentication**;
   - disable **Standard flow**;
   - disable **Direct access grants**; and
   - enable **Service accounts roles**.
3. Leave **Root URL** and **Home URL** blank in **Login settings**, then save the client.
4. Assign `daml_ledger_api` as a default client scope. Follow [Assign the Ledger API scope](#assign-the-ledger-api-scope).
5. Ensure the M2M access token contains `AUDIENCE`. Follow [Add the Ledger API audience](#add-the-ledger-api-audience).
6. Open **Credentials** and record the generated client secret.

### Assign the Ledger API scope

On the client's **Client scopes** tab:

1. Select **Add client scope**.
2. Select the checkbox next to `daml_ledger_api`.
3. Open the **Add** menu and choose **Default**.
4. Confirm that the `daml_ledger_api` row shows **Default**.

### Add the Ledger API audience

Repeat this check for both the browser and M2M clients. If the realm already provides a client scope that adds the exact Ledger API audience, assign that scope as **Default** to the client and verify the resulting token. Otherwise add an audience mapper to the client's dedicated scope:

1. Open the client and select **Client scopes**.
2. Open the row whose name ends in `-dedicated`.
3. Select **Configure a new mapper**, then choose **Audience**.
4. Set:
   - **Name:** `ledger-api-audience`
   - **Included Custom Audience:** `AUDIENCE`
5. Keep **Add to access token** enabled and save.

This keeps the app-specific mapper on the selected client instead of changing a realm-wide scope. Configure the mapper independently on both clients. Do not add `noves-canton-data-app-m2m-indexing` as the browser token's Ledger API audience.

### Store the M2M client credentials

Use this private Compose file:

```dotenv
M2M_TOKEN_ENDPOINT=https://keycloak.example.com/realms/canton/protocol/openid-connect/token
M2M_CLIENT_ID=noves-canton-data-app-m2m-indexing
M2M_CLIENT_SECRET=replace-with-the-generated-client-secret
M2M_AUDIENCE=https://canton.network.global
M2M_SCOPE=daml_ledger_api
```

Store it at `docker-compose/.state/m2m-indexing.env` with mode `0600`.

## 3. Read the exact M2M indexing subject

Set shell variables without adding the secret to shell history, then request one client-credentials token:

```bash
read -r -p 'Keycloak URL: ' KEYCLOAK_URL
read -r -p 'Realm: ' REALM
read -r -p 'M2M indexing client ID: ' M2M_CLIENT_ID
read -r -s -p 'M2M indexing client secret: ' M2M_CLIENT_SECRET
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

## 4. Create the matching M2M Canton user

Create a Canton user whose ID exactly equals the observed token `sub`:

```scala
participant.ledger_api.users.create(
  id = "<exact-token-subject>",
  readAsAnyParty = true
)
```

If the user already exists, grant `CanReadAsAnyParty` and list its rights. Remove anything else. In particular, the user must not have participant or identity provider administration, act as, execute as, or rights for individual parties.

Use your validator's normal Canton administrator procedure to create or update the Canton user.

When the same M2M credentials are used for multiple distinct participants, create this same user ID with the same restricted right on every participant. The participants authorize the token independently; authorization on one participant does not propagate to another.

## 5. Verify the Noves Data App configuration

Follow [Verify authentication](verify.md).
