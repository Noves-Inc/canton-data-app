# Docker Compose installation

The Compose bundle assumes the standard validator network
`splice-validator_splice_validator`. The participant is reached at `participant:5001`, and the
optional validator API at `http://validator-app:5003`.

## Guided localhost setup

```bash
curl -fsSL https://raw.githubusercontent.com/Noves-Inc/canton-data-app/v4/install.sh | bash -s -- compose
```

The installer creates `noves-canton-data-app-v4/docker-compose`, generates local credentials,
opens `http://127.0.0.1:8099`, and waits for the wizard. When verification succeeds, it starts
the normal three-container deployment.

The installer looks for exactly one running container labelled
`com.docker.compose.service=validator`, reads its existing participant-admin machine
configuration, and streams the filtered values directly into setup-service memory. It does not
run shell commands inside the wizard, mount the Docker socket, add the values to `.env`, or retain
them in the final deployment. If more than one validator is running, select it explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/Noves-Inc/canton-data-app/v4/install.sh |
  bash -s -- compose --validator-container my-validator-container
```

Discovery failure is non-fatal: the wizard opens and shows manual
`grpcurl -expand-headers` participant commands. Operators still create the separate Auth0 or
Keycloak browser and capture clients themselves.

## Standard setup

Prepare the files:

```bash
cp docker-compose/.env.example docker-compose/.env
mkdir -p docker-compose/.state
mkdir -p docker-compose/.secrets
cp docker-compose/config/nodes-config.json docker-compose/.state/nodes-config.json
```

Edit `.env` for the public application URL and one OIDC provider. The backend uses
`NOVES_PUBLIC_API_URL`, which defaults to `https://api.canton.noves.fi`; set it only when your
deployment uses a different Noves public API endpoint. The endpoint must use HTTPS. Plain HTTP is
accepted only for loopback addresses used during local testing. Edit `.state/nodes-config.json` with the
exact participant ID.

Create `.state/capture.env`:

```dotenv
M2M_INDEXER_ENABLED=true
M2M_TOKEN_ENDPOINT=https://issuer.example.com/oauth/token
M2M_CLIENT_ID=replace-me
M2M_CLIENT_SECRET=replace-me
M2M_AUDIENCE=https://canton.network.global
M2M_SCOPE=
```

Write the installation-specific Noves gateway credential without putting it in `.env`:

```bash
umask 077
printf '%s\n' 'replace-with-this-installation-credential' \
  > docker-compose/.secrets/noves-gateway-auth-token
chmod 600 docker-compose/.secrets/noves-gateway-auth-token
```

Protect the files and start:

```bash
chmod 600 docker-compose/.env \
  docker-compose/.state/capture.env \
  docker-compose/.state/nodes-config.json \
  docker-compose/.secrets/noves-gateway-auth-token
docker compose --env-file docker-compose/.env \
  -f docker-compose/compose.yaml up -d
```

The containers are named `noves-canton-backend-v4`, `noves-canton-frontend-v4`, and
`noves-canton-database-v4`. Both application containers bind to localhost by default:

```text
Frontend/BFF:  http://127.0.0.1:8091
Backend API:   http://127.0.0.1:8090
Backend docs:  http://127.0.0.1:8090/docs
OpenAPI JSON:  http://127.0.0.1:8090/docs/v1/openapi.json
```

`FRONTEND_BIND_ADDRESS` and `BACKEND_BIND_ADDRESS` control the host interfaces.
`FRONTEND_PORT` and `BACKEND_PORT` control the published ports.

## TLS reverse proxy

Use two public hostnames and send them to the two loopback ports:

```text
https://data.example.com      -> http://127.0.0.1:8091
https://api.data.example.com  -> http://127.0.0.1:8090
```

Create DNS records for both names, configure TLS in your existing reverse proxy, and keep the
container ports on loopback. The public Swagger URL is
`https://api.data.example.com/docs`.

Setting `BACKEND_BIND_ADDRESS=0.0.0.0` publishes the complete API on every host interface. Use
that setting only when a firewall or trusted private network controls access.

## Versions

`IMAGE_VERSION=4.0.0` pins all three images. `IMAGE_VERSION=latest` opts into the newest release in
the v4-only repositories. It cannot select a future v5 image.

## Performance tuning

The final section of `.env.example` keeps all supported database and read-model controls
available. The most common are:

- `INDEX_DB_WRITE_BATCH_SIZE`: write batch size, capped at 250;
- `DATABASE_MAX_PARALLEL_WORKERS_PER_GATHER`: per-query database parallelism;
- `DATABASE_SYNCHRONOUS_COMMIT`: durability/latency policy;
- `DATABASE_MAX_WAL_SIZE`: write-ahead-log allowance during heavy ingestion;
- `READ_MODEL_TOTAL_CAPACITY`: total concurrent read-model work;
- `READ_MODEL_RESERVED_LIVE_CAPACITY`: capacity reserved for current traffic;
- `READ_MODEL_BOOTSTRAP_BATCH_SIZE`: historical catch-up batch size;
- `BACKGROUND_INDEXING_DUTY_PERCENT`: controlled-batch wall duty from `1` through `100`. The
  default `100` is a true bypass that preserves normal indexing concurrency. A lower value uses
  one shared lane for capture, classification, and derived indexing, then applies a proportional
  cooldown after non-empty or failed batches. One cooldown is capped at 30 seconds. This is not a
  CPU-utilization percentage;
- `PARTY_EVENTS_INDEXING_DELAY_MS`: deprecated fixed-delay compatibility control. Keep it at `0`
  whenever `BACKGROUND_INDEXING_DUTY_PERCENT` is below `100`; invalid combinations fail startup.

The remaining pressure thresholds let large operators match scheduling to their database and
container limits. Keep the supplied defaults initially. Increase capacity only after increasing
CPU, memory, and database connections, and observe capture lag and write latency between changes.

The `STREAM_*` variables in `.env.example` retain stream-delivery throughput controls without
requiring another service. Keep `ALLOW_PRIVATE_WEBHOOK_TARGETS=false` unless callback receivers
intentionally live on a private network. See
[Streams, alerts, and connectors](streaming.md).

## Operations

```bash
docker compose --env-file docker-compose/.env \
  -f docker-compose/compose.yaml ps
docker compose --env-file docker-compose/.env \
  -f docker-compose/compose.yaml logs -f backend
curl http://127.0.0.1:8090/startup-status
curl http://127.0.0.1:8090/docs/v1/openapi.json
```

Stop containers without deleting data:

```bash
docker compose --env-file docker-compose/.env \
  -f docker-compose/compose.yaml down
```

The named database and export volumes remain. Do not use `down --volumes` unless permanent
data deletion is intended and backups have been verified.

For encrypted storage, set `DATABASE_DATA_PATH` to an absolute path on an encrypted
filesystem. See [Encryption at rest](../encryption_at_rest.md).
