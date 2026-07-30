# Public Backend Routing Design

**Date:** 2026-07-30
**Status:** Approved for implementation
**Repository:** `canton-data-app`

## Problem

The v4 Helm chart exposes only the frontend Service. Requests to `/docs` on the
application hostname therefore return the frontend SPA instead of the backend
Swagger UI. Operators can reach the backend only through a port-forward or the
cluster-local Service.

The Compose manifest already publishes backend port 8090 on loopback, but its
bind address cannot be configured separately and the installation guide does
not identify the backend documentation URL or show how to proxy it under a
second hostname.

## Goals

- Give the backend its own public hostname when Helm routing uses Ingress or
  Istio.
- Enable backend routing by default whenever public Helm routing is enabled.
- Derive the default backend hostname by prefixing the frontend host with
  `api.`.
- Let an operator override the backend hostname or disable its public route.
- Route the complete backend API, including `/docs` and
  `/docs/v1/openapi.json`.
- Keep the Compose backend port published by default on loopback and make its
  bind address configurable.
- Document DNS, TLS, reverse-proxy, verification, and security requirements for
  both deployment methods.

## Non-goals

- The chart will not create DNS records or TLS certificates.
- The chart will not add authentication in front of Swagger UI.
- The Compose bundle will not ship a general-purpose TLS reverse proxy.
- This change will not alter backend endpoint authorization.
- The frontend hostname will not proxy backend documentation paths.

## Helm values contract

The chart adds a `backend` block under `routing`:

```yaml
routing:
  provider: ingress
  host: data.example.com
  tlsSecret: data-example-com-tls
  annotations: {}

  backend:
    enabled: true
    host: ""
    tlsSecret: ""

  ingress:
    className: nginx
```

`routing.backend.enabled` defaults to `true`. An empty
`routing.backend.host` resolves to `api.<routing.host>`. For example,
`data.example.com` produces `api.data.example.com`. A non-empty value replaces
the derived hostname.

For Kubernetes Ingress, an empty `routing.backend.tlsSecret` inherits
`routing.tlsSecret`. If both hostnames use the same Secret, its certificate must
cover both names. An explicit backend TLS Secret produces a separate TLS entry.

Istio terminates TLS at the configured Gateway. The Gateway certificate must
cover the frontend and backend hostnames. The chart does not manage the
Gateway or its certificate.

`routing.provider: none` creates no public route. The backend block remains
valid but has no effect. Setting `routing.backend.enabled: false` produces the
current frontend-only behavior for Ingress and Istio.

## Helm rendering

### Kubernetes Ingress

The existing Ingress remains the public routing resource. It contains:

- one host rule that sends `routing.host` to the frontend Service on port 3000;
- one host rule that sends the resolved backend host to the backend Service on
  port 8090 when backend routing is enabled;
- TLS host entries that use the shared or backend-specific Secret.

Both hosts use the configured IngressClass and common routing annotations. This
keeps cert-manager ownership in one resource and avoids duplicate controller
configuration.

### Istio

The existing VirtualService lists both public hosts. It matches the request
authority and routes the frontend hostname to port 3000 and the backend
hostname to port 8090. Disabling backend routing removes its host and route.

The VirtualService continues to use `routing.istio.gateway`.

### Helm notes

The installation notes print:

- the frontend URL;
- the backend base URL;
- the backend Swagger URL;
- the frontend and backend DNS names that must resolve to the ingress address;
- a backend port-forward command when public routing is disabled.

The notes use HTTPS when the Ingress has a TLS Secret. For Istio, the notes use
the scheme from `oidc.appUrl`, because TLS belongs to the external Gateway.

## Docker Compose contract

The standard manifest changes the backend port mapping to:

```yaml
ports:
  - "${BACKEND_BIND_ADDRESS:-127.0.0.1}:${BACKEND_PORT:-8090}:8090"
```

`.env.example` adds:

```dotenv
BACKEND_BIND_ADDRESS=127.0.0.1
BACKEND_PORT=8090
```

The backend stays published by default, and loopback remains the safe default.
Operators who use a host reverse proxy send:

- the frontend hostname to `127.0.0.1:8091`;
- the backend hostname to `127.0.0.1:8090`.

The Compose guide identifies `http://127.0.0.1:8090/docs` as the default local
Swagger URL. Production examples use `https://api.data.example.com/docs` after
the operator configures DNS, TLS, and the reverse proxy.

## Documentation changes

The main README and Helm guide require two DNS names for a routed production
installation. Both may point to the same load balancer address:

```text
data.example.com      -> ingress address
api.data.example.com  -> ingress address
```

The Helm guide explains shared and separate TLS Secrets, the Istio Gateway
certificate requirement, the backend-disable setting, and direct checks for
`/docs`, `/docs/v1/openapi.json`, `/health`, and `/ready`.

The Compose guide explains the two bind-address variables and shows the
frontend and backend reverse-proxy targets. It warns against setting
`BACKEND_BIND_ADDRESS=0.0.0.0` unless a firewall or trusted network limits
access.

The current statement that only the frontend is public will be replaced with a
description of the default two-host layout and the frontend-only opt-out.

## Security

Enabling backend routing publishes the complete backend API. Existing endpoint
authorization remains the enforcement boundary. Swagger UI, OpenAPI, health,
readiness, and startup-status retain their current public behavior.

Operators who need a BFF-only deployment set:

```yaml
routing:
  backend:
    enabled: false
```

Ingress annotations apply to both public hosts because the chart uses one
Ingress resource. An operator who needs different edge controls for each host
must enforce them in the ingress controller, external gateway, firewall, or
service mesh policy.

The chart will not place credentials, participant tokens, database passwords,
or gateway tokens in routes, notes, or generated documentation.

## Validation and failure behavior

The values schema requires `routing.backend.enabled`, `host`, and `tlsSecret`
with boolean and string types. Existing provider validation still requires the
frontend host and provider-specific settings.

Chart rendering derives the backend hostname only after the chart has a
non-empty frontend host. An explicit backend hostname takes precedence.
Disabling backend routing suppresses the backend host, TLS entry, notes, and
route.

The chart does not inspect certificate SANs or DNS. The documentation assigns
those checks to the operator before installation.

## Test coverage

Helm tests will render Ingress and Istio fixtures and verify:

- backend routing is enabled by default;
- the default hostname is `api.<frontend-host>`;
- both providers send backend traffic to port 8090;
- an explicit backend hostname replaces the derived hostname;
- disabling backend routing removes its host, TLS entry, and route;
- a shared TLS Secret covers both Ingress hosts;
- an explicit backend TLS Secret creates the expected second TLS mapping;
- the values schema rejects invalid backend routing types;
- Helm notes print the frontend, backend, Swagger, DNS, and port-forward
  instructions in the correct modes.

Compose tests will verify:

- the default backend binding is `127.0.0.1:8090`;
- `BACKEND_BIND_ADDRESS` and `BACKEND_PORT` override the rendered mapping;
- `.env.example` contains both variables;
- the guides identify the correct local and public documentation URLs.

The repository verification gate remains `tests/all.sh` followed by
`git diff --check`.

## Acceptance criteria

An operator can install with only the existing frontend routing values and get
two routes:

```text
https://data.example.com       -> frontend:3000
https://api.data.example.com   -> backend:8090
```

After DNS and TLS configuration, opening
`https://api.data.example.com/docs` loads the backend Swagger UI and
`https://api.data.example.com/docs/v1/openapi.json` returns the OpenAPI
document.

An operator can disable the backend route without changing the backend
Deployment or Service. A Compose operator can open the same documentation on
localhost or place a separate TLS reverse-proxy hostname in front of port 8090.
