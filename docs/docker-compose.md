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

## Standard setup

Prepare the files:

```bash
cp docker-compose/.env.example docker-compose/.env
mkdir -p docker-compose/.state
cp docker-compose/config/nodes-config.json docker-compose/.state/nodes-config.json
```

Edit `.env` for the public application URL and one OIDC provider. Edit
`.state/nodes-config.json` with the exact participant ID.

Create `.state/capture.env`:

```dotenv
M2M_INDEXER_ENABLED=true
M2M_TOKEN_ENDPOINT=https://issuer.example.com/oauth/token
M2M_CLIENT_ID=replace-me
M2M_CLIENT_SECRET=replace-me
M2M_AUDIENCE=https://canton.network.global
M2M_SCOPE=
```

Protect the files and start:

```bash
chmod 600 docker-compose/.env \
  docker-compose/.state/capture.env \
  docker-compose/.state/nodes-config.json
docker compose --env-file docker-compose/.env \
  -f docker-compose/compose.yaml up -d
```

The containers are named `noves-canton-backend-v4`, `noves-canton-frontend-v4`, and
`noves-canton-database-v4`. The backend is bound to localhost by default. The frontend also
defaults to localhost; put your existing TLS reverse proxy in front of port 8091 or change
`CDA_FRONTEND_BIND` intentionally.

## Versions

`CDA_VERSION=4.0.0` pins all three images. `CDA_VERSION=latest` opts into the newest release in
the v4-only repositories. It cannot select a future v5 image.

## Operations

```bash
docker compose --env-file docker-compose/.env \
  -f docker-compose/compose.yaml ps
docker compose --env-file docker-compose/.env \
  -f docker-compose/compose.yaml logs -f backend
curl http://127.0.0.1:8090/startup-status
```

Stop containers without deleting data:

```bash
docker compose --env-file docker-compose/.env \
  -f docker-compose/compose.yaml down
```

The named database and export volumes remain. Do not use `down --volumes` unless permanent
data deletion is intended and backups have been verified.
