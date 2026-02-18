# Docker Compose Migration Guide – v2.x → v3.0.0

This guide assumes you already have the Noves Data App running with the older two‑container docker-compose deployment (frontend + backend with local volumes). Follow the steps below to upgrade to the v3.0.0 architecture, which introduces a dedicated database container while keeping ingress, authentication, and Canton connectivity unchanged.

---

## 1. Review What Changes (and What Doesn’t)

| Component | v2.x Behavior | v3.0.0 Behavior | Action Required |
|-----------|---------------|-----------------|-----------------|
| Database storage | Embedded in backend (`INDEX_DB_PATH` + volume) | Dedicated Postgres (`canton-data-app-db`) with its own volume | **Adopt new compose file with DB service** |
| Backend env vars | `INDEX_DB_PATH` pointed to local disk | `INDEX_DB_HOST/PORT/NAME/USER/PASSWORD` connect to Postgres | Included in new compose file |
| Frontend env vars | Auth0/Keycloak, base URL | Same as before | No change |
| Canton connectivity | `CANTON_NODE_ADDR`, TLS cert | Same as before | No change |
| Ingress / reverse proxy | nginx config | Same as before | No change |

---

## 2. Download the v3 Compose Bundle

1. Check out or download the repository at `v3.x.x`.  
2. Copy `docker-compose/compose.yaml` from this release over your existing deployment host (make a backup with `cp compose.yaml compose.v2.bak` if desired).  
3. The new file already contains:
   - `canton-data-app-db` service with health checks and persistent volume
   - Updated backend env vars pointing to the database
   - Up-to-date image tags (`ghcr.io/noves-inc/...:latest`)
   - No persistent volumes for frontend/backend

> If you use any overrides (custom ports, network names, TLS mounts), re-apply those to the new file before continuing.

---

## 3. Provide the Database Password

Set the `CANTON_TRANSLATE_DB_PASSWORD` variable via `.env` or shell export so docker-compose picks it up:

```bash
export CANTON_TRANSLATE_DB_PASSWORD="replace-with-strong-pass"
```

All other environment variables (Auth0/Keycloak, Canton node address, TLS certificates) remain unchanged from v2.x.

If you want the backend to upload historical transaction snapshots so they survive future Canton major upgrades, also set the optional `BACKUP_S3_*` variables (bucket, prefix, endpoint, and credentials). See [Digital Asset’s upgrade guidance](https://docs.dev.sync.global/validator_operator/validator_major_upgrades.html) for why these backups are important.

---

## 4. Stop Old Containers and Pull New Images

```bash
cd docker-compose
docker compose down
```

This removes the old backend container so no file locks remain on the retired volume.

---

## 5. Launch the v3 Stack

```bash
docker compose up -d
docker compose ps
```

If you previously exposed the ingress for the data app using the nginx container shipped by default by your Canton node, make sure to restart that service:

```
docker restart splice-validator-nginx-1
```

Then verify:
- All containers show `healthy`.
- Backend logs contain messages like “Connected to Postgres” and “Starting initial index”.
- Frontend remains reachable via the same ingress/reverse proxy.

No changes are necessary to your nginx configuration, TLS certificates, DNS, Auth0/Keycloak settings, or Canton participant connectivity.

---

## 6. Clean Up Legacy Volumes

Once you’re satisfied the new database holds the required data:

```bash
docker volume rm docker-compose_frontend-exports docker-compose_backend-data 2>/dev/null
```
(Use `docker volume ls` to confirm names if different.)

