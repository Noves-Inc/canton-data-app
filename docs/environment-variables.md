# Container environment variables

This reference lists the environment variables exposed by the Helm chart and Docker Compose bundle. Start with the required and important settings. The remaining variables already have defaults or are needed only for optional features.

## Required and important settings

### Database password

- `POSTGRES_PASSWORD` and `INDEX_DB_PASSWORD` use the same required database password.
- Helm reads it from key `database.passwordKey` in `database.existingSecret`. The defaults are Secret `noves-canton-data-app-database` and key `postgres-password`.
- Compose reads `DATABASE_PASSWORD` from `.env`. The installer generates it when the example placeholder remains.



### Capture authentication

The backend requires:

- `M2M_TOKEN_ENDPOINT`
- `M2M_CLIENT_ID`
- `M2M_CLIENT_SECRET`
- `M2M_AUDIENCE`

Helm reads them from `capture.existingSecret`. Compose reads them from `.state/capture.env`.

`M2M_INDEXER_ENABLED=true` is fixed by Helm and must be present in the Compose capture file. `M2M_SCOPE` is optional.

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

Ledger API TLS and mTLS do not add container environment variables. Helm uses `canton.certificateSecret`, `canton.certificateKey`, `canton.clientCertificateKey`, `canton.clientPrivateKeyKey`, and `canton.tlsServerName`. Compose uses `cert_file`, `client_cert_file`, `client_key_file`, and `tls_server_name` in `.state/nodes-config.json`, with certificate files mounted read-only under `/certificates`. See the [Helm](helm.md#4-create-application-secrets) or [Docker Compose](docker-compose.md#optional-ledger-api-tls-and-mtls) instructions.

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
