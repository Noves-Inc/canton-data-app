# Docker Compose Keycloak Installation Design

**Date:** 2026-07-30

**Status:** Approved for implementation

## Goal

Make the standard Docker Compose package installable beside a validator
deployed with Canton's standard Compose bundle. The documented path must work
with Keycloak browser login, a dedicated Keycloak machine client for capture,
durable local volumes, and an existing host NGINX proxy.

The first live rehearsal targets `canton-testnet` and its existing
`canton-testnet` Keycloak realm.

## Current failures

The current package cannot complete a first installation as documented:

- its three default `4.0.0` image tags are not published;
- one `IMAGE_VERSION` cannot select the three current private prerelease
  artifacts, which use different tags and registries;
- `validator-app` is not a service name on the standard Compose network;
- capture credentials are marked optional and can silently disable capture;
- the installer does not generate an accounting credential-encryption key;
- optional export and backup S3 settings cannot be passed to the backend;
- the standard installer starts containers without preflight or readiness
  checks;
- the reverse-proxy instructions omit WebSocket forwarding and contain no
  tested NGINX example; and
- the Keycloak guide does not give exact Compose variables or connect the
  service-account token subject to the matching Canton user clearly enough.

The package also defaults `CANTON_NETWORK` to `mainnet`. Automatic detection is
deferred and documented in the backend design
`docs/superpowers/specs/2026-07-30-automatic-canton-network-detection-design.md`.
Until that backend change ships, a non-mainnet operator must set the variable
explicitly.

## Supported installation contract

### Images

Compose accepts one complete image reference per service:

```dotenv
BACKEND_IMAGE=repository/image:tag@sha256:digest
FRONTEND_IMAGE=repository/image:tag@sha256:digest
DATABASE_IMAGE=repository/image:tag@sha256:digest
```

The current v4 prerelease defaults match the chart:

```text
noves.azurecr.io/cda-backend:prod-3e1a1fde-1785439104@sha256:37cad1fe33871bf08ba1be9699c11e87c643931e51d295c9de7bfed8afe1c793
noves.azurecr.io/cda-frontend:prod-c78cdd33-1785419965@sha256:3205d0193e1b493098f9d1704604206f173fb456aa6fb6dbcc8b8529f70266b1
ghcr.io/noves-inc/noves-canton-database-v4:candidate-30160846627-1@sha256:1482f1bbe6ca9039ebe4bdcdf7442d34acf9389b2799215b95e10ee8d01ba49b
```

The values remain replaceable when public images ship. The docs state that
the prerelease images are private and require registry authentication.

### Canton services

The default external network remains
`splice-validator_splice_validator`.

The participant address remains `participant:5001`. The standard validator
service is `validator`, so the validator API default becomes
`http://validator:5003`.

`CANTON_NETWORK` remains required for this release. The example uses
`mainnet`, and the testnet rehearsal sets `testnet`. The guide explains why
non-mainnet deployments must change it and links to the deferred automatic
detection design.

### Local state and secrets

The default database and export stores remain named Docker volumes. S3 is
optional and does not replace the `/exports` volume unless the operator enables
it.

The backend must receive `ACCOUNTING_TOKEN_ENCRYPTION_KEY`. The installer
generates one 32-byte base64 value on first install and stores it in a
mode-0600 environment file. Rerunning or upgrading the installation reuses the
same value. The guide requires operators who install manually to generate,
protect, and back up the value with the database.

The capture environment file is required in the normal application manifest.
An absent file fails before containers start instead of launching the app without
capture.

The Noves gateway credential remains in the private
`.state/gateway.env` file and is injected only into the backend and frontend
containers that use it. The guide explains that Docker administrators can
inspect container environment values.

Optional export and backup credentials use separate mode-0600 environment
files. Empty non-secret endpoint, bucket, and region values keep S3 disabled.
The example does not place access keys in the ordinary `.env` file.

The nodes configuration bind mount must fail when its source file is absent.
Docker must not create a directory at the expected file path.

## Installer behavior

`install-compose.sh --standard` performs these checks before `up`:

1. Docker Compose is available.
2. `.env`, `.state/nodes-config.json`, `.state/capture.env`, the accounting
   environment file, and the gateway credential exist with private
   permissions.
3. Required placeholder values have been replaced.
4. The configured external Docker network exists.
5. `participant` and `validator` resolve on that network.
6. the three image references can be pulled with the operator's current
   registry credentials; and
7. the configured frontend and backend host ports are available.

The installer generates only the database password and accounting encryption
key when they are absent. It never generates or rotates OIDC, Canton, registry,
or Noves credentials.

After starting the services, it polls the backend's loopback
`/startup-status` and `/ready` endpoints. Failure output names the failing
service and prints the exact log and status commands. It does not claim the
application is installed merely because Docker created the containers.

## Keycloak contract

The installation uses two new clients and does not reuse the validator's
client:

| Client | Type | Purpose |
|---|---|---|
| `noves-canton-data-app-browser` | Public, authorization code with PKCE S256 | Human login |
| `noves-canton-data-app-capture` | Confidential, service accounts | Participant-wide capture |

For the live test:

```text
Keycloak URL: https://keycloak.testnet.noves.fi
Realm: canton-testnet
Application URL: https://cda-testnet.noves.fi
Browser callback: https://cda-testnet.noves.fi/callback
Token endpoint: https://keycloak.testnet.noves.fi/realms/canton-testnet/protocol/openid-connect/token
Ledger API audience: https://canton.network.global
Default scope: daml_ledger_api
```

The operator requests a client-credentials token and reads its exact `sub`
claim. The Canton user ID must equal that subject exactly and receive only
`CanReadAsAnyParty`. A token exchange, subject comparison, rights query, and
participant identity check must succeed before capture is considered
configured.

Use of the validator's participant-admin machine credential is transient and
limited to creating or verifying that Canton user after explicit operator
approval. The credential is not written to Noves App files or containers.

## NGINX and public URLs

The Compose package ships a focused NGINX include example for an existing host
proxy. It does not add another proxy container.

The live host uses:

```text
https://cda-testnet.noves.fi     -> 127.0.0.1:8091
https://api-cda-testnet.noves.fi -> 127.0.0.1:8090
```

Both names are one label below `noves.fi`, so the host's existing
`*.noves.fi` certificate covers them.

The frontend location forwards WebSocket upgrades with HTTP/1.1. Both
locations preserve `Host`, `X-Forwarded-For`, `X-Forwarded-Host`, and
`X-Forwarded-Proto`. Upstreams use Docker-aware or otherwise restart-safe
resolution so an NGINX reload does not fail solely because the app is temporarily
stopped.

The example is syntax-tested with NGINX in the repository test suite and again
on the live host before reload.

## Documentation structure

The Compose guide becomes one linear standard-install path:

1. Confirm resources, network, service names, and registry access.
2. Copy the files.
3. Set exact images, application URL, network, node identity, and Keycloak
   browser values.
4. Create capture, accounting, gateway, and optional S3 secret files.
5. Configure Keycloak and the matching Canton user.
6. Start with the installer.
7. Configure DNS and NGINX.
8. Verify readiness, OpenAPI, browser login, WebSocket upgrade, capture, and
   restart behavior.

Guided setup remains a separate optional section. Advanced performance tuning
moves after the working installation path. Repeated security warnings are
consolidated into the step where they affect an operator decision.

## Live acceptance criteria

The testnet rehearsal is complete when:

- the Noves App starts from new database and export volumes;
- all three containers use the pinned digests;
- the backend reports ready and `/docs/v1/openapi.json` returns JSON;
- both public hostnames work through NGINX and TLS;
- the frontend runtime configuration selects the `canton-testnet` Keycloak
  realm;
- browser login reaches the Noves App callback;
- the capture token subject equals the Canton user ID;
- that user has exactly `CanReadAsAnyParty`;
- participant-wide capture is running without a network mismatch;
- WebSocket requests upgrade through the frontend proxy; and
- stopping and starting the Compose project preserves the accounting key,
  database, exports, and readiness.

The rehearsal records every documentation or manifest defect found after the
first corrected deployment and fixes it before handoff.
