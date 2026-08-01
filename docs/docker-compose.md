# Docker Compose installation

Use these instructions to install the Noves Data App with Docker Compose. The examples attach the app to `splice-validator_splice_validator` and use `participant:5001` and `http://validator:5003`. Set the network, participant address, and scan API URL to match your deployment when those defaults do not apply.

These instructions keep the configuration in local files.

See [Container environment variables](environment-variables.md) for the variables injected into each container and whether they require operator input.

## 1. Check the host

The Noves Data App adds a database, backend, and frontend to the validator host. Check CPU, memory, and disk before starting; initial capture and read-model catch-up add load until the app reaches the ledger end.

Find a Docker network that the app can use to reach the Ledger API and scan API. The default network name is shown here:

```bash
docker network inspect splice-validator_splice_validator >/dev/null
```

If your deployment uses another network, record its name for `CANTON_DOCKER_NETWORK`. The participant and scan API containers do not need specific Compose service names.

The shipped `.env.example` pins `BACKEND_IMAGE=`, `FRONTEND_IMAGE=`, and `DATABASE_IMAGE=` by tag and digest. Use all three references from the same release. If Noves supplied registry credentials for your release, authenticate with the named registry before running the installer.

## 2. Prepare the installation files

From a checkout of this repository:

```bash
export APP_INSTALL_DIR=/opt/noves-canton-data-app
mkdir -p "$APP_INSTALL_DIR/docker-compose/.state/certificates"
cp docker-compose/.env.example "$APP_INSTALL_DIR/docker-compose/.env"
cp docker-compose/config/nodes-config.json \
  "$APP_INSTALL_DIR/docker-compose/.state/nodes-config.json"
```

Edit `.env`:

- replace `APP_URL` with the public frontend URL;
- leave the three image references pinned;
- set `CANTON_DOCKER_NETWORK` if the validator uses a nonstandard network;
- set `CANTON_SCAN_API_URL` only if `http://validator:5003` is not reachable;
- ensure the configured `synchronizer_alias` identifies the participant's Global Synchronizer; and
- configure exactly one browser OIDC provider.

The backend detects mainnet, testnet, or devnet automatically from the exact synchronizer identity. Unknown or conflicting identities keep readiness false instead of guessing.

For embedded mode, set `EMBED_ALLOWED_ORIGINS` to the exact, comma-separated origins allowed to host the iframe. Leave it blank for a standalone deployment. See the [embedded mode guide](../embedded_mode.md).

Leave `REPLACE_WITH_PARTICIPANT_ID` in `.state/nodes-config.json` until step 4, where you read the complete ID from the participant. Set its `addr` to the Ledger API address reachable on `CANTON_DOCKER_NETWORK`.

### Optional Ledger API TLS and mTLS

`cert_file` verifies the participant's server certificate with a private CA. It accepts either one DER certificate or a PEM bundle containing multiple trust anchors; it is not a client certificate. When the Ledger API requires mTLS, copy the unencrypted PEM client identity into the mounted certificate directory:

```bash
cp /secure/path/ca.crt "$APP_INSTALL_DIR/docker-compose/.state/certificates/ca.crt"
cp /secure/path/client.crt "$APP_INSTALL_DIR/docker-compose/.state/certificates/client.crt"
cp /secure/path/client.key "$APP_INSTALL_DIR/docker-compose/.state/certificates/client.key"
chmod 600 "$APP_INSTALL_DIR/docker-compose/.state/certificates/"*
```

Set the primary node fields in `.state/nodes-config.json`:

```json
"cert_file": "/certificates/ca.crt",
"client_cert_file": "/certificates/client.crt",
"client_key_file": "/certificates/client.key",
"tls_server_name": "ledger.example.com"
```

The client certificate and key must be configured together. `client.crt` may contain the leaf followed by intermediate certificates. Omit `cert_file` or leave it empty when the participant certificate uses normal system trust. A client pair or `tls_server_name` still enables TLS; the app never falls back to plaintext after any TLS setting is configured. `tls_server_name` controls SNI and hostname verification when `addr` is an internal service name that is not in the participant certificate SAN.

The installer rejects paths outside `/certificates`, missing files, partial client pairs, and files the non-root backend cannot read. After pulling the backend image, it uses a root one-shot container to set the certificate directory to group `1654` with mode `0750` and configured files to group `1654` with mode `0440`. This gives the backend's non-root user access without making the private key world-readable. It stores only paths in `nodes-config.json`; certificate and key contents remain in `.state/certificates` and are mounted read-only.

Certificates are loaded into long-lived channels at backend startup. To rotate them, first configure the participant to accept both old and new client issuers or identities for the transition. Copy each replacement to a temporary file in `.state/certificates`, then rename all replacements into place before restarting anything. Rerun `install-compose.sh` with the same `--directory` to restore group `1654` and `0440` permissions, then reload the channels:

```bash
cd "$APP_INSTALL_DIR/docker-compose"
docker compose --env-file .env -f compose.yaml restart backend
```

For an unrelated server-CA rollover, create `ca-bundle.pem` with the old root followed by the new root. Point `cert_file` at that bundle, restart the backend, and verify it still reaches the participant using the old certificate. Then switch the participant to its new certificate and verify connectivity. Finally replace the bundle with the new root only and restart the backend again. If a trust-overlap bundle or cross-signed participant certificate is not available, schedule a maintenance window instead. For a client-identity rollover, keep both client identities trusted until the restarted backend is healthy.

## 3. Configure browser login and capture

Create separate browser and capture clients. Do not reuse the validator's client.

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

The capture token's exact `sub` must match a Canton user with only `CanReadAsAnyParty`. The installer treats a missing or incomplete capture file as an error instead of silently starting without capture.

## 4. Read the participant ID and create the capture user

Use your validator's administrator procedure to obtain a short-lived Ledger API administrator token. The example below reads the settings used by Canton's Compose bundle. If your deployment stores them elsewhere, export the same values from your own secret manager. Set `CAPTURE_USER_ID` to the exact `sub` from the capture token check in the Keycloak or Auth0 guide:

```bash
export VALIDATOR_DIR=/path/to/splice-node/docker-compose/validator
export CAPTURE_USER_ID='replace-with-the-exact-capture-token-subject'
export PARTICIPANT_ADDRESS=participant:5001

set -a
. "$VALIDATOR_DIR/.env"
. "$APP_INSTALL_DIR/docker-compose/.env"
set +a

: "${AUTH_WELLKNOWN_URL:?missing from the validator .env}"
: "${VALIDATOR_AUTH_CLIENT_ID:?missing from the validator .env}"
: "${VALIDATOR_AUTH_CLIENT_SECRET:?missing from the validator .env}"
: "${LEDGER_API_AUTH_AUDIENCE:?missing from the validator .env}"
: "${LEDGER_API_AUTH_SCOPE:?missing from the validator .env}"

ADMIN_TOKEN_URL="$(
  curl -fsS "$AUTH_WELLKNOWN_URL" | jq -er '.token_endpoint'
)"
export PARTICIPANT_ADMIN_TOKEN="$(
  curl -fsS --request POST "$ADMIN_TOKEN_URL" \
    --header 'content-type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=client_credentials \
    --data-urlencode client_id="$VALIDATOR_AUTH_CLIENT_ID" \
    --data-urlencode client_secret="$VALIDATOR_AUTH_CLIENT_SECRET" \
    --data-urlencode audience="$LEDGER_API_AUTH_AUDIENCE" \
    --data-urlencode scope="$LEDGER_API_AUTH_SCOPE" |
    jq -er '.access_token'
)"
unset VALIDATOR_AUTH_CLIENT_SECRET
```

The validator's `AUTH_WELLKNOWN_URL` is an OpenID Connect discovery URL. It is not a token endpoint; the command above resolves `token_endpoint` from the discovery document.

Use a pinned `grpcurl` container on the validator network:

```bash
export GRPCURL_IMAGE='fullstorydev/grpcurl:v1.9.3@sha256:085e183ca334eb4e81ca81ee12cbb2b2737505d1d77f5e33dabc5d066593d998'

PARTICIPANT_ID="$(
  docker run --rm \
    --network "$CANTON_DOCKER_NETWORK" \
    --env PARTICIPANT_ADMIN_TOKEN \
    "$GRPCURL_IMAGE" \
    -plaintext -expand-headers \
    -H 'authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}' \
    -d '{}' \
    "$PARTICIPANT_ADDRESS" \
    com.daml.ledger.api.v2.admin.PartyManagementService/GetParticipantId |
    jq -er '.participant_id // .participantId'
)"
printf '%s\n' "$PARTICIPANT_ID"
```

The example uses `-plaintext`. For an mTLS-only Ledger API, add `--volume "$APP_INSTALL_DIR/docker-compose/.state/certificates:/certificates:ro"` to each `docker run` command and replace `-plaintext` with `-cacert /certificates/ca.crt -cert /certificates/client.crt -key /certificates/client.key -authority ledger.example.com` for the participant-ID and user-management calls.

`grpcurl` currently prints the field as `participant_id`; the fallback also accepts camel case. Put the printed value in `.state/nodes-config.json` as `expectedParticipantId`.

Create the Canton user with the capture token's exact subject:

```bash
docker run --rm \
  --network "$CANTON_DOCKER_NETWORK" \
  --env PARTICIPANT_ADMIN_TOKEN \
  "$GRPCURL_IMAGE" \
  -plaintext -expand-headers \
  -H 'authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}' \
  -d "{\"user\":{\"id\":\"${CAPTURE_USER_ID}\"},\"rights\":[{\"canReadAsAnyParty\":{}}]}" \
  "$PARTICIPANT_ADDRESS" \
  com.daml.ledger.api.v2.admin.UserManagementService/CreateUser
```

If `CreateUser` reports that the user already exists, inspect its rights before changing anything:

```bash
docker run --rm \
  --network "$CANTON_DOCKER_NETWORK" \
  --env PARTICIPANT_ADMIN_TOKEN \
  "$GRPCURL_IMAGE" \
  -plaintext -expand-headers \
  -H 'authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}' \
  -d "{\"userId\":\"${CAPTURE_USER_ID}\"}" \
  "$PARTICIPANT_ADDRESS" \
  com.daml.ledger.api.v2.admin.UserManagementService/ListUserRights

unset PARTICIPANT_ADMIN_TOKEN PARTICIPANT_ADDRESS VALIDATOR_AUTH_CLIENT_ID \
  AUTH_WELLKNOWN_URL ADMIN_TOKEN_URL LEDGER_API_AUTH_AUDIENCE \
  LEDGER_API_AUTH_SCOPE
```

The final rights response must contain only `can_read_as_any_party`. Do not place the validator administrator client or token in Noves Data App files.

## 5. Create local secrets

`install-compose.sh` generates the database password when `.env` still contains the example placeholder. It also creates `.state/accounting.env` with a random 32-byte `ACCOUNTING_TOKEN_ENCRYPTION_KEY`. The file is reused on every installer run. Back it up with the database: replacing it makes stored accounting-provider credentials unreadable.

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
  "$APP_INSTALL_DIR/docker-compose/.state/capture.env"
chmod 644 "$APP_INSTALL_DIR/docker-compose/.state/nodes-config.json"
```

The installer applies mode `0600` to the generated accounting file. The node configuration contains certificate paths but no credential contents; mode `0644` lets the non-root backend read its bind mount. Keep the private key in `.state/certificates` group-readable only as needed by the container user.

### Optional S3 storage

The default deployment writes exports to the named `noves-canton-data-app-v4-exports` volume. Set `EXPORTS_VOLUME` in `.env` to use another volume name. No S3 settings are required.

To use S3 export or backup storage, copy the separate example and fill only the block you need:

```bash
cp docker-compose/config/storage.env.example \
  "$APP_INSTALL_DIR/docker-compose/.state/storage.env"
chmod 600 "$APP_INSTALL_DIR/docker-compose/.state/storage.env"
```

The supported settings are `EXPORTS_S3_*` and `BACKUP_S3_*`. The local export volume remains mounted even when the optional file is present.

## 6. Install and wait for readiness

Run:

```bash
./scripts/install-compose.sh --directory "$APP_INSTALL_DIR"
```

The installer validates required files and placeholders, confirms the external network, pulls the three images, starts the project, and waits for `http://127.0.0.1:8090/ready`.

Useful local endpoints:

```text
Frontend/BFF:  http://127.0.0.1:8091
Backend API:   http://127.0.0.1:8090
Startup:       http://127.0.0.1:8090/startupStatus
Backend docs:  http://127.0.0.1:8090/docs
OpenAPI JSON:  http://127.0.0.1:8090/docs/v1/openapi.json
```

`FRONTEND_BIND_ADDRESS`, `FRONTEND_PORT`, `BACKEND_BIND_ADDRESS`, and `BACKEND_PORT` control the published host bindings. Keep both addresses on `127.0.0.1` when a reverse proxy runs directly on the host.

## 7. Add DNS, TLS, and NGINX

Use two public names:

```text
data.example.com      -> frontend/BFF
api.data.example.com  -> backend API and /docs
```

Both A records can point to the validator host.

For NGINX running as a container on the validator network, start with [`docker-compose/nginx/noves-canton-data-app.conf.example`](../docker-compose/nginx/noves-canton-data-app.conf.example). Replace its hostnames and certificate paths and mount the include into the existing NGINX configuration.

If you added a mount or changed the bind-mounted `nginx.conf`, recreate only the validator's NGINX service with the same Compose files used for the validator deployment:

```bash
cd "$VALIDATOR_DIR"
docker compose -f compose.yaml -f compose-traffic-topups.yaml \
  up -d --no-deps --force-recreate nginx
docker exec <nginx-container> nginx -t
```

Use the same `-f` arguments as your validator deployment if it uses different override files.

A reload is enough after editing an include that was already mounted:

```bash
docker exec <nginx-container> nginx -t
docker exec <nginx-container> nginx -s reload
```

Some editors, including `sed -i`, replace a file instead of updating its existing inode. A running container keeps the old bind-mounted inode until the service is recreated.

The example resolves the app container names at request time, so NGINX can reload while the app is stopped. It also forwards the HTTP/1.1 upgrade headers required by frontend WebSockets.

If NGINX runs directly on the host instead of in Docker, use loopback upstreams:

```text
http://127.0.0.1:8091
http://127.0.0.1:8090
```

Do not set either bind address to `0.0.0.0` unless a firewall or trusted private network controls direct access.

## 8. Verify

Check local readiness before diagnosing DNS or TLS:

```bash
curl -fsS http://127.0.0.1:8090/health
curl -fsS http://127.0.0.1:8090/ready
curl -fsS http://127.0.0.1:8090/startupStatus | jq
curl -fsS http://127.0.0.1:8090/docs/v1/openapi.json | jq '.info'
```

Then check both public hosts:

```bash
curl -fsS https://data.example.com >/dev/null
curl -fsS https://api.data.example.com/ready
curl -fsS https://api.data.example.com/docs/v1/openapi.json | jq '.info'
```

Open `https://data.example.com`, sign in, and confirm the browser returns to `https://data.example.com/callback`. Check capture separately:

```bash
curl -fsS http://127.0.0.1:8090/api/v2/capture/status | jq
```

The capture status must show the indexer running across the participant without a network or token error.

## Operations and upgrades

```bash
cd "$APP_INSTALL_DIR/docker-compose"
docker compose --env-file .env -f compose.yaml ps
docker compose --env-file .env -f compose.yaml logs -f backend
docker compose --env-file .env -f compose.yaml down
```

`down` preserves the named database and export volumes. Never use `down --volumes` during an upgrade. Preserve `.state/accounting.env` along with the database.

For encrypted local storage, set `DATABASE_DATA_PATH` to an absolute path on an encrypted filesystem. See [Encryption at rest](../encryption_at_rest.md).

Set `ALLOW_PRIVATE_WEBHOOK_TARGETS=true` only when an alert or connector must deliver to a receiver on a private network. The default blocks those targets. Traffic cost analysis and stream processing run in the backend without extra services. The database, read-model, and stream-delivery settings in `.env.example` are optional tuning controls; keep their defaults until measurements justify a change.
