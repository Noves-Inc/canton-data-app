# Docker Compose installation

This path installs the Noves App beside a validator deployed with Canton's standard
Docker Compose bundle. It uses the existing
`splice-validator_splice_validator` network, `participant:5001`, and
`http://validator:5003`.

The setup wizard is optional. The steps below describe a standard installation
whose configuration stays in local files.

## 1. Check the host

The Noves App adds a database, backend, and frontend to the validator host. Check CPU,
memory, and disk before starting; initial capture and read-model catch-up add
load until the app reaches the ledger end.

Confirm the standard network and services:

```bash
docker network inspect splice-validator_splice_validator >/dev/null
docker ps \
  --filter label=com.docker.compose.service=participant \
  --filter network=splice-validator_splice_validator
docker ps \
  --filter label=com.docker.compose.service=validator \
  --filter network=splice-validator_splice_validator
```

Both commands must list a running container. If your Compose project uses
another network, record its name for `CANTON_DOCKER_NETWORK`.

The current v4 prerelease images are private. Authenticate before installation:

```bash
docker login noves.azurecr.io
docker login ghcr.io
```

The shipped `.env.example` pins `BACKEND_IMAGE=`, `FRONTEND_IMAGE=`, and
`DATABASE_IMAGE=` independently by tag and digest. Do not remove a digest
unless you are deliberately testing a different build.

## 2. Prepare the installation files

From a checkout of this repository:

```bash
export APP_INSTALL_DIR=/opt/noves-canton-data-app-v4
mkdir -p "$APP_INSTALL_DIR/docker-compose/.state"
mkdir -p "$APP_INSTALL_DIR/docker-compose/.secrets"
cp docker-compose/.env.example "$APP_INSTALL_DIR/docker-compose/.env"
cp docker-compose/config/nodes-config.json \
  "$APP_INSTALL_DIR/docker-compose/.state/nodes-config.json"
```

Edit `.env`:

- replace `APP_URL` with the public frontend URL;
- leave the three image references pinned;
- set `CANTON_DOCKER_NETWORK` if the validator uses a nonstandard network;
- set `CANTON_VALIDATOR_URL` only if `http://validator:5003` is not reachable;
- set `NOVES_PUBLIC_API_URL` only when Noves supplied a non-default public API
  endpoint; the default is `https://api.canton.noves.fi`;
- set `CANTON_NETWORK=testnet` or `CANTON_NETWORK=devnet` for a non-mainnet
  participant; and
- configure exactly one browser OIDC provider.

The app does not yet detect the network early enough to configure every
network-dependent subsystem. Omitting `CANTON_NETWORK=testnet` on testnet makes
the backend assume mainnet and quarantine capture when it detects the
mismatch.

Replace `REPLACE_WITH_PARTICIPANT_ID` in
`.state/nodes-config.json` with the complete participant ID returned by the
participant. Keep the address as `participant:5001` for the standard bundle.

## 3. Configure browser login and capture

Create separate browser and capture clients. Do not reuse the validator's
client.

- [Keycloak](authentication/keycloak.md)
- [Auth0](authentication/auth0.md)

For Keycloak, `.env` contains the public browser settings:

```dotenv
APP_URL=https://data.example.com
VITE_AUTH0_DOMAIN=
VITE_AUTH0_CLIENT_ID=
VITE_AUTH0_AUDIENCE=
VITE_KEYCLOAK_URL=https://keycloak.example.com
VITE_KEYCLOAK_REALM=canton
VITE_KEYCLOAK_CLIENT_ID=noves-canton-data-app-browser
```

Create `.state/capture.env` with the dedicated machine client:

```dotenv
M2M_INDEXER_ENABLED=true
M2M_TOKEN_ENDPOINT=https://keycloak.example.com/realms/canton/protocol/openid-connect/token
M2M_CLIENT_ID=noves-canton-data-app-capture
M2M_CLIENT_SECRET=replace-with-the-generated-client-secret
M2M_AUDIENCE=https://canton.network.global
M2M_SCOPE=daml_ledger_api
```

The capture token's exact `sub` must match a Canton user with only
`CanReadAsAnyParty`. The installer treats a missing or incomplete capture file
as an error instead of silently starting without capture.

## 4. Create local secrets

Obtain the installation-specific Noves gateway credential from Noves, then
write it without adding it to `.env`:

```bash
umask 077
printf '%s\n' 'replace-with-the-installation-credential' \
  > "$APP_INSTALL_DIR/docker-compose/.secrets/noves-gateway-auth-token"
```

`install-compose.sh` generates the database password when `.env` still
contains the example placeholder. It also creates
`.state/accounting.env` with a random 32-byte
`ACCOUNTING_TOKEN_ENCRYPTION_KEY`. The file is reused on every installer run.
Back it up with the database: replacing it makes stored accounting-provider
credentials unreadable.

For a manual installation that does not use the installer, generate it once:

```bash
umask 077
printf 'ACCOUNTING_TOKEN_ENCRYPTION_KEY=%s\n' \
  "$(openssl rand -base64 32 | tr -d '\n')" \
  > "$APP_INSTALL_DIR/docker-compose/.state/accounting.env"
```

Protect all local configuration:

```bash
chmod 600 \
  "$APP_INSTALL_DIR/docker-compose/.env" \
  "$APP_INSTALL_DIR/docker-compose/.state/capture.env" \
  "$APP_INSTALL_DIR/docker-compose/.state/nodes-config.json" \
  "$APP_INSTALL_DIR/docker-compose/.secrets/noves-gateway-auth-token"
```

The installer applies mode `0600` to the generated accounting file.

### Optional S3-compatible storage

The default deployment writes exports to the named
`noves-canton-data-app-v4-exports` volume. Set `EXPORTS_VOLUME` in `.env` to
use another volume name. No S3 settings are required.

To use S3-compatible export or backup storage, copy the separate example and
fill only the block you need:

```bash
cp docker-compose/config/storage.env.example \
  "$APP_INSTALL_DIR/docker-compose/.state/storage.env"
chmod 600 "$APP_INSTALL_DIR/docker-compose/.state/storage.env"
```

The supported settings are `EXPORTS_S3_*` and `BACKUP_S3_*`. The local export
volume remains mounted even when the optional file is present.

## 5. Install and wait for readiness

Run:

```bash
./scripts/install-compose.sh \
  --standard \
  --directory "$APP_INSTALL_DIR"
```

The installer validates required files and placeholders, confirms the external
network and standard validator services, pulls the three images, starts the
project, and waits for `http://127.0.0.1:8090/ready`.

Useful local endpoints:

```text
Frontend/BFF:  http://127.0.0.1:8091
Backend API:   http://127.0.0.1:8090
Startup:       http://127.0.0.1:8090/startup-status
Backend docs:  http://127.0.0.1:8090/docs
OpenAPI JSON:  http://127.0.0.1:8090/docs/v1/openapi.json
```

`FRONTEND_BIND_ADDRESS`, `FRONTEND_PORT`, `BACKEND_BIND_ADDRESS`, and
`BACKEND_PORT` control the published host bindings. Keep both addresses on
`127.0.0.1` when a reverse proxy runs directly on the host.

## 6. Add DNS, TLS, and NGINX

Use two public names:

```text
data.example.com      -> frontend/BFF
api.data.example.com  -> backend API and /docs
```

Both A records can point to the validator host.

For NGINX running as a container on the validator network, start with
[`docker-compose/nginx/cda.conf.example`](../docker-compose/nginx/cda.conf.example).
Replace its hostnames and certificate paths, mount the include into the
existing NGINX configuration, then check and reload:

```bash
docker exec <nginx-container> nginx -t
docker exec <nginx-container> nginx -s reload
```

The example resolves the app container names at request time, so NGINX can reload
while the app is stopped. It also forwards the HTTP/1.1 upgrade headers required by
frontend WebSockets.

If NGINX runs directly on the host instead of in Docker, use loopback upstreams:

```text
http://127.0.0.1:8091
http://127.0.0.1:8090
```

Do not set either bind address to `0.0.0.0` unless a firewall or trusted private
network controls direct access.

## 7. Verify

Check local readiness before diagnosing DNS or TLS:

```bash
curl -fsS http://127.0.0.1:8090/health
curl -fsS http://127.0.0.1:8090/ready
curl -fsS http://127.0.0.1:8090/startup-status | jq
curl -fsS http://127.0.0.1:8090/docs/v1/openapi.json | jq '.info'
```

Then check both public hosts:

```bash
curl -fsS https://data.example.com >/dev/null
curl -fsS https://api.data.example.com/ready
curl -fsS https://api.data.example.com/docs/v1/openapi.json | jq '.info'
```

Open `https://data.example.com`, sign in, and confirm the browser returns to
`https://data.example.com/callback`. Check capture separately:

```bash
curl -fsS http://127.0.0.1:8090/api/v2/capture/status | jq
```

The capture status must show the participant-wide indexer running without a
network or token error.

## Operations and upgrades

```bash
cd "$APP_INSTALL_DIR/docker-compose"
docker compose --env-file .env -f compose.yaml ps
docker compose --env-file .env -f compose.yaml logs -f backend
docker compose --env-file .env -f compose.yaml down
```

`down` preserves the named database and export volumes. Never use
`down --volumes` during an upgrade. Preserve `.state/accounting.env` along with
the database.

For encrypted local storage, set `DATABASE_DATA_PATH` to an absolute path on an
encrypted filesystem. See [Encryption at rest](../encryption_at_rest.md).

Performance and stream-delivery controls are listed in `.env.example`. Keep
their defaults for the first installation. Change one group at a time after
observing database CPU, memory, connections, capture lag, and write latency.
The broadest controls are `DATABASE_MAX_PARALLEL_WORKERS_PER_GATHER`,
`READ_MODEL_TOTAL_CAPACITY`, and `BACKGROUND_INDEXING_DUTY_PERCENT`.
See [Streams, alerts, and connectors](streaming.md) for `STREAM_*` and
`ALLOW_PRIVATE_WEBHOOK_TARGETS`.

## Optional guided setup

The localhost wizard detects safe validator and OIDC values but does not create
Keycloak or Auth0 clients:

```bash
curl -fsSL https://raw.githubusercontent.com/Noves-Inc/canton-data-app/v4/install.sh |
  bash -s -- compose
```

If more than one validator is running, add
`--validator-container <container-name>`. The host installer may stream the
selected validator's participant-admin machine configuration into setup
service memory. It never adds that credential to Noves App files or the final
deployment.
