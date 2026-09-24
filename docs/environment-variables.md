# Container environment variables

This reference lists the environment variables exposed by the Helm chart and Docker Compose bundle. Start with the required and important settings. The remaining variables already have defaults or are needed only for optional features.

## Required and important settings

### Database password

- `POSTGRES_PASSWORD` and `INDEX_DB_PASSWORD` use the same required database password.
- Helm reads it from key `database.passwordKey` in `database.existingSecret`. The defaults are Secret `noves-canton-data-app-database` and key `postgres-password`.
- Compose reads `DATABASE_PASSWORD` from `.env`. The installer generates it when the example placeholder remains.



### M2M indexing authentication

For the default indexer user, the backend requires:

- `M2M_TOKEN_ENDPOINT`
- `M2M_CLIENT_ID`
- `M2M_CLIENT_SECRET`
- `M2M_AUDIENCE`

Helm reads them from `m2mIndexing.existingSecret`. Compose reads them from `.state/m2m-indexing.env`. A node
with an explicit `m2mIndexing` object instead reads its client secret or static token from the configured
file under `/m2m-indexing-secrets`; those nodes do not use the global token-source variables.

`M2M_INDEXER_ENABLED=true` remains enabled for both global and explicit node credentials. Helm and
Compose both fix it in the backend container; it does not belong in the operator-maintained M2M indexing
file. `M2M_SCOPE` is optional, as are the explicit node client-credential `audience` and `scope`.

### Browser authentication

The public application URL is required. Set `oidc.appUrl` in Helm or `APP_URL` in Compose. It supplies the redirect and logout URLs.

For Auth0, provide:

- `VITE_AUTH0_DOMAIN`
- `VITE_AUTH0_CLIENT_ID`
- `VITE_AUTH0_AUDIENCE`

For Keycloak, provide:

- `VITE_KEYCLOAK_URL`
- `VITE_KEYCLOAK_REALM`
- `VITE_KEYCLOAK_CLIENT_ID`

Helm uses the matching `oidc.auth0` or `oidc.keycloak` values. Compose reads the variables from `.env`. Leave the inactive provider's variables empty.

### Canton connection

- The backend detects the Canton network from the configured synchronizer alias and its authenticated identity catalog; there is no operator network selector.
- `SCAN_PROXY_URL` comes from `canton.scanApiUrl` in Helm or `CANTON_SCAN_API_URL` in Compose. The defaults are `http://validator-app:5003/api/validator` for Helm and `http://validator:5003/api/validator` for Compose. It must be the validator application's scan-proxy base path (including `/api/validator`), not the bare service origin. Override the value when that address is not reachable.

Ledger API TLS and mTLS do not add container environment variables. Helm configures each connection under `canton.nodes[].tls`; its Secret is mounted only in the backend under `/certificates/nodes/<node-id>`. Compose uses `cert_file`, `client_cert_file`, `client_key_file`, and `tls_server_name` in `.state/nodes-config.json`, with certificate files mounted read-only under `/certificates`. See the [Helm](helm.md#4-create-application-secrets) or [Docker Compose](docker-compose.md#optional-ledger-api-tls-and-mtls) instructions.

### S3 features

When S3 exports are enabled, `EXPORTS_S3_BUCKET` is required. When S3 transaction-history backups are enabled, `BACKUP_S3_BUCKET` is required.

Access key and secret key variables are required only when the storage authentication method needs them:

- `EXPORTS_S3_ACCESS_KEY_ID`
- `EXPORTS_S3_SECRET_ACCESS_KEY`
- `BACKUP_S3_ACCESS_KEY_ID`
- `BACKUP_S3_SECRET_ACCESS_KEY`

Helm reads S3 settings from `exports.s3` and `backup.s3`. Compose reads them from optional `.state/storage.env`.

## Optional and defaulted settings



### Database

- `POSTGRES_DB` and `INDEX_DB_NAME` default to `canton_index`.
- `POSTGRES_USER` and `INDEX_DB_USER` default to `appuser`.
- `INDEX_DB_HOST` is generated from the database Service in Helm and fixed to `database` in Compose.
- `INDEX_DB_PORT` defaults to `5432`.
- `PGDATA` is set by Compose to `/home/postgres/pgdata/data`.



### Backend

- `ALLOW_PRIVATE_WEBHOOK_TARGETS` defaults to `false`.
- `NODES_CONFIG_FILE_PATH` is fixed to `/config/nodes-config.json`.
- `M2M_SCOPE` is optional.

Database and read-model tuning:

- `INDEX_DB_WRITE_BATCH_SIZE` defaults to `250`. Lower it for constrained storage.
- `DATABASE_MAX_PARALLEL_WORKERS_PER_GATHER` defaults to `0`. Increase it only when parallel PostgreSQL queries fit the pod's shared memory.
- `DATABASE_SYNCHRONOUS_COMMIT` defaults to `off`. Changing it trades ingestion throughput for stronger synchronous WAL durability.
- `READ_MODEL_TOTAL_CAPACITY` defaults to `4`.
- `READ_MODEL_RESERVED_LIVE_CAPACITY` defaults to `1` and must remain lower than total capacity.
- `DATABASE_VOLUME_CAPACITY` is the size of the volume the database is stored on, written the way the
  storage is requested (`256Gi`, `500G`) or as plain bytes. A release that changes how transaction
  history is defined rebuilds every materialization, writing the new copy beside the one still being
  served, so the database is briefly larger than its settled size. Background indexing pauses at 85%
  of this figure and resumes once the retired copies are removed, instead of filling the volume.
  Reads and live indexing are never held back by it. Unset, or `0`, leaves the limit unevaluated and
  is the behaviour of earlier releases.

  The Helm chart fills it in from `database.persistence.size`, which is the right answer only when
  the chart creates the claim from that value. On an existing claim, and while `migration.enabled`
  runs the database on `migration.existingClaim`, the chart renders `0` and the size has to be given
  in `backend.performance.readModel.databaseVolumeCapacity`. Compose installations set it themselves.

  Nothing in the app measures the disk, so expanding the volume does not lift a pause on its own:
  raise this figure with it. A figure smaller than the database pauses background indexing with no
  way back, which the app reports as an error at startup.

  The figure the app compares against it is the size of the database. A volume also carries the
  write-ahead log and temporary files, which is why the limit sits at 85% rather than at the brim.
  On a volume shared with anything other than this database, declare the share this database may
  use rather than the size of the disk.

  Space a retired generation leaves behind is returned by rebuilding the affected indexes, which
  the app does by itself, one at a time, after a generation is retired. This requires the database
  role the app connects as to own its tables, which is the case for every installation the chart or
  the Compose bundle creates. An installation that migrates as one role and runs as another keeps
  working but reclaims nothing, and says so in the log.
- `BACKGROUND_INDEXING_DUTY_PERCENT` defaults to `100`. Values from `1` through `99` pace background indexing.

Stream delivery tuning:

- `STREAM_POLL_INTERVAL_MS` defaults to `5000`.
- `STREAM_PAGE_SIZE` defaults to `100`.
- `STREAM_RETRY_DELAY_MS` defaults to `2000`.
- `STREAM_WEBSOCKET_BUFFER_LIMIT` defaults to `10000`.
- `STREAM_DATABASE_TIMEOUT_SECONDS` defaults to `60`.
- `STREAM_DEDUPLICATION_WINDOW_RECORDS` defaults to `1000000`.
- `STREAM_DELIVERY_RECENCY_MINUTES` defaults to `1440`.

Helm exposes these as typed `backend.performance` and `backend.streaming` values. Compose exposes the matching variables in `.env`. `backend.extraEnv` remains available for backend settings that are not part of this supported tuning surface.



### Frontend

- `BACKEND_BASE_URL` is generated from the backend Service.
- `CANTON_DATA_APP_URL` is set by Helm from `oidc.appUrl`.
- `VITE_AUTH0_REDIRECT_URI`, `VITE_AUTH0_LOGOUT_URL`, `VITE_KEYCLOAK_REDIRECT_URI`, and `VITE_KEYCLOAK_LOGOUT_URL` are generated from the public application URL.
- `EMBED_ALLOWED_ORIGINS` is empty by default. Set exact comma-separated origins in Compose, or use `embedded.allowedOrigins` in Helm.
- `PORT` is set to `3000` by Compose.



### S3

- `EXPORTS_S3_ENDPOINT_URL`, `EXPORTS_S3_REGION`, and `EXPORTS_S3_SESSION_TOKEN` are optional.
- `BACKUP_S3_ENDPOINT_URL`, `BACKUP_S3_REGION`, and `BACKUP_S3_SESSION_TOKEN` are optional.



### Migration

`DATABASE_EXPECTED_SOURCE=v3` is set automatically during a v3.16.1 migration and is absent otherwise.

See [Helm installation](helm.md), [Docker Compose installation](docker-compose.md), [Auth0 configuration](authentication/auth0.md), and [Keycloak configuration](authentication/keycloak.md) for setup procedures.
