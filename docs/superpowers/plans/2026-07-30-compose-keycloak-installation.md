# Docker Compose Keycloak Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a fresh v4 Docker Compose installation work beside Canton's standard validator Compose deployment, with private digest-pinned images, Keycloak browser and capture clients, durable local volumes, and a tested NGINX proxy.

**Architecture:** Keep the Noves App's three services on the validator's existing external Docker network. Split service image references and secret-bearing environment files by responsibility, add fail-fast Compose and installer checks, and provide a focused NGINX include for the existing proxy. Rehearse the result on `canton-testnet` with `CANTON_NETWORK=testnet`; automatic network detection remains deferred.

**Tech Stack:** Docker Compose v2+, Bash, NGINX 1.27, Keycloak 26, .NET 9 health and OpenAPI endpoints, Markdown operator documentation.

## Global Constraints

- Work only on the local `v4` branch and stage exact paths.
- Do not modify or discard the existing uncommitted Helm image updates.
- Do not push.
- Use the three current prerelease image references with tags and digests.
- Keep named database and export volumes as the working default.
- Generate `ACCOUNTING_TOKEN_ENCRYPTION_KEY` once and never rotate it during reinstall or upgrade.
- Require the capture environment file; keep the optional S3 environment file optional.
- Use `participant:5001` and `http://validator:5003` on the standard Compose network.
- Set `CANTON_NETWORK=testnet` for the live rehearsal.
- Do not reuse the validator's OIDC client for the Noves App.
- Do not persist the validator participant-admin credential in Noves App files.
- Do not delete validator, Keycloak, or unrelated Docker resources.
- Do not log registry passwords, Keycloak client secrets, M2M tokens, or participant-admin credentials.

---

### Task 1: Correct the Compose runtime contract

**Files:**
- Modify: `tests/docker-compose.sh`
- Modify: `docker-compose/compose.yaml`
- Modify: `docker-compose/compose.setup.yaml`
- Modify: `docker-compose/.env.example`
- Create: `docker-compose/config/storage.env.example`

**Interfaces:**
- Consumes: `BACKEND_IMAGE`, `FRONTEND_IMAGE`, `DATABASE_IMAGE`, `CANTON_DOCKER_NETWORK`, `CANTON_VALIDATOR_URL`, and the files under `.state`.
- Produces: a rendered application manifest that fails when capture, accounting, or node configuration is absent and starts without S3 settings when storage configuration is absent.

- [ ] **Step 1: Add failing image and validator-service tests**

Replace the shared-image assertions in `tests/docker-compose.sh` with:

```bash
assert_contains "$scratch/standard.yaml" \
  'image: noves.azurecr.io/cda-backend:prod-3e1a1fde-1785439104@sha256:37cad1fe33871bf08ba1be9699c11e87c643931e51d295c9de7bfed8afe1c793'
assert_contains "$scratch/standard.yaml" \
  'image: noves.azurecr.io/cda-frontend:prod-c78cdd33-1785419965@sha256:3205d0193e1b493098f9d1704604206f173fb456aa6fb6dbcc8b8529f70266b1'
assert_contains "$scratch/standard.yaml" \
  'image: ghcr.io/noves-inc/noves-canton-database-v4:candidate-30160846627-1@sha256:1482f1bbe6ca9039ebe4bdcdf7442d34acf9389b2799215b95e10ee8d01ba49b'
assert_contains "$scratch/standard.yaml" 'SCAN_PROXY_URL: http://validator:5003'
assert_contains "$compose_dir/.env.example" 'CANTON_VALIDATOR_URL=http://validator:5003'
assert_not_contains "$compose_dir/.env.example" 'IMAGE_VERSION='
```

Render an override and assert that it replaces only the selected service:

```bash
BACKEND_IMAGE=registry.example/cda/backend:v4@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
docker compose --env-file "$compose_dir/.env.example" \
  -f "$compose_dir/compose.yaml" config >"$scratch/image-override.yaml"
assert_contains "$scratch/image-override.yaml" \
  'image: registry.example/cda/backend:v4@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
```

- [ ] **Step 2: Add failing state-file and storage tests**

Assert that the rendered backend contains:

```bash
assert_contains "$scratch/standard.yaml" 'path: /config/nodes-config.json'
assert_contains "$scratch/standard.yaml" 'create_host_path: false'
assert_contains "$scratch/standard.yaml" 'path: ./.state/capture.env'
assert_contains "$scratch/standard.yaml" 'required: true'
assert_contains "$scratch/standard.yaml" 'path: ./.state/accounting.env'
assert_contains "$scratch/standard.yaml" 'path: ./.state/storage.env'
assert_contains "$scratch/standard.yaml" 'required: false'
assert_contains "$compose_dir/config/storage.env.example" 'EXPORTS_S3_BUCKET='
assert_contains "$compose_dir/config/storage.env.example" 'BACKUP_S3_BUCKET='
```

Create temporary `.state` files before rendering so required Compose
`env_file` validation can succeed:

```bash
mkdir -p "$compose_dir/.state"
touch "$compose_dir/.state/capture.env" "$compose_dir/.state/accounting.env"
cleanup_state_files() {
  rm -f "$compose_dir/.state/capture.env" "$compose_dir/.state/accounting.env"
}
trap 'cleanup_state_files; rm -rf "$scratch"' EXIT
```

- [ ] **Step 3: Run the focused test and confirm failure**

Run:

```bash
tests/docker-compose.sh
```

Expected: FAIL on the unpublished shared image contract or
`validator-app:5003`.

- [ ] **Step 4: Implement per-service image references**

Use these image fields in `compose.yaml` and `compose.setup.yaml`:

```yaml
image: ${DATABASE_IMAGE:-ghcr.io/noves-inc/noves-canton-database-v4:candidate-30160846627-1@sha256:1482f1bbe6ca9039ebe4bdcdf7442d34acf9389b2799215b95e10ee8d01ba49b}
image: ${BACKEND_IMAGE:-noves.azurecr.io/cda-backend:prod-3e1a1fde-1785439104@sha256:37cad1fe33871bf08ba1be9699c11e87c643931e51d295c9de7bfed8afe1c793}
image: ${FRONTEND_IMAGE:-noves.azurecr.io/cda-frontend:prod-c78cdd33-1785419965@sha256:3205d0193e1b493098f9d1704604206f173fb456aa6fb6dbcc8b8529f70266b1}
```

Add the same complete values to `.env.example` and remove `IMAGE_VERSION`.

- [ ] **Step 5: Correct Canton defaults and browser placeholders**

Change both `SCAN_PROXY_URL` fallbacks and `.env.example` to
`http://validator:5003`. Keep `CANTON_NETWORK=mainnet` for this release, with a
comment that testnet and devnet operators must change it.

Make all Auth0 and Keycloak example values blank:

```dotenv
VITE_AUTH0_DOMAIN=
VITE_AUTH0_CLIENT_ID=
VITE_AUTH0_AUDIENCE=
VITE_KEYCLOAK_URL=
VITE_KEYCLOAK_REALM=
VITE_KEYCLOAK_CLIENT_ID=
```

- [ ] **Step 6: Make local configuration fail fast**

Use these backend environment files:

```yaml
env_file:
  - path: ./.state/capture.env
    required: true
  - path: ./.state/accounting.env
    required: true
  - path: ./.state/storage.env
    required: false
```

Replace the nodes-config short mount with:

```yaml
- type: bind
  source: ./.state/nodes-config.json
  target: /config/nodes-config.json
  read_only: true
  bind:
    create_host_path: false
```

- [ ] **Step 7: Add the optional S3 environment example**

Create `docker-compose/config/storage.env.example` containing every backend
storage variable with an empty value:

```dotenv
EXPORTS_S3_BUCKET=
EXPORTS_S3_ENDPOINT_URL=
EXPORTS_S3_ACCESS_KEY_ID=
EXPORTS_S3_SECRET_ACCESS_KEY=
EXPORTS_S3_SESSION_TOKEN=
EXPORTS_S3_REGION=
BACKUP_S3_BUCKET=
BACKUP_S3_ENDPOINT_URL=
BACKUP_S3_ACCESS_KEY_ID=
BACKUP_S3_SECRET_ACCESS_KEY=
BACKUP_S3_SESSION_TOKEN=
BACKUP_S3_REGION=
```

- [ ] **Step 8: Run the focused test**

Run:

```bash
tests/docker-compose.sh
```

Expected: `docker compose tests passed`.

- [ ] **Step 9: Commit the runtime contract**

```bash
git add docker-compose/compose.yaml \
  docker-compose/compose.setup.yaml \
  docker-compose/.env.example \
  docker-compose/config/storage.env.example \
  tests/docker-compose.sh
git commit -m "fix: make Compose v4 installable"
```

---

### Task 2: Generate stable secrets and add installer preflight

**Files:**
- Modify: `tests/installers.sh`
- Modify: `scripts/install-compose.sh`
- Modify: `install.sh`

**Interfaces:**
- Consumes: the corrected Compose files from Task 1 and the current Docker credentials.
- Produces: `.state/accounting.env` with one stable key, validated standard-install files, an image pull, and a readiness wait.

- [ ] **Step 1: Add failing accounting-key tests**

Extend the standard Compose installer fixture to remove any pre-created
accounting file. After one installer run, assert:

```bash
accounting_file="$compose_install/docker-compose/.state/accounting.env"
[[ -f "$accounting_file" ]] ||
  fail 'Compose installer did not create accounting.env'
grep -Eq '^ACCOUNTING_TOKEN_ENCRYPTION_KEY=[A-Za-z0-9+/]{43}=$' "$accounting_file" ||
  fail 'Compose installer did not write a 32-byte base64 accounting key'
[[ "$(stat -f '%Lp' "$accounting_file" 2>/dev/null || stat -c '%a' "$accounting_file")" == 600 ]] ||
  fail 'accounting.env is not mode 0600'
```

Save its checksum, run the installer again, and assert that the checksum is
unchanged.

- [ ] **Step 2: Extend the fake Docker and curl commands**

Teach the fake Docker command to record and succeed for:

```text
network inspect splice-validator_splice_validator
compose --env-file .env -f compose.yaml config
compose --env-file .env -f compose.yaml pull
compose --env-file .env -f compose.yaml up -d
```

Teach the fake curl command to return success for
`http://127.0.0.1:8090/ready`. Assert that standard mode invoked config, pull,
up, and readiness in that order.

- [ ] **Step 3: Add failing validation cases**

Add isolated standard-install invocations that must fail for:

- a missing `.state/nodes-config.json`;
- `replace-with-a-long-random-password` in `.env`;
- a capture file missing `M2M_CLIENT_SECRET`;
- a missing external Docker network; and
- an image pull failure.

Each assertion checks that the error names the exact file, setting, network, or
pull operation.

- [ ] **Step 4: Run installer tests and confirm failure**

Run:

```bash
tests/installers.sh
```

Expected: FAIL because standard mode neither generates the accounting key nor
performs the new preflight.

- [ ] **Step 5: Generate or reuse the accounting key**

Move the `openssl` requirement before the standard/guided branch. Add:

```bash
accounting_env_file=".state/accounting.env"
if [[ ! -f "$accounting_env_file" ]]; then
  umask 077
  printf 'ACCOUNTING_TOKEN_ENCRYPTION_KEY=%s\n' \
    "$(openssl rand -base64 32 | tr -d '\n')" >"$accounting_env_file"
fi
chmod 600 "$accounting_env_file"
```

Reject a blank, malformed, or duplicate key without replacing it.

- [ ] **Step 6: Validate standard configuration**

Before contacting Docker, require `.env`, nodes config, capture credentials,
the accounting key, and the gateway credential. Reject literal
`replace-with-` placeholders.

Validate these capture keys without printing values:

```bash
for key in M2M_TOKEN_ENDPOINT M2M_CLIENT_ID M2M_CLIENT_SECRET M2M_AUDIENCE; do
  grep -Eq "^${key}=(\"[^\"]+\"|[^[:space:]].*)$" .state/capture.env ||
    die ".state/capture.env is missing a non-blank $key."
done
```

Run `docker compose ... config --quiet` to validate the assembled manifest.

- [ ] **Step 7: Validate network and image access**

Require:

```bash
docker network inspect "$canton_docker_network" >/dev/null 2>&1 ||
  die "Docker network '$canton_docker_network' does not exist."
```

Use `docker ps` labels plus `docker inspect` to confirm one running
`participant` and one running `validator` service attached to that network.
Then run:

```bash
docker compose --env-file .env -f compose.yaml pull ||
  die "Could not pull the Noves App images. Log in to the configured registries and retry."
```

- [ ] **Step 8: Start and wait for backend readiness**

Replace the `exec ... up -d` branch with:

```bash
docker compose --env-file .env -f compose.yaml up -d
backend_port="$(sed -n 's/^BACKEND_PORT=//p' .env | tail -1)"
backend_port="${backend_port:-8090}"
backend_origin="http://127.0.0.1:$backend_port"
wait_for_backend_ready "$backend_origin" ||
  die "The Noves App did not become ready. Run: docker compose --env-file .env -f compose.yaml logs backend"
printf 'Installation complete. Backend status: %s/startup-status\n' "$backend_origin"
```

Implement `wait_for_backend_ready` with a bounded loop of 120 five-second
attempts against `/ready`. On failure, request `/startup-status` once for
operator-visible diagnostics.

- [ ] **Step 9: Download the storage example**

Update both installer copy loops so remote installation includes
`config/storage.env.example`.

- [ ] **Step 10: Run installer tests**

Run:

```bash
tests/installers.sh
```

Expected: `installer tests passed`.

- [ ] **Step 11: Commit the installer**

```bash
git add scripts/install-compose.sh install.sh tests/installers.sh
git commit -m "fix: preflight Compose installations"
```

---

### Task 3: Ship and test the NGINX proxy example

**Files:**
- Create: `docker-compose/nginx/cda.conf.example`
- Create: `tests/compose-nginx.sh`
- Modify: `tests/all.sh`

**Interfaces:**
- Consumes: the stable Noves App container names and the shared validator Docker network.
- Produces: two TLS virtual hosts with restart-safe Docker DNS resolution and frontend WebSocket forwarding.

- [ ] **Step 1: Write the failing proxy contract test**

Create `tests/compose-nginx.sh` with assertions for:

```bash
assert_contains "$config" 'server_name data.example.com;'
assert_contains "$config" 'server_name api.data.example.com;'
assert_contains "$config" 'resolver 127.0.0.11'
assert_contains "$config" 'noves-canton-frontend-v4:3000'
assert_contains "$config" 'noves-canton-backend-v4:8090'
assert_contains "$config" 'proxy_http_version 1.1;'
assert_contains "$config" 'proxy_set_header Upgrade $http_upgrade;'
assert_contains "$config" 'proxy_set_header Connection "upgrade";'
assert_contains "$config" 'proxy_set_header X-Forwarded-Proto $scheme;'
```

Generate a temporary self-signed certificate, wrap the include in an NGINX
`http` block, and run:

```bash
docker run --rm \
  -v "$scratch/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$scratch/cert.pem:/etc/nginx/cert.pem:ro" \
  -v "$scratch/key.pem:/etc/nginx/key.pem:ro" \
  nginx:1.27-alpine nginx -t
```

- [ ] **Step 2: Run the proxy test and confirm failure**

Run:

```bash
tests/compose-nginx.sh
```

Expected: FAIL because the example does not exist.

- [ ] **Step 3: Add the focused NGINX include**

Create two `server` blocks on port 443. Use variables so upstream names resolve
at request time:

```nginx
resolver 127.0.0.11 valid=30s ipv6=off;
set $cda_frontend noves-canton-frontend-v4:3000;
proxy_pass http://$cda_frontend;
```

and:

```nginx
resolver 127.0.0.11 valid=30s ipv6=off;
set $cda_backend noves-canton-backend-v4:8090;
proxy_pass http://$cda_backend;
```

Both hosts set `Host`, `X-Forwarded-Host`, `X-Forwarded-For`, and
`X-Forwarded-Proto`. The frontend host also sets the HTTP/1.1 WebSocket
headers.

- [ ] **Step 4: Add the proxy test to the full gate**

Add:

```bash
"$repo_root/tests/compose-nginx.sh"
```

after `tests/docker-compose.sh` in `tests/all.sh`.

- [ ] **Step 5: Run the proxy test**

Run:

```bash
tests/compose-nginx.sh
```

Expected: NGINX reports `syntax is ok` and
`compose NGINX tests passed`.

- [ ] **Step 6: Commit the proxy example**

```bash
git add docker-compose/nginx/cda.conf.example tests/compose-nginx.sh tests/all.sh
git commit -m "docs: add Compose NGINX proxy example"
```

---

### Task 4: Rewrite the standard Compose and Keycloak path

**Files:**
- Modify: `tests/docs.sh`
- Modify: `docs/docker-compose.md`
- Modify: `docs/authentication/keycloak.md`
- Modify: `docs/security.md`
- Modify: `docs/upgrades.md`
- Modify: `readme.md`

**Interfaces:**
- Consumes: the manifest, installer, and NGINX contracts from Tasks 1–3.
- Produces: one complete standard-install sequence and exact Keycloak operator instructions.

- [ ] **Step 1: Add failing documentation assertions**

Add assertions for:

```bash
assert_contains docs/docker-compose.md 'http://validator:5003'
assert_contains docs/docker-compose.md 'CANTON_NETWORK=testnet'
assert_contains docs/docker-compose.md 'BACKEND_IMAGE='
assert_contains docs/docker-compose.md '.state/accounting.env'
assert_contains docs/docker-compose.md 'storage.env.example'
assert_contains docs/docker-compose.md 'docker-compose/nginx/cda.conf.example'
assert_contains docs/docker-compose.md 'api.data.example.com/docs'
assert_contains docs/authentication/keycloak.md 'VITE_KEYCLOAK_URL='
assert_contains docs/authentication/keycloak.md 'noves-canton-data-app-capture'
assert_not_contains docs/docker-compose.md 'validator-app:5003'
```

- [ ] **Step 2: Run docs tests and confirm failure**

Run:

```bash
tests/docs.sh
```

Expected: FAIL on the corrected validator URL or missing exact Compose
Keycloak block.

- [ ] **Step 3: Rewrite the standard installation sequence**

Make `docs/docker-compose.md` follow the eight steps in the approved design.
Include exact preflight commands:

```bash
docker network inspect splice-validator_splice_validator >/dev/null
docker ps --filter label=com.docker.compose.service=participant
docker ps --filter label=com.docker.compose.service=validator
docker login noves.azurecr.io
docker login ghcr.io
```

Use `scripts/install-compose.sh --standard` as the normal start command.
Retain direct `docker compose` commands under operations and troubleshooting.

- [ ] **Step 4: Document secrets and optional storage**

Give exact commands for manual accounting-key creation:

```bash
umask 077
printf 'ACCOUNTING_TOKEN_ENCRYPTION_KEY=%s\n' \
  "$(openssl rand -base64 32 | tr -d '\n')" \
  > docker-compose/.state/accounting.env
chmod 600 docker-compose/.state/accounting.env
```

Explain that installer reruns preserve the file and that losing it makes
stored accounting-provider credentials unreadable.

Show copying `config/storage.env.example` only when S3 is used. State directly
that the default `/exports` named volume needs no S3 configuration.

- [ ] **Step 5: Make the Keycloak Compose mapping explicit**

Add this browser block to `docs/authentication/keycloak.md`:

```dotenv
APP_URL=https://data.example.com
VITE_AUTH0_DOMAIN=
VITE_AUTH0_CLIENT_ID=
VITE_AUTH0_AUDIENCE=
VITE_KEYCLOAK_URL=https://keycloak.example.com
VITE_KEYCLOAK_REALM=canton
VITE_KEYCLOAK_CLIENT_ID=noves-canton-data-app-browser
```

Add this capture block:

```dotenv
M2M_INDEXER_ENABLED=true
M2M_TOKEN_ENDPOINT=https://keycloak.example.com/realms/canton/protocol/openid-connect/token
M2M_CLIENT_ID=noves-canton-data-app-capture
M2M_CLIENT_SECRET=<generated-client-secret>
M2M_AUDIENCE=https://canton.network.global
M2M_SCOPE=daml_ledger_api
```

Keep the exact token-subject inspection and Canton-user rights steps. Remove
repeated warnings after each client section.

- [ ] **Step 6: Document NGINX and verification**

Link the shipped include, explain container-NGINX versus host-NGINX upstreams,
and require both DNS names. Verification uses:

```bash
curl -fsS https://api.data.example.com/health
curl -fsS https://api.data.example.com/ready
curl -fsS https://api.data.example.com/docs/v1/openapi.json | jq '.info'
curl -fsS http://127.0.0.1:8090/startup-status | jq
```

Include one WebSocket upgrade check through the frontend hostname.

- [ ] **Step 7: Align README, security, and upgrade guidance**

Replace `validator-app:5003` only in Compose contexts; keep the Helm service
name unchanged. Update the README file-preparation commands to protect
nodes-config and accounting files. State that upgrades preserve the accounting
file and named volumes.

- [ ] **Step 8: Run prose and docs checks**

Run:

```bash
tests/docs.sh
rg -n 'validator-app:5003' docs/docker-compose.md docker-compose readme.md
git diff --check
```

Expected: docs tests pass; the search finds no Compose reference to
`validator-app:5003`; diff check prints nothing.

- [ ] **Step 9: Commit the documentation**

```bash
git add tests/docs.sh docs/docker-compose.md \
  docs/authentication/keycloak.md docs/security.md docs/upgrades.md readme.md
git commit -m "docs: make Compose Keycloak setup reproducible"
```

---

### Task 5: Verify the repository and rehearse on canton-testnet

**Files:**
- Verify only: all files changed by Tasks 1–4
- Remote installation directory: `/root/noves-canton-data-app-v4/docker-compose`
- Remote NGINX include: `/root/splice-node/apps/nginx/cda-services.conf`

**Interfaces:**
- Consumes: committed local v4 files, existing registry credentials, operator-created Keycloak clients, and the approved participant-admin operation.
- Produces: a fresh running Noves App installation and a list of any remaining defects.

- [ ] **Step 1: Run the complete local gate**

Run:

```bash
tests/all.sh
git diff --check
git status --short
```

Expected: every test script passes; only the known prior Helm image updates
remain uncommitted.

- [ ] **Step 2: Copy the tested package without secrets**

Create `/root/noves-canton-data-app-v4` on `canton-testnet` and copy the exact
files from the verified local commit. Do not copy local credential files.
Record the commit ID in a mode-0644 `SOURCE_COMMIT` file.

- [ ] **Step 3: Authenticate private registries without printing credentials**

Copy the previously approved registry credentials through stdin to
`docker login` on the remote host. Pull all three digest-pinned images and
verify their RepoDigests with `docker image inspect`.

- [ ] **Step 4: Prepare a fresh installation**

Create new named volumes:

```text
noves-canton-data-app-v4-testnet-data
noves-canton-data-app-v4-testnet-exports
```

Create `.env`, `.state/nodes-config.json`, `.state/capture.env`,
`.state/accounting.env`, and the gateway secret with mode 0600. Set:

```dotenv
APP_URL=https://cda-testnet.noves.fi
CANTON_NETWORK=testnet
CANTON_VALIDATOR_URL=http://validator:5003
DATABASE_VOLUME=noves-canton-data-app-v4-testnet-data
EXPORTS_VOLUME=noves-canton-data-app-v4-testnet-exports
VITE_KEYCLOAK_URL=https://keycloak.testnet.noves.fi
VITE_KEYCLOAK_REALM=canton-testnet
VITE_KEYCLOAK_CLIENT_ID=noves-canton-data-app-browser
```

- [ ] **Step 5: Ask the operator to configure Keycloak**

Send the operator the direct local documentation link and the exact live
values from the approved design. Wait for the browser and capture client IDs
and capture secret to be created. Do not request or use a Keycloak administrator
password.

- [ ] **Step 6: Create and verify the Canton capture user**

After explicit approval, use the validator's existing participant-admin
machine credential transiently to:

1. exchange it for an admin token in memory;
2. create the exact capture-token `sub` as a Canton user when absent;
3. grant only `CanReadAsAnyParty`;
4. list and verify the final rights; and
5. unset the token and credential variables.

- [ ] **Step 7: Install the proxy configuration safely**

Copy the rendered NGINX include, using:

```text
cda-testnet.noves.fi
api-cda-testnet.noves.fi
```

Run `nginx -t` inside the existing NGINX container before reloading. Preserve
the current configuration and restore it if the syntax check fails.

- [ ] **Step 8: Run the standard installer**

Run:

```bash
./scripts/install-compose.sh \
  --standard \
  --directory /root/noves-canton-data-app-v4
```

Wait for backend readiness. Inspect container status, startup status, and logs
without exposing secret environment variables.

- [ ] **Step 9: Verify the complete installation**

Verify:

```bash
curl -fsS http://127.0.0.1:8090/health
curl -fsS http://127.0.0.1:8090/ready
curl -fsS http://127.0.0.1:8090/docs/v1/openapi.json | jq '.info'
curl -fsS https://api-cda-testnet.noves.fi/docs/v1/openapi.json | jq '.info'
curl -fsS https://cda-testnet.noves.fi
```

Confirm browser Keycloak configuration, M2M token refresh, exact rights,
capture progress, frontend WebSocket upgrade, and volume persistence after
`docker compose down` followed by `up -d`.

- [ ] **Step 10: Fix and retest any rehearsal defect**

For each new defect, add a focused local regression test first, confirm it
fails, make the minimal manifest or documentation change, rerun the focused
test, copy the corrected files, and repeat the remote verification.

- [ ] **Step 11: Final verification report**

Report:

- application and backend URLs;
- required DNS records and their resolved host address;
- exact local commits, with unpushed status;
- image tags and digests;
- container, readiness, OpenAPI, Keycloak, M2M, capture, WebSocket, and restart
  results;
- remaining limitations, including explicit `CANTON_NETWORK=testnet`; and
- any operator action still required.
