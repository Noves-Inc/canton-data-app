# Embedded Mode Integration Guide

Embed the Noves Data App inside a host application via iframe with seamless authentication and URL synchronization.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Data App Configuration](#data-app-configuration)
4. [Host Application Setup](#host-application-setup)
5. [postMessage API Reference](#postmessage-api-reference)
6. [Complete Integration Example](#complete-integration-example)
7. [Deployment Recommendations](#deployment-recommendations)
8. [Verification & Testing](#verification--testing)
9. [Troubleshooting](#troubleshooting)

---

## Overview

The Data App supports an embedded mode that allows a host application to render it inside an iframe. The app retains its full UI — header, Noves logo, navigation, footer, and all functionality. No separate builds or deploy coordination required.

### How It Works

1. The host authenticates the user via its own OIDC provider (Keycloak, Auth0, etc.)
2. The host renders the Data App in an iframe with `?embedded=true`
3. The Data App emits a `noves:ready` event when it's ready to receive tokens
4. The host passes the JWT and refresh token via `postMessage`
5. The Data App authenticates the user instantly — no login screen, no redirects
6. As the user navigates inside the Data App, it emits route change events so the host URL bar stays in sync
7. Shareable URLs generated inside the Data App point to the host's domain

### Architecture

```
Host Application (e.g., host.example.com)
├── Authenticates user via Keycloak/Auth0
├── Renders iframe -> Data App URL + ?embedded=true
├── Sends JWT via postMessage (on noves:ready)
├── Listens for noves:navigation events
│   └── Updates host URL bar (history.pushState)
│
└── iframe: Noves Data App (e.g., dataapp.example.com)
    ├── Emits noves:ready when loaded
    ├── Receives JWT via postMessage
    ├── Authenticates user (no OIDC redirect)
    ├── Registers refresh token for server-side indexer keepalive
    └── Emits noves:navigation on every route change
```

---

## Prerequisites

- **Data App** deployed and accessible from the host application's network
- **Shared OIDC provider** — the host and Data App must use the same Keycloak or Auth0 instance, so the JWT tokens are valid for both
- The OIDC tokens must include the claims and scopes the Data App backend expects (e.g., `daml_ledger_api` scope for Keycloak). If the host uses the same Keycloak instance that manages the Canton node, this works out of the box.

> **Important:** The host application must already have the user authenticated before loading the embedded Data App. The Data App does not show a login screen in embedded mode — it waits for tokens from the host.

---

## Data App Configuration

The Data App requires one environment variable to enable embedding. All other embedded mode behavior is activated automatically when the host loads the app with `?embedded=true`.

| Variable | Required | Description |
|----------|----------|-------------|
| `EMBED_ALLOWED_ORIGINS` | Yes | Comma-separated list of origins allowed to embed the Data App |

### Docker Compose

Add to the frontend service environment:

```yaml
environment:
  EMBED_ALLOWED_ORIGINS: "https://host.example.com"
```

### Kubernetes

Add to the frontend ConfigMap (`manifests/configmaps.yaml`):

```yaml
EMBED_ALLOWED_ORIGINS: "https://host.example.com"
```

### Multiple Origins

To allow embedding from multiple origins (e.g., production and staging):

```bash
EMBED_ALLOWED_ORIGINS=https://host.example.com,https://staging.host.example.com
```

> **Important:** The value must be the exact origin (protocol + domain + port) of the host application. Wildcards are not supported. When this variable is not set, iframe embedding is blocked entirely (default behavior for standalone deployments).

---

## Host Application Setup

### 1. Render the Data App in an iframe

```html
<iframe
  id="data-app"
  src="https://<data-app-url>/dashboard?embedded=true"
  allow="clipboard-write"
  style="width: 100%; height: 100%; border: none;"
></iframe>
```

**Required attributes:**

| Attribute | Purpose |
|-----------|---------|
| `src` | Data App URL with `?embedded=true` query parameter |
| `allow="clipboard-write"` | Enables copy-to-clipboard inside the iframe. Without this, the Clipboard API is blocked by the browser in cross-origin iframes. |

### 2. Listen for `noves:ready` and send authentication tokens

The Data App emits a `noves:ready` message when it's loaded and ready to receive tokens. The host should wait for this event before sending authentication data.

```js
const DATA_APP_ORIGIN = 'https://<data-app-url>'
const iframe = document.getElementById('data-app')

window.addEventListener('message', (event) => {
  // Always validate the message origin
  if (event.origin !== DATA_APP_ORIGIN) return

  if (event.data.type === 'noves:ready') {
    // Data App is ready — send authentication tokens
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
| `refreshToken` | Yes | OIDC refresh token. The Data App uses this server-side to keep backend indexers alive by autonomously refreshing the JWT before it expires. |
| `hostBaseUrl` | No | Base URL for shareable links (e.g., `https://host.example.com/data-app`). When set, "Copy link" features inside the Data App generate URLs pointing to the host domain instead of the Data App domain. |

> **Important:** Always specify the target origin (second argument to `postMessage`) — never use `'*'`. This prevents token leakage to unintended windows.

### 3. Listen for navigation events

As the user navigates inside the Data App, it emits `noves:navigation` events with the current path. The host should listen for these to keep its URL bar in sync.

```js
window.addEventListener('message', (event) => {
  if (event.origin !== DATA_APP_ORIGIN) return

  if (event.data.type === 'noves:navigation') {
    // Update host URL bar to reflect the Data App page
    history.pushState(null, '', `/data-app${event.data.path}`)
  }
})
```

**Fields in `noves:navigation`:**

| Field | Description |
|-------|-------------|
| `type` | Always `'noves:navigation'` |
| `path` | Relative path within the Data App (e.g., `/dashboard`, `/backend-status`, `/exports`) |

### 4. Support deep links

When a user navigates directly to a host URL that maps to a Data App page (e.g., `host.example.com/data-app/backend-status`), the host should:

1. Extract the Data App path from the URL (`/backend-status`)
2. Set the iframe `src` to `https://<data-app-url>/backend-status?embedded=true`
3. Wait for `noves:ready` and send the JWT as usual

This ensures bookmarks and shared links open the correct page inside the embedded app.

---

## postMessage API Reference

### Messages from Data App to Host

| Message Type | When | Payload |
|-------------|------|---------|
| `noves:ready` | On load, when the Data App is ready to receive tokens | `{ type: 'noves:ready' }` |
| `noves:navigation` | On every client-side route change | `{ type: 'noves:navigation', path: '/dashboard' }` |

### Messages from Host to Data App

| Message Type | When | Payload |
|-------------|------|---------|
| `noves:auth` | After receiving `noves:ready` | `{ type: 'noves:auth', token, refreshToken, hostBaseUrl }` |

### Message Flow

```
Host                              Data App (iframe)
 |                                     |
 |  <-- noves:ready ------------------ |  (iframe loaded, listener active)
 |                                     |
 |  --- noves:auth ------------------> |  (JWT + refresh token + hostBaseUrl)
 |                                     |
 |                                     |  (authenticates user, renders app)
 |                                     |
 |  <-- noves:navigation ------------- |  (user clicks "Backend Status")
 |                                     |
 |  (updates URL bar)                  |
 |                                     |
```

---

## Complete Integration Example

A minimal but complete host application implementation:

```html
<!DOCTYPE html>
<html>
<head><title>Host Application</title></head>
<body>
  <header>
    <h1>My Platform</h1>
    <nav><!-- host navigation --></nav>
  </header>

  <iframe
    id="data-app"
    src="https://dataapp.example.com/dashboard?embedded=true"
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
          // Data App is ready — send tokens
          iframe.contentWindow.postMessage({
            type: 'noves:auth',
            token: getAccessToken(),       // your OIDC access token
            refreshToken: getRefreshToken(), // your OIDC refresh token
            hostBaseUrl: HOST_BASE_URL
          }, DATA_APP_ORIGIN)
          break

        case 'noves:navigation':
          // Sync host URL bar with Data App navigation
          history.pushState(null, '', `/data-app${event.data.path}`)
          break
      }
    })

    // Deep link support: load the correct Data App page from host URL
    const path = window.location.pathname
    if (path.startsWith('/data-app/')) {
      const appPath = path.replace('/data-app', '')
      iframe.src = `${DATA_APP_ORIGIN}${appPath}?embedded=true`
    }
  </script>
</body>
</html>
```

A fully working demo application is available at [Noves-Inc/canton-data-app-embedded-demo](https://github.com/Noves-Inc/canton-data-app-embedded-demo).

---

## Deployment Recommendations

### Same-Site Subdomain (Recommended)

For the best user experience, deploy the Data App on a subdomain of the host's domain:

```
Host:     host.example.com
Data App: dataapp.host.example.com    (same-site subdomain)
```

This makes the iframe **same-site**, which means:

- User preferences (theme, table settings, selected party) persist across sessions
- No risk of third-party cookie/storage blocking from Safari, Chrome, or Firefox

### Cross-Origin Deployment

If the Data App is deployed on a completely separate origin (e.g., `dataapp.otherdomain.com`), everything still works — authentication is handled via `postMessage` regardless. However:

- User preferences may not persist between page reloads on browsers with strict third-party storage policies (Safari, Firefox strict mode, Chrome with third-party cookie phase-out)
- Preferences work within a single session but may reset on reload

---

## Verification & Testing

After completing the integration, verify each step of the handshake:

### 1. iframe loads without CSP blocking

Open the browser DevTools Console. If you see:

```
Refused to frame 'https://dataapp.example.com/' because an ancestor violates the Content Security Policy
```

Check that `EMBED_ALLOWED_ORIGINS` is set correctly in the Data App deployment and that the origin matches exactly (protocol + domain + port).

### 2. `noves:ready` is received

In the host application's Console, confirm that a `noves:ready` message arrives from the Data App. If it doesn't:

- Verify the iframe `src` includes `?embedded=true`
- Check that the Data App loaded successfully inside the iframe (no network errors)

### 3. Authentication works

After sending `noves:auth`, the Data App should display the dashboard without showing a login screen. If you see "Waiting for authentication..." instead:

- The `noves:auth` message was not received — check that it's sent after `noves:ready`
- The token may be invalid — verify the JWT is from the same OIDC provider the Data App is configured to use

### 4. Navigation sync works

Click through pages inside the embedded Data App. The host URL bar should update to reflect the current page (e.g., `/data-app/backend-status`).

### 5. Clipboard works

Use a "Copy" button inside the embedded Data App (e.g., copy a party ID or transaction URL). If it fails silently, check that the iframe has `allow="clipboard-write"`.

---

## Troubleshooting

### iframe shows "Refused to connect" or is blank

**Symptoms:** The iframe area is empty or shows a browser error page.

**Common causes:**

1. **`EMBED_ALLOWED_ORIGINS` not set** — The Data App blocks all iframe embedding by default.
   - **Solution:** Set `EMBED_ALLOWED_ORIGINS` to the host's origin in the Data App deployment.

2. **Origin mismatch** — The value in `EMBED_ALLOWED_ORIGINS` doesn't match the host's actual origin.
   - **Solution:** Ensure the origin includes the protocol and port if non-standard (e.g., `https://host.example.com`, not `host.example.com`).

3. **Data App not restarted** — The environment variable was added but the server wasn't restarted.
   - **Solution:** Restart the Data App container to pick up the new configuration.

### User sees login screen instead of being authenticated

**Symptoms:** The Data App renders inside the iframe but shows the login page with "Waiting for authentication..." or the standard OIDC login button.

**Common causes:**

1. **Tokens sent before `noves:ready`** — The `postMessage` was sent before the Data App's listener was active.
   - **Solution:** Always wait for the `noves:ready` message before sending `noves:auth`.

2. **Invalid JWT** — The token is from a different OIDC provider than the Data App expects.
   - **Solution:** Verify both the host and Data App use the same Keycloak or Auth0 instance.

3. **Missing `?embedded=true`** — The iframe URL doesn't include the query parameter.
   - **Solution:** Append `?embedded=true` to the iframe `src`.

### Copy-to-clipboard not working

**Symptoms:** Clicking "Copy" buttons inside the embedded Data App does nothing.

**Cause:** The browser blocks the Clipboard API in cross-origin iframes unless explicitly permitted.

**Solution:** Add `allow="clipboard-write"` to the iframe element.

### User preferences reset on every page load

**Symptoms:** Theme, table settings, or selected party revert to defaults each time the page reloads.

**Cause:** The browser is blocking `localStorage` access in the cross-origin iframe (common in Safari and Firefox strict mode).

**Solution:** Deploy the Data App on a same-site subdomain of the host. See [Deployment Recommendations](#deployment-recommendations).
