# Docker Compose Migration Guide – Adding Multi-Validator Support (v3.12.0+)

This guide covers how to add a second (or more) Canton validator node to an existing single-node deployment after upgrading to v3.12.0 or later. If you are deploying for the first time, follow [docker_compose_deployment.md](docker_compose_deployment.md) and use the JSON config file from the start.

---

## 1. What Changes

| Area | Before | After | Action Required |
|------|--------|-------|-----------------|
| Node configuration | `CANTON_NODE_ADDR` + `CANTON_NODE_CERT_FILE_PATH` env vars | JSON config file mounted as a volume | Create config file, mount it, set `NODES_CONFIG_FILE_PATH` |
| TLS certificates | Single cert mounted via `CANTON_NODE_CERT_FILE_PATH` | Per-node `cert_file` paths inside the JSON config | Move cert reference into JSON config |
| Database schema | No `validator_node_id` column | Column added and backfilled on first startup | Automatic — no manual action needed |
| Other env vars | Unchanged | Unchanged | No change |

> Legacy environment variables (`CANTON_NODE_ADDR`, `CANTON_NODE_CERT_FILE_PATH`, `CANTON_NODE_ID`) continue to work for single-node setups and do not need to be removed.

---

## 2. Determine Your Existing Node ID

The `primaryNodeId` you set in the JSON config must match the node ID already stored in the database. Identify it before proceeding.

- **If you used `CANTON_NODE_ID`**: use that value.
- **If you did not set `CANTON_NODE_ID`**: the default is `main-node`.

Write this value down — you will need it in the next step.

---

## 3. Create the Node Configuration File

Create a `config/` directory next to your `compose.yaml` and write the JSON file:

```bash
mkdir -p config
```

```json
{
  "primaryNodeId": "main-node",
  "nodes": {
    "main-node": {
      "addr": "participant-1.example.com:5001",
      "cert_file": "/certs/validator-1.crt"
    },
    "validator-2": {
      "addr": "participant-2.example.com:5001",
      "cert_file": "/certs/validator-2.crt"
    }
  }
}
```

Replace `main-node` with your actual existing node ID from Step 2. If your participant does not use TLS, omit the `cert_file` lines.

> **WARNING: `primaryNodeId` must exactly match the node ID already in your database.** An incorrect value will mis-label all existing historical data, which is not easily reversible.

---

## 4. Update compose.yaml

Add the config file and any certificate volumes to the backend service, and set `NODES_CONFIG_FILE_PATH`:

```yaml
services:
  canton-data-app-backend:
    volumes:
      - ./config/nodes-config.json:/app/config/nodes-config.json:ro
      - ./certs/validator-1.crt:/certs/validator-1.crt:ro   # keep your existing cert mount
      - ./certs/validator-2.crt:/certs/validator-2.crt:ro   # add new node cert
    environment:
      NODES_CONFIG_FILE_PATH: "/app/config/nodes-config.json"
      # CANTON_NODE_ADDR and CANTON_NODE_CERT_FILE_PATH can remain but will be ignored
      # once NODES_CONFIG_FILE_PATH is set
```

---

## 5. Restart the Backend

```bash
docker compose up -d --force-recreate canton-data-app-backend
```

Watch the logs to confirm the migration completes successfully:

```bash
docker compose logs -f canton-data-app-backend
```

Look for messages indicating:
- Node configuration loaded
- `validator_node_id` column migration complete (only appears on first startup with multiple nodes)
- Connection established to both participant nodes

---

## 6. Verify

```bash
# Confirm both nodes are registered
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  http://localhost:8090/api/v2/nodes

# Expected: JSON listing both validator-1 and validator-2
```

The frontend node selector in the dashboard will also show all configured nodes once you reload the page.
