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
4. [Network & TLS Configuration](#network--tls-configuration)
5. [Nginx Configuration](#nginx-configuration)
6. [Deployment](#deployment)
7. [Verification & Testing](#verification--testing)
8. [Debugging Commands](#debugging-commands)
9. [Troubleshooting](#troubleshooting)
10. [Operational Commands](#operational-commands)

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
  # Canton Ledger API connection
  CANTON_NODE_ADDR: "participant:5001"  # Internal Docker DNS
  # OR if using external participant:
  # CANTON_NODE_ADDR: "canton-validator.yourdomain.com:8443"
  
  # TLS/Certificate (see next section)
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
