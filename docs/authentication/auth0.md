# Auth0 configuration

Create two Auth0 applications. The browser application signs users in; the M2M application
captures participant history. They must not share credentials.

In the examples below, `APP_URL` is the exact public URL, such as
`https://data.example.com`, and `AUDIENCE` is the API identifier used by the Canton validator.

## 1. Browser application

1. In **Applications > Applications**, select **Create Application**.
2. Choose **Single Page Web Applications**.
3. Name it for the Data App browser login.
4. Under **Application URIs**, set:
   - **Allowed Callback URLs:** `APP_URL/callback`
   - **Allowed Logout URLs:** `APP_URL`
   - **Allowed Web Origins:** `APP_URL`
5. Save and record the tenant domain and Client ID. A browser client has no client secret in the
   Data App configuration.

### Screenshot slot `auth0-spa-callbacks`

Auth0 application settings showing the three Application URI fields. Capture only the field
labels and example-host values; redact tenant identifiers.

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

### Screenshot slot `auth0-m2m-api-grant`

Auth0 M2M API authorization page showing the selected Canton API and its minimal grant. Redact
the client ID, tenant name, and any secrets.

Auth0 client-credentials tokens normally use `<client-id>@clients` as `sub`. Request a token and
confirm the actual claim for your tenant; the value is case-sensitive.

### Screenshot slot `auth0-token-subject`

Auth0 token inspection showing only the `sub`, `iss`, and `aud` claims. Never include the
access token or client secret.

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

### Screenshot slot `auth0-canton-rights`

Canton user-rights output showing `CanReadAsAnyParty` and no other rights. Redact participant
and party identifiers.

## 4. Verify

In the setup wizard, enter the tenant domain, browser Client ID, audience, M2M credentials, and
exact Canton user ID. Activation is blocked if discovery, token exchange, subject equality,
participant identity, or rights verification fails.

For a standard installation, verify the same properties before creating the capture Secret.
