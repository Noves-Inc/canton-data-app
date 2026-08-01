# Embedded Mode Integration Guide

Embed the Noves Data App inside a host application via iframe with full functionality and URL synchronization.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Data App Configuration](#data-app-configuration)
4. [Auth Mode 1: Own Login](#auth-mode-1-own-login)
5. [Auth Mode 2: Host Auth](#auth-mode-2-host-auth)
6. [Navigation & URL Sync (Both Modes)](#navigation--url-sync-both-modes)
7. [postMessage API Reference](#postmessage-api-reference)
8. [Complete Integration Examples](#complete-integration-examples)
9. [Deployment Recommendations](#deployment-recommendations)
10. [Verification & Testing](#verification--testing)
11. [Troubleshooting](#troubleshooting)

---

## Overview

The Data App supports an embedded mode with two authentication approaches, selected by the host via a URL query parameter:

| Mode | iframe URL | How Auth Works | Best For |
|------|-----------|----------------|----------|
| **Own Login** | `?embedded=true` | Data App shows its own Keycloak/Auth0 login inside the iframe | Host user and Canton participant user are **different** (e.g., node management platform where the platform user is not the Canton participant) |
| **Host Auth** | `?embedded=true&auth=host` | Host passes JWT tokens via `postMessage` — no login screen | Host and Data App share the **same** OIDC provider and user identity |

Both modes share: iframe embedding configuration, navigation events for URL sync, shareable URL rewriting, clipboard support, and accounting integration handling.

---

## Prerequisites

**Both modes:**
- Data App deployed and accessible from the host application's network
- At least one allowed host origin configured for embedded mode

**Own Login mode (additional):**
- Data App configured with **Keycloak** credentials (same as any standalone deployment)
- The OIDC provider must allow redirects from the Data App's URL
- Keycloak must be configured to allow its login page to render inside an iframe (see [Keycloak iframe configuration](#own-login-keycloak-configuration) below)

> **Important:** Own Login mode requires **Keycloak**. Auth0's Universal Login page blocks iframe rendering entirely (`X-Frame-Options: deny`) as a clickjacking protection, and this cannot be configured per-origin. If the Data App uses Auth0, use Host Auth mode instead.

**Host Auth mode (additional):**
- Host and Data App must use the **same** Keycloak or Auth0 instance and OIDC client. The refresh token must be issued to the client ID configured in the Data App.
- OIDC tokens must include the claims and scopes the Data App backend expects (e.g., `daml_ledger_api` scope for Keycloak). If using the same Keycloak instance that manages the Canton node, this works out of the box.

---

## Data App Configuration

The Data App requires a list of allowed host origins to enable embedding. The deployment package passes this list to the frontend as `EMBED_ALLOWED_ORIGINS`. The auth mode is selected by the host application via a URL query parameter — no additional Data App configuration is needed.

| Deployment | Setting | Required |
|------------|---------|----------|
| Docker Compose | `EMBED_ALLOWED_ORIGINS` with comma-separated origins | For embedded mode |
| Helm | `embedded.allowedOrigins` with a list of origins | For embedded mode |

### Docker Compose

Set the value in `docker-compose/.env`:

```dotenv
EMBED_ALLOWED_ORIGINS=https://host.example.com
```

The Compose package passes this setting to the frontend container. Recreate that container to apply the new environment:

```bash
docker compose --env-file .env -f compose.yaml up -d frontend
```

### Helm

Set the origins in your Helm values file and upgrade the release:

```yaml
embedded:
  allowedOrigins:
    - https://host.example.com
```

The chart converts the list to the frontend's `EMBED_ALLOWED_ORIGINS` setting.

### Multiple Origins

For Docker Compose, separate origins with commas:

```dotenv
EMBED_ALLOWED_ORIGINS=https://host.example.com,https://staging.host.example.com
```

For Helm, add each origin to the list:

```yaml
embedded:
  allowedOrigins:
    - https://host.example.com
    - https://staging.host.example.com
```

> **Important:** Each value must be the exact origin (protocol + domain + port) of the host application. Wildcards are not supported. When the origin list is empty, iframe embedding is blocked entirely (default behavior for standalone deployments).

---

## Auth Mode 1: Own Login

The simplest integration. The Data App handles authentication internally — the Keycloak login page renders inside the iframe. The host application only provides the iframe container.

This mode is appropriate when the host platform's user is **not** the same user who has credentials for the Canton participant (e.g., a node management platform where operators deploy Canton nodes for their customers, and each customer has their own Keycloak credentials to access the Data App).

### Own Login: Keycloak Configuration

By default, Keycloak's login page may block iframe rendering. To allow it, configure the Content Security Policy in your Keycloak realm:

1. Go to **Realm Settings** > **Security Defenses** in the Keycloak admin console
2. Under **Content-Security-Policy**, update the `frame-ancestors` directive to include the host application's origin:
   ```
   frame-src 'self'; frame-ancestors 'self' https://host.example.com; ...
   ```
3. Save the configuration

This allows Keycloak's login page to render inside the iframe hosted at the specified origin.

> **Important:** Only add the specific origin of the host application. Do not use `*` or remove frame-ancestors entirely, as this would disable clickjacking protection.

### Host Setup

```html
<iframe
  id="data-app"
  src="https://<data-app-url>/dashboard?embedded=true"
  allow="clipboard-write"
  style="width: 100%; height: 100%; border: none;"
></iframe>
```

The user sees the Data App's Keycloak login page inside the iframe, authenticates with their Canton participant credentials, and uses the app normally. No `postMessage` auth handshake is needed.

> **Important:** The `allow="clipboard-write"` attribute is required. Without it, browsers block the Clipboard API inside cross-origin iframes, and copy-to-clipboard features will fail silently.

### Optional: Pass Host Base URL

To make "Copy link" and "Share" features inside the Data App generate URLs pointing to the host's domain instead of the Data App's own URL, send a `noves:config` message after the iframe loads:

```js
const iframe = document.getElementById('data-app')

iframe.addEventListener('load', () => {
  iframe.contentWindow.postMessage({
    type: 'noves:config',
    hostBaseUrl: 'https://host.example.com/data-app'
  }, 'https://<data-app-url>')
})
```

---

## Auth Mode 2: Host Auth

The host application authenticates the user via its own OIDC provider and passes tokens to the Data App via `postMessage`. No login screen is shown inside the iframe — the user is authenticated instantly.

This mode is appropriate when the host and the Data App share the **same** OIDC provider and user identity.

### Host Setup

```html
<iframe
  id="data-app"
  src="https://<data-app-url>/dashboard?embedded=true&auth=host"
  allow="clipboard-write"
  style="width: 100%; height: 100%; border: none;"
></iframe>
```

Note the `&auth=host` parameter — this tells the Data App to wait for tokens from the host instead of showing its own login page.

### Send Tokens After `noves:ready`

The Data App emits a `noves:ready` message when it's loaded and ready to receive tokens. The host must wait for this event before sending authentication data.

```js
const DATA_APP_ORIGIN = 'https://<data-app-url>'
const iframe = document.getElementById('data-app')

window.addEventListener('message', (event) => {
  if (event.origin !== DATA_APP_ORIGIN) return

  if (event.data.type === 'noves:ready') {
    iframe.contentWindow.postMessage({
      type: 'noves:auth',
      token: keycloakAccessToken,
      refreshToken: keycloakRefreshToken,
      hostBaseUrl: 'https://host.example.com/data-app'
    }, DATA_APP_ORIGIN)
  }
})
```

**Fields in `noves:auth`:**

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | Must be `'noves:auth'` |
| `token` | Yes | JWT access token from the OIDC provider |
| `refreshToken` | Yes | OIDC refresh token. The Data App stores it in the browser and sends it to its BFF, which refreshes the user's access token server-side even when the tab is closed. It is not used for v4 global ledger capture; capture uses the deployment's M2M credentials. |
| `hostBaseUrl` | No | Base URL for shareable links (e.g., `https://host.example.com/data-app`). When set, "Copy link" features generate URLs pointing to the host domain. |

> **Important:** Always specify the target origin (second argument to `postMessage`) — never use `'*'`. This prevents token leakage to unintended windows.

---

## Navigation & URL Sync (Both Modes)

Regardless of which auth mode is used, the Data App emits `noves:navigation` events on every client-side route change. The host should listen for these to keep its URL bar in sync with the embedded app's current page.

### Listen for Navigation Events

```js
window.addEventListener('message', (event) => {
  if (event.origin !== 'https://<data-app-url>') return

  if (event.data.type === 'noves:navigation') {
    history.pushState(null, '', `/data-app${event.data.path}`)
  }
})
```

When a user clicks "Backend Status" inside the embedded Data App, the host URL updates to `host.example.com/data-app/backend-status`.

### Support Deep Links

When a user navigates directly to a host URL that maps to a Data App page (e.g., `host.example.com/data-app/backend-status`), the host should:

1. Extract the Data App path from the URL (`/backend-status`)
2. Set the iframe `src` to `https://<data-app-url>/backend-status?embedded=true` (add `&auth=host` for host-auth mode)
3. For host-auth mode: wait for `noves:ready` and send tokens as usual

This ensures bookmarks and shared links open the correct page inside the embedded app.

---

## postMessage API Reference

### Messages from Data App to Host

| Message | Auth Mode | When | Payload |
|---------|-----------|------|---------|
| `noves:ready` | Host Auth only | On load, when ready to receive tokens | `{ type: 'noves:ready' }` |
| `noves:navigation` | Both | On every client-side route change | `{ type: 'noves:navigation', path: '/dashboard' }` |

### Messages from Host to Data App

| Message | Auth Mode | When | Payload |
|---------|-----------|------|---------|
| `noves:auth` | Host Auth only | After receiving `noves:ready` | `{ type: 'noves:auth', token, refreshToken, hostBaseUrl }` |
| `noves:config` | Own Login (optional) | After iframe load | `{ type: 'noves:config', hostBaseUrl }` |

### Message Flow — Own Login

```
Host                              Data App (iframe)
 |                                     |
 |  (optional) noves:config ---------> |  (hostBaseUrl for shareable URLs)
 |                                     |
 |                                     |  (shows Keycloak login, user authenticates)
 |                                     |
 |  <-- noves:navigation ------------- |  (user navigates inside the app)
 |  (updates URL bar)                  |
```

### Message Flow — Host Auth

```
Host                              Data App (iframe)
 |                                     |
 |  <-- noves:ready ------------------- |  (iframe loaded, listener active)
 |                                     |
 |  --- noves:auth ------------------> |  (JWT + refresh token + hostBaseUrl)
 |                                     |
 |                                     |  (authenticates user, renders app)
 |                                     |
 |  <-- noves:navigation ------------- |  (user navigates inside the app)
 |  (updates URL bar)                  |
```

---

## Complete Integration Examples

### Own Login Mode (Minimal)

```html
<iframe
  id="data-app"
  src="https://dataapp.example.com/dashboard?embedded=true"
  allow="clipboard-write"
  style="width: 100%; height: calc(100vh - 60px); border: none;"
></iframe>

<script>
  const DATA_APP_ORIGIN = 'https://dataapp.example.com'

  window.addEventListener('message', (event) => {
    if (event.origin !== DATA_APP_ORIGIN) return
    if (event.data.type === 'noves:navigation') {
      history.pushState(null, '', `/data-app${event.data.path}`)
    }
  })
</script>
```

### Host Auth Mode (Full)

```html
<iframe
  id="data-app"
  src="https://dataapp.example.com/dashboard?embedded=true&auth=host"
  allow="clipboard-write"
  style="width: 100%; height: calc(100vh - 60px); border: none;"
></iframe>

<script>
  const DATA_APP_ORIGIN = 'https://dataapp.example.com'
  const HOST_BASE_URL = 'https://host.example.com/data-app'
  const iframe = document.getElementById('data-app')

  window.addEventListener('message', (event) => {
    if (event.origin !== DATA_APP_ORIGIN) return

    switch (event.data.type) {
      case 'noves:ready':
        iframe.contentWindow.postMessage({
          type: 'noves:auth',
          token: getAccessToken(),
          refreshToken: getRefreshToken(),
          hostBaseUrl: HOST_BASE_URL
        }, DATA_APP_ORIGIN)
        break

      case 'noves:navigation':
        history.pushState(null, '', `/data-app${event.data.path}`)
        break
    }
  })
</script>
```

A fully working demo application is available at [Noves-Inc/canton-data-app-embedded-demo](https://github.com/Noves-Inc/canton-data-app-embedded-demo).

---

## Deployment Recommendations

### Same-Site Subdomain (Recommended)

For the best user experience, deploy the Data App on a subdomain of the host's domain:

```
Host:     host.example.com
Data App: dataapp.host.example.com
```

This makes the iframe **same-site**, which means:

- User preferences (theme, table settings, selected party) persist across sessions
- No risk of third-party cookie/storage blocking from Safari, Chrome, or Firefox
- OIDC redirects in own-login mode work without cross-origin issues

### Cross-Origin Deployment

If the Data App is deployed on a completely separate origin, everything still works — authentication is handled within the iframe (own-login mode) or via postMessage (host-auth mode) regardless. However:

- User preferences may not persist between page reloads on browsers with strict third-party storage policies
- Preferences work within a single session but may reset on reload

---

## Verification & Testing

### Own Login Mode

1. **iframe loads:** Navigate to host page — Data App should render inside the iframe. If you see a CSP error, check `EMBED_ALLOWED_ORIGINS`.
2. **Login works:** The Keycloak login page should appear inside the iframe. After authenticating, the dashboard loads.
3. **Navigation sync:** Click through pages inside the Data App. The host URL bar should update (e.g., `/data-app/backend-status`).
4. **Clipboard:** Copy a party ID or transaction URL — should work if `allow="clipboard-write"` is set.

### Host Auth Mode

1. **Waiting state:** Load iframe with `?embedded=true&auth=host` — should show "Waiting for authentication..." spinner.
2. **Token handshake:** After host sends `noves:auth` in response to `noves:ready`, the app should authenticate and show the dashboard.
3. **Navigation sync:** Same as own-login mode.

### Standalone Regression

Run Compose with `EMBED_ALLOWED_ORIGINS` empty, or Helm with `embedded.allowedOrigins: []` — the app should behave identically to a normal standalone deployment.

---

## Troubleshooting

### iframe shows "Refused to connect" or is blank

**Symptoms:** The iframe area is empty or shows a browser error page.

**Common causes:**

1. **No allowed origins configured** — The Data App blocks all iframe embedding when `EMBED_ALLOWED_ORIGINS` is empty or `embedded.allowedOrigins` is an empty list.
   - **Solution:** Add the host's exact origin using the setting for your deployment package.

2. **Origin mismatch** — The value in `EMBED_ALLOWED_ORIGINS` doesn't match the host's actual origin.
   - **Solution:** Ensure the origin includes the protocol and port if non-standard (e.g., `https://host.example.com`, not `host.example.com`).

3. **Frontend not recreated or redeployed** — The setting changed but the existing frontend container still has its old environment.
   - **Solution:** Run the Compose `up -d frontend` command above, or upgrade the Helm release. Helm rolls the frontend pod when its ConfigMap changes.

### Own Login: Auth0 login page shows error or refuses to load

**Symptoms:** The iframe loads but Auth0's Universal Login shows an error page, a blank page, or "Oops!, something went wrong."

**Cause:** Auth0 blocks its Universal Login page from rendering inside iframes entirely. Auth0 sets `X-Frame-Options: deny` and `Content-Security-Policy: frame-ancestors 'none'` on all login pages as clickjacking protection. This cannot be configured per-origin.

**Solution:** Own Login mode is not compatible with Auth0. Use **Host Auth mode** (`?embedded=true&auth=host`) instead, where the host application authenticates via Auth0 and passes tokens to the Data App via postMessage.

### Own Login: Keycloak login page doesn't render inside iframe

**Symptoms:** The iframe loads but the Keycloak login page doesn't appear, or redirects fail.

**Common causes:**

1. **Keycloak blocks iframe rendering** — By default, Keycloak sets `X-Frame-Options: SAMEORIGIN` and `frame-ancestors 'self'` which block cross-origin iframe rendering.
   - **Solution:** In Keycloak admin console, go to **Realm Settings > Security Defenses > Headers**. Clear the **X-Frame-Options** field (leave empty), and update **Content-Security-Policy** to add the host origin to `frame-ancestors`: `frame-src 'self'; frame-ancestors 'self' https://host.example.com; object-src 'none';`

2. **Redirect URI mismatch** — The Data App's `VITE_KEYCLOAK_REDIRECT_URI` doesn't match the Data App's actual URL.
   - **Solution:** Ensure the redirect URI points to the Data App's own URL (e.g., `https://dataapp.host.example.com/callback`), not the host's URL.

3. **Third-party cookie blocking** — Cross-origin iframes may have `sessionStorage` blocked, breaking the OIDC PKCE flow.
   - **Solution:** Deploy the Data App on a same-site subdomain. See [Deployment Recommendations](#deployment-recommendations).

### Host Auth: User sees "Waiting for authentication..." indefinitely

**Symptoms:** The Data App renders inside the iframe but shows a loading spinner with "Waiting for authentication..."

**Common causes:**

1. **Missing `&auth=host`** — The iframe URL doesn't include `auth=host`, so the Data App shows its own login instead of waiting for tokens.
   - **Solution:** Append `&auth=host` to the iframe `src`.

2. **Tokens sent before `noves:ready`** — The `postMessage` was sent before the Data App's listener was active.
   - **Solution:** Always wait for the `noves:ready` message before sending `noves:auth`.

3. **Invalid JWT** — The token is from a different OIDC provider than the Data App expects.
   - **Solution:** Verify both the host and Data App use the same Keycloak or Auth0 instance.

### Copy-to-clipboard not working

**Symptoms:** Clicking "Copy" buttons inside the embedded Data App does nothing.

**Cause:** The browser blocks the Clipboard API in cross-origin iframes unless explicitly permitted.

**Solution:** Add `allow="clipboard-write"` to the iframe element.

### User preferences reset on every page load

**Symptoms:** Theme, table settings, or selected party revert to defaults each time the page reloads.

**Cause:** The browser is blocking `localStorage` access in the cross-origin iframe.

**Solution:** Deploy the Data App on a same-site subdomain of the host. See [Deployment Recommendations](#deployment-recommendations).

### Own Login: "Connection blocked" error during Keycloak redirect (local development only)

**Symptoms:** After authenticating on Keycloak, the redirect back to the Data App fails with: "The connection is blocked because it was initiated by a public page to connect to devices or servers on your local network."

**Cause:** Chrome's [Local Network Access](https://developer.chrome.com/blog/local-network-access) (LNA) protection blocks requests from public origins (e.g., `keycloak.example.com`) to private/local addresses (e.g., `localhost`). This only happens when the Data App runs on `localhost` while Keycloak is on a remote domain.

**Solution:** This does not affect production deployments where both the Data App and Keycloak are on public or same-network domains. For local development only: go to `chrome://flags/#local-network-access-check`, set to **Disabled**, and relaunch Chrome. Re-enable after testing.
