# Auth0 configuration

Create two Auth0 applications. The browser application signs users in; the M2M application
captures participant history. They must not share credentials.

In the examples below, `APP_URL` is the exact public URL, such as
`https://data.example.com`, and `AUDIENCE` is the API identifier used by the Canton validator.

## 1. Browser application

1. In **Applications > Applications**, select **Create Application**.
2. Choose **Single Page Web Applications**.
3. Name it for the Noves App browser login.
4. Under **Application URIs**, set:
   - **Allowed Callback URLs:** `APP_URL/callback`
   - **Allowed Logout URLs:** `APP_URL`
   - **Allowed Web Origins:** `APP_URL`
5. Save and record the tenant domain and Client ID. A browser client has no client secret in the
   Noves App configuration.

Use these Helm values:

```yaml
oidc:
  provider: auth0
  appUrl: https://data.example.com
  auth0:
    domain: tenant.example.auth0.com
    clientId: replace-with-browser-client-id
    audience: https://canton.network.global
```

For Compose, use the equivalent `VITE_AUTH0_*` values in `.env`.

## 2. Dedicated capture application

1. Create another application and choose **Machine to Machine Applications**.
2. Select the API whose identifier is `AUDIENCE`.
3. Authorize only the scopes required to obtain a Canton Ledger API token.
4. Record the M2M Client ID, Client Secret, audience, and token endpoint. The token endpoint is
   normally `https://TENANT_DOMAIN/oauth/token`.
5. Do not authorize the M2M application for unrelated APIs.

Auth0 client-credentials tokens normally use `<client-id>@clients` as `sub`. Request a token and
confirm the actual claim for your tenant; the value is case-sensitive.

```bash
TOKEN_RESPONSE="$(
  curl -fsS --request POST "https://$AUTH0_DOMAIN/oauth/token" \
    --header 'content-type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=client_credentials \
    --data-urlencode client_id="$M2M_CLIENT_ID" \
    --data-urlencode client_secret="$M2M_CLIENT_SECRET" \
    --data-urlencode audience="$AUDIENCE"
)"
TOKEN="$(jq -er '.access_token' <<<"$TOKEN_RESPONSE")"
PAYLOAD="$(cut -d. -f2 <<<"$TOKEN" | tr '_-' '/+')"
printf '%s' "$PAYLOAD===" | base64 -d 2>/dev/null | jq '{sub,iss,aud}'
unset TOKEN TOKEN_RESPONSE PAYLOAD
```

Copy the exact `sub`, then clear the shell variables that contain credentials.

## 3. Matching Canton user

Create a Canton user whose ID exactly equals the token's `sub`, then grant only
`CanReadAsAnyParty`. The console pattern is:

```scala
participant.ledger_api.users.create(
  id = "<exact-token-subject>",
  readAsAnyParty = true
)
```

Leave all administration, act-as, execute-as, and per-party rights unset. See
[Security](../security.md) for the complete boundary.

In guided setup, the installer can detect the Auth0 tenant URL and audience from the validator
configuration. After you create and enter the dedicated capture application, the wizard asks for
explicit confirmation and can create this Canton user automatically. It does not create or
modify the Auth0 application. If automatic participant provisioning is unavailable, use the
copyable `grpcurl -expand-headers` commands shown by the wizard.

## 4. Verify

In the setup wizard, enter the tenant domain, browser Client ID, audience, M2M credentials, and
exact Canton user ID. Activation is blocked if discovery, token exchange, subject equality,
participant identity, or rights verification fails.

For a standard installation, follow the copyable participant-ID and `grpcurl -expand-headers`
commands in [Helm installation](../helm.md) before creating the capture Secret.
