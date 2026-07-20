# Noves Data App
<img width="1906" height="911" alt="noves-data-app-dashboard" src="https://github.com/user-attachments/assets/b887b869-acf8-4719-b9ec-b6dedb4718ad" />

## Table of Contents

1. [Overview](#overview)
2. [Components](#components)
3. [Deployment](#deployment)
   - [Initial Considerations](#initial-considerations)
   - [Requirements](#requirements)
   - [Encryption at Rest](#encryption-at-rest)
   - [Authentication](#authentication)
   - [Ingress](#ingress)
   - [Port Numbers & Networking](#port-numbers--networking)
   - [Docker Images](#docker-images)
   - [Authorization](#authorization)
4. [Environment Variables](#environment-variables)
   - [Frontend Environment Variables](#frontend-environment-variables)
   - [Backend Environment Variables](#backend-environment-variables)
5. [Data Exports](#data-exports)
6. [Transaction History Backups](#transaction-history-backups-optional)
7. [Installation Steps](#installation-steps)
8. [Optional Addons](#optional-addons)
   - [Traffic Analyzer](#traffic-analyzer)
9. [Embedded Mode](#embedded-mode)
10. [Support](#support)

---

## Overview

Welcome to the Noves Data App for Canton.

This is a self-hosted application that takes care of sourcing, indexing, processing and visualizing your Canton data for a variety of reporting scenarios and use cases.

Because it runs in your infrastructure and uses your existing authentication system, it allows you to maintain full security and privacy, as intended in the Canton Network's design philosophy, while still enabling a superior data UX.
<img width="1766" height="729" alt="noves-data-app-transactions" src="https://github.com/user-attachments/assets/2e242be7-0e64-47d9-b2d9-d78ec2f6c984" />

---

## Components

The Data App consists of three primary components:

### Backend Indexer/Processor

The backend indexes your data, contextualizes it with its real-world meaning, and delivers it in an enriched JSON format that's easily consumed by other applications for financial reporting and other purposes. 

The JSON schema for Canton transactions is similar to the one we use for reporting on other blockchains (see [docs.noves.fi](https://docs.noves.fi) for more). It's intended to capture the full breadth of relevant details, while simplifying and interpreting a lot of the complexity that comes with raw data.

### Dashboard (Frontend)

The frontend consists of a dashboard that runs on backend-provided data. It allows you to:
- Visualize data in multiple views
- Filter by various conditions
- Graph transaction data
- Export to CSV (see [Data Exports](#data-exports))

> The larger **transaction** and **cost-basis** exports run as asynchronous jobs on the backend and require an S3-compatible bucket to be configured. See [Data Exports](#data-exports) for setup.

### Wallet Features (Optional)

The app includes optional wallet functionality that enables users to:
- Send and receive Canton Coin (CC) transfers
- Maintain an address book for parties
- Perform wallet operations for any party the user is authorized to act as

**To enable wallet features**, the backend must have network access to the validator's Scan API and the `SCAN_PROXY_URL` environment variable must be configured. If this variable is not set, the app will launch normally but wallet features will be disabled.

### Database (TimescaleDB/Postgres)

Version 3.0.0 introduces a dedicated Postgres database container. It is the authoritative store for data and the only stateful workload that requires persistent storage.

---

## Deployment

### Initial Considerations

The delivery of the app is through three Docker containers (frontend, backend, database) that are assumed to run in the same network (for example inside a docker-compose deployment) or inside the same Kubernetes namespace.

Only the database container requires persistent storage. The frontend and backend are stateless and can be re-created freely as long as they can reach the database service.

It is not a requirement that they run in the same network as your Canton validator node. But in practice, we expect this to be the case most of the time (for your own security). All URLs and endpoints are configurable via environment variables.

---

### Requirements

The backend will need network access to the Ledger API on your validator node.

We assume that the traffic between the backend container and Ledger API will be encrypted, so we have planned for a certificate to be mounted to the container so that it can authenticate secure gRPC requests against the Ledger API.

On your validator node, if not done already, you will need to expose a port for the gRPC Ledger API, and (optionally) enable TLS. We're including exact instructions on how to do this, in a separate file.

### Hardware Requirements

Resource usage is driven primarily by the number of transactions in your validator. As an initial benchmark, we recommend allocating to the data app:

- `1 CPU` core allocated to the backend container, `1 CPU` core allocated to the database container
- `1 GB` of memory allocated to the backend container, `2 GB` of memory allocated to the database container
-  The frontend container has minimal requirements, `0.5 CPU` and `512 MB` for memory should be sufficient
- For storage, plan to be using approximately `70%` of the validator's Postgres volume size. For example, if the validator is using `100 GB` of storage, assume the data app database would use approximately `70 GB`

---

### Encryption at Rest

Starting with v4, the storage backing the database volume is expected to be **encrypted at rest**. The database container is the only stateful component, so this comes down to one thing: the volume it mounts must live on encrypted storage — an encrypted cloud disk, a LUKS filesystem, or an encrypted Kubernetes StorageClass, depending on your environment. Queries, dashboards and performance are unaffected.

See **[encryption_at_rest.md](encryption_at_rest.md)** for the full guide: setup per deployment mode (Docker Compose and Kubernetes), migration of existing unencrypted deployments (a file copy — no re-indexing), backup/export bucket requirements, key management, and a verification checklist.

---

### Authentication 

This app leverages your existing authentication system, instead of requiring a new one.

The frontend ships native support for **Auth0** and **Keycloak** authentication providers via OIDC. The system automatically detects which provider to use based on environment variables.

The backend will always work with any authentication system that is compatible with Canton's JWT standard.

#### Auth0 Setup

For Auth0 authentication, you will need to:

1. Create an Auth0 Single Page Application (SPA) for user authentication
2. Configure Canton users with appropriate read permissions for each user (this is already done if you're using Auth0 as your primary authentication provider in the validator)

**Note:** The backend does not authenticate with Auth0 directly. It receives JWT tokens from the frontend and passes them through to Canton's Ledger API.

📄 **For detailed Auth0 setup instructions, see: [authentication/auth0.md](authentication/auth0.md)**

#### Keycloak Setup

For Keycloak authentication, you will need to:

1. Create a Keycloak Public Client for user authentication
2. Configure the `daml_ledger_api` scope as a default scope for Canton Network compatibility
3. Configure Canton users with appropriate read permissions for each user (this is already done if you're using Keycloak as your primary authentication provider in the validator)

**Note:** The backend does not authenticate with Keycloak directly. It receives JWT tokens from the frontend and passes them through to Canton's Ledger API.

📄 **For detailed Keycloak setup instructions, see: [authentication/keycloak.md](authentication/keycloak.md)**

#### Authentication Flow

If you're using the frontend to query the data, you'll sign in with essentially the same flow as logging in to the native Canton Wallet:

- You log in with your user account, which has already been authorized for one or more parties, and the frontend will get a JWT token issued via Auth0 and send that token to the backend, which will retrieve data for the parties you're authorized to read.

For larger organizations, this means that users can only access data for parties that they have previously been granted access to.

---

### Ingress

We have planned for both the frontend and backend to exposed via a DNS record and https, should you desire to. For example: `canton-data-app-frontend.yourcompany.com`

You'll find sample manifests / config files for nginx in the instructions, but you can use any reverse proxy of your choice. We advise you to leverage your existing reverse proxy (aka your existing nginx instance, if you have one), instead of installing a separate one.

---

### Port Numbers & Networking

By default, the backend runs on port `8090`, the frontend runs on port `8091`, and the database listens on port `5432`. These are customizable via environment variables. If you change the default port, update your docker-compose config or Kubernetes manifest accordingly.

Regardless of your deployment topology, it is highly advised that both containers run in the same network, for optimal service-to-service communicationn.

In practice, this means running them inside a docker-compose when deploying in a VM, or running them in the same namespace of a Kubernetes cluster.

For service-to-service communication, there are environment variables that you can set to define the exact URL that the frontend will use to talk to the backend. This will typically be the Kubernetes service name or the name of the container in the docker-compose.

For docker-compose, we assume that you'll be deploying using the same network as the validator node (`splice-validator_splice_validator` network). This is the default setting in our compose file and it allows this app to reference the validator node via a friendly internal DNS name, and vice versa.

**Default Ports:**
- Backend: `8090`
- Frontend: `8091`
- Database: `5432`

---

### Docker Images

Regardless of your chosen deployment topology, you'll be pulling our Docker images from GitHub Container Registry.

**Required Images:**
- **Frontend**: `ghcr.io/noves-inc/canton-translate-ui:latest` (also available with individual version numbers)
- **Backend**: `ghcr.io/noves-inc/canton-translate:latest` (also available with individual version numbers)
- **Database**: `ghcr.io/noves-inc/canton-translate-db:latest` (also available with individual version numbers)

**Pull the images:**
```bash
docker pull ghcr.io/noves-inc/canton-translate-ui:latest
docker pull ghcr.io/noves-inc/canton-translate:latest
docker pull ghcr.io/noves-inc/canton-translate-db:latest
```

The images will launch with the default deployment manifests included in this repository, and upon launch they will authorize your participant ID against our active subscriptions.

---

### Authorization

To use the app, you must have purchased a license that covers the participant ID you're trying to fetch data for.

For example, if you purchase a license for your main validator party:
```
validator-party::1220dd5cc6e969cd7d7c11e339fbd07fab5f6fa1f999dc09339228d17299d9d68941
```

Then you'll be able to pull data for any parties that end in:
```
1220dd5cc6e969cd7d7c11e339fbd07fab5f6fa1f999dc09339228d17299d9d68941
```

---

## Environment Variables

Both containers are configured via environment variables. Below is a comprehensive reference of all available settings.

### Frontend Environment Variables

| Variable | Example Value | Description |
|----------|---------------|-------------|
| `PORT` | `8091` | The port the frontend server listens on |
| `CANTON_TRANSLATE_BASE_URL` | `http://canton-data-app-backend:8090` | Internal URL to reach the backend service. For Docker Compose, this is the backend container name and port. For Kubernetes, this is the backend service name. |
| **Auth0 Configuration** | | **Use these variables for Auth0 authentication** |
| `VITE_AUTH0_DOMAIN` | `dev-xxx.us.auth0.com` | Your Auth0 tenant domain |
| `VITE_AUTH0_CLIENT_ID` | `abc123...` | The Client ID of your Auth0 SPA application (see [Auth0 Setup](authentication/auth0.md)) |
| `VITE_AUTH0_REDIRECT_URI` | `https://canton-data-ui.yourdomain.com/callback` | The callback URL where Auth0 redirects after login. Must match the **Allowed Callback URLs** configured in your Auth0 SPA application. |
| `VITE_AUTH0_LOGOUT_URL` | `https://canton-data-ui.yourdomain.com` | The URL where users are redirected after logout. Must match the **Allowed Logout URLs** configured in your Auth0 SPA application. |
| `VITE_AUTH0_AUDIENCE` | `https://your-audience.com` | (Optional) The Auth0 API identifier if you're using JWT audience validation. |
| **Keycloak Configuration** | | **Use these variables for Keycloak authentication (alternative to Auth0)** |
| `VITE_KEYCLOAK_URL` | `https://keycloak.yourdomain.com` | Base URL of your Keycloak server. When this variable is present, the app will use Keycloak instead of Auth0. |
| `VITE_KEYCLOAK_REALM` | `your-realm-name` | Keycloak realm name where your client is configured |
| `VITE_KEYCLOAK_CLIENT_ID` | `data-app-ui` | The Client ID of your Keycloak Public Client (see [Keycloak Setup](authentication/keycloak.md)) |
| `VITE_KEYCLOAK_REDIRECT_URI` | `https://canton-data-ui.yourdomain.com/callback` | The callback URL where Keycloak redirects after login. Must match the **Valid redirect URIs** configured in your Keycloak client. |
| `VITE_KEYCLOAK_LOGOUT_URL` | `https://canton-data-ui.yourdomain.com` | The URL where users are redirected after logout. Must match the **Valid post logout redirect URIs** configured in your Keycloak client. |
| **Wallet Configuration** | | **Optional settings for wallet features** |
| `VITE_WALLET_CONFIRMATION_THRESHOLD` | `100000` | (Optional) The Canton Coin (CC) amount threshold above which users must type "CONFIRM" to complete a transfer. Defaults to `100000` CC if not set. |
| **Embedded Mode** | | **Optional settings for iframe embedding** |
| `EMBED_ALLOWED_ORIGINS` | `https://host.example.com` | (Optional) Comma-separated list of origins allowed to embed the Data App in an iframe. When not set, iframe embedding is blocked. See [Embedded Mode](#embedded-mode). |

**Authentication Provider Selection:**
- The app automatically detects which authentication provider to use based on environment variables
- If `VITE_KEYCLOAK_URL` is set, Keycloak will be used
- If `VITE_KEYCLOAK_URL` is not set, Auth0 will be used (legacy behavior)
- Configure **either** Auth0 **or** Keycloak variables, not both

---

### Backend Environment Variables

The backend has the following user-configurable environment variables:

| Variable | Example Value | Description |
|----------|---------------|-------------|
| `NODES_CONFIG_FILE_PATH` | `/app/config/nodes-config.json` | (Recommended) Path to a JSON file that defines one or more Canton validator nodes. When set, this takes precedence over the legacy single-node environment variables below. Required for multi-validator deployments. See deployment guides for format details. |
| **Legacy single-node variables** | | **Use the JSON config file above instead for new deployments. These remain supported for single-node setups.** |
| `CANTON_NODE_ADDR` | `splice-validator-participant-1:5001` | Address of the Canton participant's Ledger API. For Docker Compose deployments on the same network, use the participant container name and port. For external connections, use the fully qualified domain name and port. |
| `CANTON_NODE_CERT_FILE_PATH` | `""` or `/code/cert.crt` | Path to TLS certificate for secure gRPC communication with Canton. **Must be an empty string (`""`)** if the Ledger API does not require TLS (common for Docker Compose deployments). If TLS is required, mount the certificate file and provide its path. |
| `CANTON_NODE_ID` | `main-node` | Identifier assigned to the node when using legacy environment variables. Defaults to `main-node` if not set. This value is stored in the database to tag all indexed data; keep it stable after initial deployment. |
| `INDEX_DB_HOST` | `data-app-db` | Internal hostname for the database service. |
| `INDEX_DB_PORT` | `5432` | Database port exposed by the database service. |
| `INDEX_DB_NAME` | `canton_index` | Database name automatically created by the database container. |
| `INDEX_DB_USER` | `appuser` | Database username configured for the database container. |
| `INDEX_DB_PASSWORD` | `********` | Database password. Use Docker secrets, env vars, or Kubernetes Secrets to supply this securely. |
| **Reporting Configuration** | | **Optional settings for transaction reporting workflows** |
| `AUTOMATIC_UNCLASSIFIED_REPORTING` | `true` or `false` | (Optional) Enable automatic reporting flow for unclassified transactions. When set to `true`, unclassified transactions are automatically included in reporting workflows. If not set or set to `false`, the app falls back to a manual reporting option, available directly in the UI next to the "Unclassified" transaction label. Default is `false`. |
| **Backup Configuration** | | **Optional S3-compatible backup settings for transaction history** |
| `BACKUP_S3_BUCKET` | `canton-backup-test` | (Optional) Destination bucket for off-cluster transaction-history backups. |
| `BACKUP_S3_PREFIX` | `validator-a/` | (Optional) Prefix applied to every uploaded backup object. |
| `BACKUP_S3_ENDPOINT_URL` | `https://<your-provider-endpoint>` | (Optional) Custom S3-compatible endpoint (Cloudflare R2, MinIO, etc.) |
| `BACKUP_S3_ACCESS_KEY_ID` | `AKIA...` | (Optional) Access key for the backup bucket. |
| `BACKUP_S3_SECRET_ACCESS_KEY` | `********` | (Optional) Secret key for the backup bucket. |
| `BACKUP_S3_SESSION_TOKEN` | `********` | (Optional) Session token when using temporary credentials. Leave blank for long-lived credentials. |
| **Export Configuration** | | **S3-compatible storage for asynchronous data exports. See [Data Exports](#data-exports).** |
| `EXPORTS_S3_BUCKET` | `canton-exports` | (Optional) Destination bucket for transaction and cost-basis export results. **If left blank, the export feature falls back to `BACKUP_S3_BUCKET`.** When neither is set, those exports return a `501 "exports are not configured"` error. |
| `EXPORTS_S3_ENDPOINT_URL` | `https://<your-provider-endpoint>` | (Optional) Custom S3-compatible endpoint (Cloudflare R2, MinIO, etc.). Falls back to `BACKUP_S3_ENDPOINT_URL`. |
| `EXPORTS_S3_ACCESS_KEY_ID` | `AKIA...` | (Optional) Access key for the exports bucket. Falls back to `BACKUP_S3_ACCESS_KEY_ID`. Not required when using an attached IAM role on AWS. |
| `EXPORTS_S3_SECRET_ACCESS_KEY` | `********` | (Optional) Secret key for the exports bucket. Falls back to `BACKUP_S3_SECRET_ACCESS_KEY`. Not required when using an attached IAM role on AWS. |
| `TRANSACTION_EXPORT_TTL_DAYS` | `7` | (Optional) Days an export result is retained in the bucket before automatic cleanup. Default `7`. |
| `COST_BASIS_EXPORT_TTL_DAYS` | `7` | (Optional) Same retention setting for cost-basis export results. Default `7`. |
| `TRANSACTION_EXPORT_MAX_SOURCE_PARTIES` | `50` | (Optional) Maximum number of parties allowed in a single transaction export job. Default `50`. |
| **Wallet Configuration** | | **Required to enable wallet features** |
| `SCAN_PROXY_URL` | `http://validator:5003/api/validator` | (Optional) URL to the validator's Scan API proxy endpoint. **Required to enable wallet features.** If not set, wallet functionality is disabled. For Docker Compose, use the validator container name (e.g., `http://validator:5003/api/validator`). For Kubernetes, use the fully qualified service name (e.g., `http://validator-app.validator.svc.cluster.local:5003/api/validator`). |
| `TRAFFIC_ANALYSIS_ENABLED` | `true` or `false` | (Optional) Enable traffic cost analysis. Requires Fluent Bit addon. Default is `false`. See [traffic-analyzer/](traffic-analyzer/) for setup. |

**Note:** The backend does not require Auth0 credentials. It receives JWT tokens from the frontend and passes them through to Canton's Ledger API for validation. You can also call the backend's API directly if you generate a valid JWT token on your own.

---

## Data Exports

The dashboard can export your data for downstream reporting and accounting. There are two categories of export, with different storage requirements:

### 1. In-browser CSV (no configuration required)

Smaller, on-screen result sets — such as the rollup/accounting preview — are turned into a CSV directly in your browser and downloaded locally. These work out of the box and need no extra setup.

### 2. Asynchronous exports (require an S3-compatible bucket)

Larger exports run as **background jobs on the backend** and stream their output to an S3-compatible object store. From the UI these are:

- **Transaction exports** — Financial CSV, Activity CSV, and Raw JSON (NDJSON).
- **Cost-basis exports** — realized gains/losses CSV (FIFO/LIFO/Proportional).

The flow is: the dashboard submits a job, polls until it completes, then receives a short-lived **presigned download URL** (valid 1 hour) that the browser uses to download the file directly from the bucket. Results are retained in the bucket for **7 days** by default ([`TRANSACTION_EXPORT_TTL_DAYS`](#backend-environment-variables) / `COST_BASIS_EXPORT_TTL_DAYS`) and then cleaned up automatically. The frontend never holds S3 credentials.

#### Configuring the exports bucket

These exports require an S3-compatible bucket. You have two options:

1. **Reuse your backup bucket (simplest).** If you have already configured the [Transaction History Backups](#transaction-history-backups-optional) (`BACKUP_S3_*`) variables, **exports work automatically** — no extra configuration is needed. The export feature reads the `EXPORTS_S3_*` variables first and transparently falls back to the corresponding `BACKUP_S3_*` values when they are blank.

2. **Use a dedicated exports bucket.** Set the `EXPORTS_S3_*` variables to send exports to a different bucket than your backups:

   ```yaml
   EXPORTS_S3_BUCKET: "canton-exports"
   EXPORTS_S3_ENDPOINT_URL: "https://<your-provider-endpoint>"   # for R2/MinIO/etc.
   EXPORTS_S3_ACCESS_KEY_ID: "AKIA..."                            # omit when using an AWS IAM role
   EXPORTS_S3_SECRET_ACCESS_KEY: "********"                       # omit when using an AWS IAM role
   ```

Any S3-compatible provider works (AWS S3, Cloudflare R2, MinIO, etc.). On AWS with an attached IAM role, you can omit the access key and secret. Store credentials in a Secret rather than a plain ConfigMap.

> **After setting these variables, restart the backend** so it picks them up — environment variables are read only at startup. For Docker Compose, recreate the backend container (`docker compose up -d`); for Kubernetes, restart the backend deployment (`kubectl rollout restart deployment/<backend-deployment>`).

> **If no bucket is configured at all** (neither `EXPORTS_S3_*` nor `BACKUP_S3_*`), submitting a transaction or cost-basis export returns `501 "exports are not configured (set EXPORTS_S3_BUCKET env var)"`. The rest of the app is unaffected.

> Support for other destinations (e.g. a mounted PVC) is not available in this release. If you need one, reach out via the support channel below.

---

## Transaction History Backups (Optional)

Major upgrades of the Canton network prune participant transaction history. This means that if you query the Ledger API, you won't be able to retrieve transaction history prior to the major upgrade ([Digital Asset validator upgrade guide](https://docs.dev.sync.global/validator_operator/validator_major_upgrades.html)).

While public Canton Coin transactions are still retrievable via the Scan API, if you have any private transactions (involving for example private assets such as CBTC), those will be lost when you conduct a major upgrade, unless you take a backup first.

To facilitate this, the backend container can stream periodic transaction snapshots into an S3-compatible object store. Enable this feature by setting the optional `BACKUP_S3_*` environment variables listed above. Once configured, the backend uploads append-only archives to your chosen bucket so you can restore or reprocess historical data even after a network-wide upgrade. You control retention, lifecycle rules, and access controls directly in your object storage account.

The backup feature is entirely optional. The application continues to run without the variables. However, we strongly recommend enabling it in production so that your reporting data survives major Canton upgrades.

## Installation Steps

### Before You Begin

**Complete authentication setup first:**

Choose your authentication provider and complete its setup:
- **Auth0**: [authentication/auth0.md](authentication/auth0.md)
- **Keycloak**: [authentication/keycloak.md](authentication/keycloak.md)

You'll need credentials from your chosen authentication provider before proceeding with deployment.

### Deployment Instructions

**Choose your deployment method:**

- **Docker Compose**: See [docker-compose/docker_compose_deployment.md](docker-compose/docker_compose_deployment.md) for step-by-step instructions
- **Kubernetes**: See [kubernetes/kubernetes_deployment.md](kubernetes/kubernetes_deployment.md) for step-by-step instructions

**Note**: the app will take approximately 2-3 minutes to index the first batch of data after being installed. Once the dashboard is up & running, wait for a few minutes.

---

## Optional Addons

### Traffic Analyzer

The Traffic Analyzer addon enables real-time traffic cost analysis by collecting Canton participant logs and correlating them with transaction data. This allows you to see the traffic cost associated with each transaction.

**This is an optional feature.** The main Data App functions fully without it.

**How it works:**
1. Fluent Bit collects logs from your Canton participant container
2. Logs are filtered and sent via HTTP to the Data App backend (port 5124)
3. The backend correlates traffic costs with transaction IDs
4. Traffic cost data becomes available via the Traffic Cost API

**Requirements:**
- Backend container with `TRAFFIC_ANALYSIS_ENABLED=true` environment variable set
- Canton participant with `LOG_LEVEL_CANTON=DEBUG` enabled
- Fluent Bit 2.x installed and configured per our instructions

**Installation:**
- **Docker Compose**: See [traffic-analyzer/docker-compose/README.md](traffic-analyzer/docker-compose/README.md)
- **Kubernetes**: See [traffic-analyzer/kubernetes/README.md](traffic-analyzer/kubernetes/README.md)

📄 **For full documentation, see: [traffic-analyzer/README.md](traffic-analyzer/README.md)**

---

## Embedded Mode

The Data App can be embedded inside a host application via iframe. This allows platforms that manage Canton node deployments to offer the Data App as part of their own UI, with URL synchronization and flexible authentication.

**This is an optional feature.** The main Data App functions fully without it.

**Two authentication modes:**

| Mode | iframe URL | Description |
|------|-----------|-------------|
| **Own Login** | `?embedded=true` | Data App shows its own Keycloak/Auth0 login inside the iframe. Use when the host user and Canton participant user are different. |
| **Host Auth** | `?embedded=true&auth=host` | Host passes JWT tokens via postMessage — no login screen. Use when host and Data App share the same OIDC user. |

**Requirements:**
- Frontend container with `EMBED_ALLOWED_ORIGINS` set to the host application's origin

**Configuration:**

```bash
# Single origin
EMBED_ALLOWED_ORIGINS=https://host.example.com

# Multiple origins
EMBED_ALLOWED_ORIGINS=https://host.example.com,https://staging.host.example.com
```

📄 **For full integration documentation, see: [embedded-mode/embedded_mode.md](embedded-mode/embedded_mode.md)**

---

## Support

This is an early-stage product. It's possible that issues will arise, and we're here to help in any way we can.

If you spot any issues or run into a snag during deployment, contact us through our shared Slack channel `#canton-data-app` (ask us for an invite link if you're not a member already).
