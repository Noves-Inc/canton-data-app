# Data App - Docker Compose Deployment

## Prerequisites
- Docker & Docker Compose installed
- Existing Canton validator node running in Docker Compose (typically with network `splice-validator_splice_validator`)
- Domain with DNS access (or ability to configure DNS records)
- Auth0 or Keycloak instance with admin access
- Access to Canton participant's Ledger API (gRPC)

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Auth0 Configuration](#auth0-configuration)
3. [Environment Configuration](#environment-configuration)
4. [Node Configuration (v3.12.0+)](#node-configuration-v3120)
5. [Network & TLS Configuration](#network--tls-configuration)
6. [Nginx Configuration](#nginx-configuration)
7. [Deployment](#deployment)
8. [Verification & Testing](#verification--testing)
9. [Debugging Commands](#debugging-commands)
10. [Troubleshooting](#troubleshooting)
11. [Operational Commands](#operational-commands)
12. [Optional: Traffic Analyzer Addon](#optional-traffic-analyzer-addon)

---

## Architecture Overview

The Data App consists of three Docker containers:

- **Database (`canton-data-app-db`)**: Postgres instance that stores all indexed data. This is the only stateful service and mounts the persistent volume defined in the compose file.
- **Backend (`canton-data-app-backend`)**: Indexes Canton ledger data via gRPC Ledger API, enriches it, persists to the database, and exposes a REST API.
- **Frontend (`canton-data-app-frontend`)**: UI that authenticates users via Auth0 or Keycloak (OIDC) and displays data from the backend.

All three containers run in the same Docker network as your Canton validator node (`splice-validator_splice_validator` by default) to enable direct service-to-service communication.

### Authentication Flow

1. User logs into frontend via Auth0 or Keycloak (OIDC provider)
2. Frontend receives JWT token from the authentication provider
3. Frontend sends user's JWT token to backend with data requests
4. Backend forwards the same JWT token to Canton's Ledger API (passthrough)
5. Canton validates JWT and returns data for authorized parties only

**Important:** The backend acts as a passthrough. It does not generate its own tokens or authenticate with the OIDC provider directly.

### Wallet Features (Optional)

The app includes optional wallet functionality that enables users to send/receive Canton Coin (CC) transfers and maintain an address book. To enable wallet features:

1. **Backend**: Set `SCAN_PROXY_URL` to point to your validator's Scan API (e.g., `http://validator:5003/api/validator`)
2. **Frontend** (optional): Configure `VITE_WALLET_CONFIRMATION_THRESHOLD` to set the CC amount requiring explicit confirmation (default: 100000 CC)

If `SCAN_PROXY_URL` is not set, the app will function normally but wallet features will be disabled.

---

## Authentication Configuration

**Before proceeding with deployment, complete your authentication provider setup:**

Choose your authentication provider and complete its setup:
- **Auth0**: 📄 **[Auth0 Setup Guide](../authentication/auth0.md)**
- **Keycloak**: 📄 **[Keycloak Setup Guide](../authentication/keycloak.md)**

---

## Environment Configuration

### Backend Configuration

Edit `compose.yaml` and configure the `canton-data-app-backend` service:

```yaml
environment:
  # Node configuration (v3.12.0+): use a JSON config file for single or multi-node setups
  # See "Node Configuration" section below for format and volume mount instructions
  NODES_CONFIG_FILE_PATH: "/app/config/nodes-config.json"

  # Legacy single-node variables (still supported; used when NODES_CONFIG_FILE_PATH is not set)
  CANTON_NODE_ADDR: "participant:5001"  # Internal Docker DNS
  # OR if using external participant:
  # CANTON_NODE_ADDR: "canton-validator.yourdomain.com:8443"

  # TLS/Certificate (legacy single-node only; for multi-node set cert_file inside the JSON config)
  CANTON_NODE_CERT_FILE_PATH: ""

  # Database connection
  INDEX_DB_HOST: "canton-data-app-db"
  INDEX_DB_PORT: "5432"
  INDEX_DB_NAME: "canton_index"
  INDEX_DB_USER: "appuser"
  INDEX_DB_PASSWORD: ${CANTON_TRANSLATE_DB_PASSWORD:-change-me}

  # Optional S3-compatible backup destination
  BACKUP_S3_BUCKET: ""
  BACKUP_S3_PREFIX: ""
  BACKUP_S3_ENDPOINT_URL: ""
  BACKUP_S3_ACCESS_KEY_ID: ""
  BACKUP_S3_SECRET_ACCESS_KEY: ""
  BACKUP_S3_SESSION_TOKEN: ""

  # Wallet features (optional - leave empty to disable)
  SCAN_PROXY_URL: "http://validator:5003/api/validator"  # Required to enable wallet features
```

> Define `CANTON_TRANSLATE_DB_PASSWORD` in a `.env` file or export it before running `docker compose` so the password is never checked into source control.

### Frontend Configuration

Configure the `canton-data-app-frontend` service:

**For Auth0 Authentication:**

```yaml
environment:
  PORT: "8091"
  
  # Backend endpoint (internal Docker DNS)
  CANTON_TRANSLATE_BASE_URL: "http://canton-data-app-backend:8090"
  
  # Auth0 configuration (SPA app from Auth0 Setup section)
  VITE_AUTH0_DOMAIN: "your-tenant.us.auth0.com"
  VITE_AUTH0_CLIENT_ID: "<SPA_CLIENT_ID>"  # From SPA app
  VITE_AUTH0_AUDIENCE: "https://canton.network.global"  # Custom API identifier - REQUIRED for JWT tokens
  VITE_AUTH0_REDIRECT_URI: "https://canton-data-ui.yourdomain.com/callback"
  VITE_AUTH0_LOGOUT_URL: "https://canton-data-ui.yourdomain.com"
```

**For Keycloak Authentication:**

```yaml
environment:
  PORT: "8091"
  
  # Backend endpoint (internal Docker DNS)
  CANTON_TRANSLATE_BASE_URL: "http://canton-data-app-backend:8090"
  
  # Keycloak configuration (Public client from Keycloak Setup section)
  VITE_KEYCLOAK_URL: "https://keycloak.yourdomain.com"  # Base URL of Keycloak server
  VITE_KEYCLOAK_REALM: "your-realm-name"  # Keycloak realm name
  VITE_KEYCLOAK_CLIENT_ID: "data-app-ui"  # From Keycloak Public Client
  VITE_KEYCLOAK_REDIRECT_URI: "https://canton-data-ui.yourdomain.com/callback"
  VITE_KEYCLOAK_LOGOUT_URL: "https://canton-data-ui.yourdomain.com"
```

**Note:** The presence of `VITE_KEYCLOAK_URL` triggers Keycloak authentication. Configure **either** Auth0 **or** Keycloak variables, not both.

**Wallet Configuration (Optional):**

```yaml
environment:
  # Optional: Threshold for requiring "CONFIRM" on large transfers (default: 100000 CC)
  VITE_WALLET_CONFIRMATION_THRESHOLD: "100000"
```

### Database Configuration

The `canton-data-app-db` runs TimescaleDB/Postgres and is the only stateful workload:

```yaml
services:
  canton-data-app-db:
    image: ghcr.io/noves-inc/canton-translate-db:latest
    environment:
      POSTGRES_USER: "appuser"
      POSTGRES_DB: "canton_index"
      POSTGRES_PASSWORD: ${CANTON_TRANSLATE_DB_PASSWORD:-change-me}
      PGDATA: /home/postgres/pgdata/data
    volumes:
      - canton-data-app-db-data:/home/postgres/pgdata
```

The named volume `canton-data-app-db-data` preserves indexed data between restarts. No other service needs a volume.

### Port Configuration

Default ports (customizable):
- Database: `5432`
- Backend: `8090` (internal)
- Frontend: `8091` (internal)

Both app services can be accessed via nginx (or similar) on ports 80/443.

---

## Node Configuration (v3.12.0+)

Starting with v3.12.0, Canton Translate supports connecting to **one or more Canton validator nodes**. The recommended approach is a JSON config file. The legacy single-node environment variables (`CANTON_NODE_ADDR`, `CANTON_NODE_CERT_FILE_PATH`) remain supported but cannot configure multiple nodes.

### Configuration file format

**Single node:**

```json
{
  "nodes": {
    "validator-1": {
      "addr": "participant.example.com:5001",
      "cert_file": "/certs/validator-1.crt"
    }
  }
}
```

**Multiple nodes:**

```json
{
  "primaryNodeId": "validator-1",
  "nodes": {
    "validator-1": {
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

| Field | Required | Description |
|-------|----------|-------------|
| `primaryNodeId` | Required when multiple nodes are configured | ID of the node that owns pre-existing data in the database. See [Pre-existing Data Attribution](#pre-existing-data-attribution). |
| `nodes` | Yes | Object mapping node IDs to their configuration. Each key is the node ID (must be unique). |
| `nodes.<id>.addr` | Yes | gRPC address of the validator participant (`host:port`). |
| `nodes.<id>.cert_file` | No | Path to the TLS certificate file inside the container. Omit for insecure connections. |

### Mounting the config file

Place the JSON file on the host and mount it into the container. Certificate files referenced inside the JSON must also be mounted:

```yaml
services:
  canton-data-app-backend:
    image: ghcr.io/noves-inc/canton-translate:latest
    volumes:
      - ./config/nodes-config.json:/app/config/nodes-config.json:ro
      - ./certs/validator-1.crt:/certs/validator-1.crt:ro
      - ./certs/validator-2.crt:/certs/validator-2.crt:ro   # omit if only one node
    environment:
      NODES_CONFIG_FILE_PATH: "/app/config/nodes-config.json"
```

> If `NODES_CONFIG_FILE_PATH` is not set, the app also checks `/config/nodes-config.json` automatically before falling back to the legacy environment variables.

### Pre-existing data attribution

> **WARNING: Setting `primaryNodeId` incorrectly will mis-label all historical data. This is not easily reversible.**

When you add a second node to an existing deployment, the app needs to know which node originally indexed the data already in the database. On first startup with multiple nodes, it adds a `validator_node_id` column to every data table and backfills all existing rows with the value of `primaryNodeId`.

- `primaryNodeId` must match the node ID that was previously configured (the one whose data is already in the database).
- If you were using the legacy environment variables, the implicit node ID was `main-node` (or whatever `CANTON_NODE_ID` was set to).
- The app will refuse to start if multiple nodes are configured without `primaryNodeId`.

For step-by-step migration instructions, see [migrate_to_v3_12.md](migrate_to_v3_12.md).

---

## Network & TLS Configuration

### Docker Network

The compose file uses the `splice-validator_splice_validator` network (external). This is the default network created by the Canton validator's docker-compose.

To verify your network name:

```bash
docker network ls | grep splice
```

If your network has a different name, update `compose.yaml`:

```yaml
networks:
  splice-validator_splice_validator:
    external: true
    # Change to your actual network name
```

### TLS / Certificate Configuration

If your Canton participant requires TLS:

#### Step 1: Obtain Certificate

Get the TLS certificate from your validator administrator or extract it from your validator's configuration.

For a Canton validator deployed via docker-compose, the certificate is often at:
```bash
# Example path (adjust for your deployment)
/path/to/splice-node/docker-compose/validator/certs/participant.crt
```

#### Step 2: Mount Certificate

Place the certificate file in a location accessible to the docker-compose, e.g.:
```bash
mkdir -p ./certs
cp /path/to/participant.crt ./certs/validator_certificate.crt
```

#### Step 3: Update compose.yaml

```yaml
services:
  canton-data-app-backend:
    volumes:
      - ./certs/validator_certificate.crt:/code/validator_certificate.crt:ro
    environment:
      CANTON_NODE_CERT_FILE_PATH: "/code/validator_certificate.crt"
```

#### Step 4: Update CANTON_NODE_ADDR

If using TLS, ensure your `CANTON_NODE_ADDR` uses the correct port:

```yaml
CANTON_NODE_ADDR: "participant:5001"  # For plaintext (internal Docker)
# OR
CANTON_NODE_ADDR: "canton-validator.yourdomain.com:8443"  # For TLS (external)
```

---

## Nginx Configuration

### DNS Setup

Create DNS A records pointing to your server IP:
- `canton-data-ui.yourdomain.com` → Server IP
- `canton-data-api.yourdomain.com` → Server IP (optional, for direct backend access)

### SSL Certificate

Ensure you have a valid SSL certificate for `*.yourdomain.com` or specific subdomains.

For existing nginx deployments, you likely already have this configured.

### Configure canton-data-app.conf

Update `nginx/canton-data-app.conf` (included in this repository):

```nginx
# Frontend server (UI)
server {
    listen 80;
    listen 443 ssl;
    server_name canton-data-ui.yourdomain.com;  # UPDATE THIS
    
    # API requests go to backend (MUST come before / location)
    location /canton/ {
        proxy_pass http://canton-data-app-backend:8090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # Everything else goes to frontend
    location / {
        proxy_pass http://canton-data-app-frontend:8091;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

# Backend server (API) - Direct access if needed
server {
    listen 80;
    listen 443 ssl;
    server_name canton-data-api.yourdomain.com;  # UPDATE THIS
    
    location / {
        proxy_pass http://canton-data-app-backend:8090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Include in Main Nginx Config

If you're using the validator's existing nginx:

```bash
# Copy config to nginx config directory
sudo cp nginx/canton-data-app.conf /etc/nginx/conf.d/

# Or if using validator's nginx container, mount it as a volume
# and add to the main nginx.conf:
```

Add to main `nginx.conf`:
```nginx
http {
    # ... existing config ...
    
    include /etc/nginx/conf.d/canton-data-app.conf;
}
```

---

## Deployment

### Step 1: Review Configuration

Double-check all environment variables in `compose.yaml`:
- Auth0 domains and client IDs
- Canton node address
- Nginx server names match DNS records

### Step 2: Pull Docker Images

Pull the required images from GitHub Container Registry:

```bash
docker pull ghcr.io/noves-inc/canton-translate-ui:latest
docker pull ghcr.io/noves-inc/canton-translate:latest
docker pull ghcr.io/noves-inc/canton-translate-db:latest
```

### Step 3: Start Services

```bash
cd docker-compose

# Start services
docker compose up -d

# Or with project name
docker compose -p canton-data-app up -d
```

### Step 4: Reload Nginx

```bash
# For system nginx
sudo nginx -t && sudo nginx -s reload

# For Docker nginx
docker exec <nginx_container> nginx -t
docker exec <nginx_container> nginx -s reload

# Or restart the container
docker restart <nginx_container>
```

### Step 5: Monitor Startup

Watch logs for successful startup:

```bash
# Follow all logs
docker compose logs -f

# Backend only
docker compose logs -f canton-data-app-backend

# Frontend only
docker compose logs -f canton-data-app-frontend
```

---

## Verification & Testing

### Test Frontend Access

1. Navigate to `https://canton-data-ui.yourdomain.com`
2. Click "Log in"
3. Authenticate with your configured provider (Auth0 or Keycloak)
4. Should see dashboard with your data

If you get authentication errors, check:
- Authentication provider callback URLs are correct
- User's account is associated with a Canton party
- Browser console for detailed error messages
- See provider-specific troubleshooting: [Auth0](../authentication/auth0.md#troubleshooting-auth0-issues) or [Keycloak](../authentication/keycloak.md#troubleshooting-keycloak-issues)

---

## Debugging Commands

### View Logs

```bash
# All logs
docker compose logs

# Last 100 lines, follow
docker compose logs --tail=100 -f

# Specific service
docker compose logs -f canton-data-app-backend

# With timestamps
docker compose logs -f --timestamps
```

### Test gRPC Endpoints

Using `grpcurl` from host:

```bash
# List all gRPC services
docker run --rm --network $DOCKER_NETWORK fullstorydev/grpcurl -plaintext \
  participant:5001 list

# List methods in a service
docker run --rm --network $DOCKER_NETWORK fullstorydev/grpcurl -plaintext \
  participant:5001 list com.daml.ledger.api.v2.admin.UserManagementService

# Describe a method
docker run --rm --network $DOCKER_NETWORK fullstorydev/grpcurl -plaintext \
  participant:5001 describe com.daml.ledger.api.v2.admin.UserManagementService.GetUser
```


### Network Debugging

```bash
# List networks
docker network ls

# Inspect validator network
docker network inspect splice-validator_splice_validator

# See which containers are on the network
docker network inspect splice-validator_splice_validator | jq '.[0].Containers'

# Test DNS resolution
docker run --rm --network $DOCKER_NETWORK alpine nslookup participant
docker run --rm --network $DOCKER_NETWORK alpine nslookup canton-data-app-backend
```

### Authentication Token Inspection

For authentication provider token debugging and inspection:
- **Auth0**: See [Auth0 Setup Guide - Token Inspection](../authentication/auth0.md#token-inspection)
- **Keycloak**: See [Keycloak Setup Guide - Token Inspection](../authentication/keycloak.md#token-inspection)

---

## Troubleshooting

### Backend Can't Connect to Participant

**Symptoms**: Logs show "connection refused" or "connection timeout"

**Solutions**:
1. Verify network: `docker network inspect splice-validator_splice_validator`
2. Check participant is running: `docker ps | grep participant`
3. Test connectivity: `docker exec canton-data-app-backend nc -zv participant 5001`
4. Verify `CANTON_NODE_ADDR` in compose.yaml

### Authentication Errors

**Symptoms**: "PERMISSION_DENIED" or "UNAUTHENTICATED" errors

**Solutions**:

See provider-specific troubleshooting:
- **Auth0**: [Auth0 Setup Guide - Troubleshooting](../authentication/auth0.md#troubleshooting-auth0-issues)
- **Keycloak**: [Keycloak Setup Guide - Troubleshooting](../authentication/keycloak.md#troubleshooting-keycloak-issues)


### No Data Showing in Dashboard

**Symptoms**: Dashboard loads but shows no transactions/data

**Solutions**:
1. Check backend logs for indexing errors
2. Verify backend has `can_read_as` rights for the party:
   ```bash
   docker compose logs canton-data-app-backend | grep -i "error\|permission"
   ```
3. Check if transactions exist on the ledger:
   ```bash
   docker run --rm --network $DOCKER_NETWORK fullstorydev/grpcurl -plaintext \
     -H "authorization: Bearer $ACCESS_TOKEN" \
     -d '{"begin":{"boundary":"LEDGER_BEGIN"},"filter":{"filters_by_party":{"'"$PARTY_ID"'":{}}}}' \
     participant:5001 com.daml.ledger.api.v2.UpdateService/GetUpdates | head -50
   ```


### Nginx Not Routing Correctly

**Symptoms**: 404 or 502 errors when accessing frontend/backend URLs

**Solutions**:
1. Check nginx config syntax: `docker exec <nginx_container> nginx -t`
2. Verify server_name matches DNS: check `canton-data-app.conf`
3. Check nginx logs:
   ```bash
   docker logs <nginx_container> | grep canton-data-api
   ```
4. Ensure nginx is on the same Docker network

---

## Operational Commands

### Start/Stop Services

```bash
# Start
docker compose up -d

# Stop (preserves data)
docker compose stop

# Stop and remove containers (preserves volumes)
docker compose down

# Stop and remove everything including volumes (DESTRUCTIVE)
docker compose down -v
```

### Restart After Config Changes

```bash
# Recreate containers with new config
docker compose up -d --force-recreate

# Restart specific service
docker compose restart canton-data-app-backend
```

### Update Images

```bash
# Pull latest images (using compose file)
docker compose pull

# Or pull manually
docker pull ghcr.io/noves-inc/canton-translate-ui:dist
docker pull ghcr.io/noves-inc/canton-translate:dist

# Recreate containers with new images
docker compose up -d --force-recreate

# Or combined
docker compose pull && docker compose up -d --force-recreate
```

---

## Optional: Traffic Analyzer Addon

The Traffic Analyzer addon enables real-time traffic cost analysis by collecting Canton participant logs and correlating them with transaction data.

**This is an optional feature.** The main Data App functions fully without it.

### Prerequisites

- Data App backend running with `TRAFFIC_ANALYSIS_ENABLED=true` environment variable set
- Canton participant with `LOG_LEVEL_CANTON=DEBUG` enabled

### Installation

```bash
cd ../traffic-analyzer/docker-compose
docker compose up -d
```

### Configuration

The Fluent Bit configuration sends logs to the Data App backend at `http://canton-data-app-backend:5124/ingest`. If your backend container has a different name, update `fluent-bit.conf`:

```ini
[OUTPUT]
    Name              http
    Match             docker.*
    Host              YOUR_BACKEND_CONTAINER_NAME
    Port              5124
    ...
```

📄 **For full documentation, see: [../traffic-analyzer/README.md](../traffic-analyzer/README.md)**
