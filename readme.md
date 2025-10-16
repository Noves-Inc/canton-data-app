# Canton Data App
<img width="1328" height="878" alt="image" src="https://github.com/user-attachments/assets/286a3ea1-637f-4970-9330-3aaf42fe6268" />

## Table of Contents

1. [Overview](#overview)
2. [Components](#components)
3. [Deployment](#deployment)
   - [Initial Considerations](#initial-considerations)
   - [Requirements](#requirements)
   - [Authentication](#authentication)
   - [Ingress](#ingress)
   - [Port Numbers & Networking](#port-numbers--networking)
   - [Docker Images](#docker-images)
   - [Authorization](#authorization)
4. [Environment Variables](#environment-variables)
   - [Frontend Environment Variables](#frontend-environment-variables)
   - [Backend Environment Variables](#backend-environment-variables)
5. [Installation Steps](#installation-steps)
6. [Support](#support)

---

## Overview

Welcome to the Noves Data App for Canton.

This is a self-hosted application that takes care of sourcing, indexing, processing and visualizing your Canton data for a variety of reporting scenarios and use cases.

Because it runs in your infrastructure and uses your existing authentication system, it allows you to maintain full security and privacy, as intended in the Canton Network's design philosophy, while still enabling a superior data UX.
<img width="1254" height="716" alt="image" src="https://github.com/user-attachments/assets/c41d4d2c-7110-4650-b6cf-35d614e67ef4" />

---

## Components

The Data App consists of two primary components:

### Backend Indexer/Processor

The backend indexes your data, contextualizes it with its real-world meaning, and delivers it in an enriched JSON format that's easily consumed by other applications for financial reporting and other purposes. 

The JSON schema for Canton transactions is similar to the one we use for reporting on other blockchains (see [docs.noves.fi](https://docs.noves.fi) for more). It's intended to capture the full breadth of relevant details, while simplifying and interpreting a lot of the complexity that comes with raw data.

### Dashboard (Frontend)

The frontend consists of a dashboard that runs on backend-provided data. It allows you to:
- Visualize data in multiple views
- Filter by various conditions
- Graph transaction data
- Export to CSV

---

## Deployment

### Initial Considerations

The delivery of the app is through two Docker containers, which are assumed to be running in the same network (as part of a docker-compose deployment if you're deploying in a VM, or as two separate Kubernetes deployments in the same namespace, if you're deploying in k8s).

Both containers are stateful, meaning that they have local storage that needs to persist across restarts. We include the exact paths on which a volume or PVC needs to be mounted in the sample manifests.

It is not a requirement that they run in the same network as your Canton validator node. But in practice, we expect this to be the case most of the time (for your own security). All URLs and endpoints are configurable via environment variables.

---

### Requirements

The backend will need network access to the Ledger API on your validator node.

We assume that the traffic between the backend container and Ledger API will be encrypted, so we have planned for a certificate to be mounted to the container so that it can authenticate secure gRPC requests against the Ledger API.

On your validator node, if not done already, you will need to expose a port for the gRPC Ledger API, and (optionally) enable TLS. We're including exact instructions on how to do this, in a separate file.

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

By default, the backend runs on port `8090` and the frontend runs on port `8091`. These are both customizable via environment variables. If you change the default port, make sure to update your docker-compose config or Kubernetes manifest to target the correct port in each container.

Regardless of your deployment topology, it is highly advised that both containers run in the same network, for optimal service-to-service communicationn.

In practice, this means running them inside a docker-compose when deploying in a VM, or running them in the same namespace of a Kubernetes cluster.

For service-to-service communication, there are environment variables that you can set to define the exact URL that the frontend will use to talk to the backend. This will typically be the Kubernetes service name or the name of the container in the docker-compose.

For docker-compose, we assume that you'll be deploying using the same network as the validator node (`splice-validator_splice_validator` network). This is the default setting in our compose file and it allows this app to reference the validator node via a friendly internal DNS name, and vice versa.

**Default Ports:**
- Backend: `8090`
- Frontend: `8091`

---

### Docker Images

Regardless of your chosen deployment topology, you'll be pulling our Docker images from GitHub Container Registry.

**Required Images:**
- **Frontend**: `ghcr.io/noves-inc/canton-translate-ui:dist`
- **Backend**: `ghcr.io/noves-inc/canton-translate:dist`

**Pull the images:**
```bash
docker pull ghcr.io/noves-inc/canton-translate-ui:dist
docker pull ghcr.io/noves-inc/canton-translate:dist
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
| `CANTON_INDEXER_PAGE_SIZE` | `1000` | Indexer page size. |
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
| `INDEX_DB_PATH` | `.` | Path to the directory where the database file will be stored. This should point to persistent storage (a Docker volume or Kubernetes PVC). The backend will create `index.db` in this directory. |
| `CANTON_NODE_ADDR` | `splice-validator-participant-1:5001` | Address of the Canton participant's Ledger API. For Docker Compose deployments on the same network, use the participant container name and port. For external connections, use the fully qualified domain name and port. |
| `CANTON_NODE_CERT_FILE_PATH` | `""` or `/code/cert.crt` | Path to TLS certificate for secure gRPC communication with Canton. **Must be an empty string (`""`)** if the Ledger API does not require TLS (common for Docker Compose deployments). If TLS is required, mount the certificate file and provide its path. |

**Note:** The backend does not require Auth0 credentials. It receives JWT tokens from the frontend and passes them through to Canton's Ledger API for validation. You can also call the backend's API directly if you generate a valid JWT token on your own.

---

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

## Support

This is an early-stage product. It's possible that issues will arise, and we're here to help in any way we can.

If you spot any issues or run into a snag during deployment, contact us through our shared Slack channel `#canton-data-app` (ask us for an invite link if you're not a member already).
